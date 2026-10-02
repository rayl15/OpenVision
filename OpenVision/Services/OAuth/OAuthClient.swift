// OpenVision - OAuthClient.swift
// Provider-agnostic OAuth 2.0 Authorization Code + PKCE helpers for subscription sign-in.
//
// Subscription backends (ChatGPT via the Codex CLI client) don't hand out API keys — they sign in
// the way their own CLIs do: open the provider's login page, catch the redirect on a loopback port
// (see OAuthLoopbackServer), and trade the one-time code for access + refresh tokens. This file is
// the pure part of that: config, PKCE, token exchange/refresh, and reading the account id from the
// JWT. No UI, no persistence — OAuthSignIn drives the flow, OAuthTokenStore keeps the tokens.

import CryptoKit
import Foundation

/// Static configuration for one subscription provider.
struct OAuthProvider: Sendable {
    /// Stable id — the Keychain account and log tag (e.g. "chatgpt").
    let id: String
    let displayName: String
    /// Static endpoints. With `discoveryURL` set they're the fallback for discovery.
    var authorizeURL: URL
    var tokenURL: URL
    let clientId: String
    let scope: String
    /// The redirect registered for the reused CLI client id. Must match exactly.
    let redirectHost: String
    let redirectPort: UInt16
    let redirectPath: String
    /// Provider-specific authorize params (e.g. Codex's originator / simplified flow).
    var extraAuthParams: [String: String] = [:]
    /// Refresh this long before the real expiry so a request never races the deadline.
    var refreshSkew: TimeInterval = 60
    /// OIDC discovery document whose endpoints override the static ones (xAI).
    var discoveryURL: URL? = nil
    /// Discovered endpoints must be https on this host or a subdomain — the discovery response
    /// decides where tokens get sent, so it isn't trusted blindly.
    var trustedHost: String? = nil

    var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }
}

/// Tokens for a signed-in subscription. `expiresAt` already has the refresh skew applied.
struct OAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// ChatGPT only: the `ChatGPT-Account-Id` header value, read from the JWT at sign-in.
    var accountId: String?

    func isExpired(now: Date = Date()) -> Bool { accessToken.isEmpty || expiresAt <= now }
}

enum OAuthError: LocalizedError, Equatable {
    case cancelled
    case timedOut
    case portUnavailable(UInt16)
    case stateMismatch
    case missingCode
    case provider(String)
    case tokenRequestFailed(Int)
    case noAccessToken
    /// The refresh token was rejected — only a new sign-in fixes this.
    case authorizationExpired

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in took too long. Try again."
        case .portUnavailable(let port): return "Couldn't open the sign-in callback port (\(port)). Close other apps using it and try again."
        case .stateMismatch: return "Sign-in response didn't match this request. Try again."
        case .missingCode: return "Sign-in didn't return an authorization code."
        case .provider(let message): return "Sign-in failed: \(message)"
        case .tokenRequestFailed(let status): return "Sign-in token request failed (HTTP \(status))."
        case .noAccessToken: return "Sign-in response didn't include an access token."
        case .authorizationExpired: return "Your subscription sign-in expired. Sign in again in Settings."
        }
    }
}

// MARK: - PKCE

enum PKCE {
    /// A high-entropy random string, base64url without padding (RFC 7636 verifier / state).
    static func randomString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Never fall through with zeros: SystemRandomNumberGenerator is also a CSPRNG on Apple
            // platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64URLEncoded
    }

    /// S256 code challenge for `verifier`.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Authorize URL + callback

enum OAuthClient {

    // MARK: Discovery

    private static let discoveryLock = NSLock()
    /// Per provider: the discovered endpoints, or nil when discovery failed this launch.
    nonisolated(unsafe) private static var discovered: [String: (authorize: URL, token: URL)?] = [:]

    /// `provider` with its endpoints from OIDC discovery when it has a discovery URL. The result is
    /// cached for the launch, including a failure ("use the static endpoints"), because this runs
    /// inside the single-flight token refresh and a captive portal shouldn't stall every refresh.
    static func resolved(_ provider: OAuthProvider) async -> OAuthProvider {
        guard let discoveryURL = provider.discoveryURL else { return provider }
        var provider = provider
        if let cached = discoveryLock.withLock({ discovered[provider.id] }) {
            if let cached {
                provider.authorizeURL = cached.authorize
                provider.tokenURL = cached.token
            }
            return provider
        }
        var result: (authorize: URL, token: URL)?
        do {
            var request = URLRequest(url: discoveryURL)
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let authorize = trustedEndpoint(json?["authorization_endpoint"], provider),
               let token = trustedEndpoint(json?["token_endpoint"], provider) {
                result = (authorize, token)
            } else {
                NSLog("[OAuth] %@ discovery returned untrusted endpoints, using defaults", provider.id)
            }
        } catch {
            NSLog("[OAuth] %@ discovery failed (%@), using defaults", provider.id, "\(error)")
        }
        discoveryLock.withLock { discovered[provider.id] = .some(result) }
        if let result {
            provider.authorizeURL = result.authorize
            provider.tokenURL = result.token
        }
        return provider
    }

    /// An endpoint is used only if it's https on the provider's trusted host or a subdomain.
    static func trustedEndpoint(_ value: Any?, _ provider: OAuthProvider) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              url.scheme == "https", let host = url.host?.lowercased(),
              let trusted = provider.trustedHost?.lowercased(),
              host == trusted || host.hasSuffix("." + trusted) else { return nil }
        return url
    }

    static func authorizeURL(for provider: OAuthProvider, challenge: String, state: String) -> URL {
        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientId),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        for (name, value) in provider.extraAuthParams.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    /// Pull the authorization code out of the loopback callback's query, rejecting a provider
    /// error or a state that isn't the one we sent (a stale or forged redirect).
    static func authorizationCode(from query: [URLQueryItem], expectedState: String) throws -> String {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if let error = value("error") {
            throw OAuthError.provider(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw OAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    // MARK: Token endpoint

    static func exchange(code: String, verifier: String, provider: OAuthProvider) async throws -> OAuthCredentials {
        let data = try await postToken(provider.tokenURL, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": provider.redirectURI,
            "client_id": provider.clientId,
            "code_verifier": verifier,
        ])
        return try credentials(from: data, provider: provider, previous: nil)
    }

    static func refresh(_ current: OAuthCredentials, provider: OAuthProvider) async throws -> OAuthCredentials {
        guard !current.refreshToken.isEmpty else { throw OAuthError.authorizationExpired }
        let provider = await resolved(provider)
        let data = try await postToken(provider.tokenURL, form: [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": provider.clientId,
        ])
        return try credentials(from: data, provider: provider, previous: current)
    }

    /// Token-endpoint JSON → stored credentials. A refresh response may omit the refresh token
    /// or account id; keep the previous ones then.
    static func credentials(from data: Data, provider: OAuthProvider, previous: OAuthCredentials?,
                            now: Date = Date()) throws -> OAuthCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.noAccessToken
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let accountId = JWT.chatGPTAccountId(idToken: json["id_token"] as? String, accessToken: access)
        return OAuthCredentials(
            accessToken: access,
            refreshToken: refresh ?? previous?.refreshToken ?? "",
            expiresAt: now.addingTimeInterval(expiresIn - provider.refreshSkew),
            accountId: accountId ?? previous?.accountId
        )
    }

    private static func postToken(_ url: URL, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(form).utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Token responses can carry credentials, so log the status and error code, never the body.
            let code = tokenErrorCode(data)
            NSLog("[OAuth] token request failed: HTTP %d (%@)", status, code ?? "-")
            if isRevoked(status: status, errorCode: code) { throw OAuthError.authorizationExpired }
            throw OAuthError.tokenRequestFailed(status)
        }
        return data
    }

    /// Codes that mean the refresh token is dead and only a new sign-in helps: RFC 6749's
    /// invalid_grant, plus the ones OpenAI's token endpoint returns (the same set the Codex CLI
    /// treats as permanent).
    static let revokedErrorCodes: Set<String> = [
        "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]

    /// The OAuth error code from a token-endpoint error body: RFC 6749's flat `"error": "…"`, or
    /// OpenAI's nested `"error": {"code": "…"}`.
    static func tokenErrorCode(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = json["error"] as? String { return code.lowercased() }
        return ((json["error"] as? [String: Any])?["code"] as? String)?.lowercased()
    }

    /// Whether a failed token request means the sign-in is gone. A 401 that carries an OAuth error
    /// counts (the Codex CLI treats every 401 from OpenAI's endpoint as permanent), except
    /// invalid_client, which is a configuration problem. A 401 with no OAuth body, e.g. from a
    /// proxy, stays retryable so a working sign-in isn't thrown away.
    static func isRevoked(status: Int, errorCode code: String?) -> Bool {
        if let code, revokedErrorCodes.contains(code) { return true }
        return status == 401 && code != nil && code != "invalid_client"
    }

    /// application/x-www-form-urlencoded with only RFC 3986 unreserved characters left bare —
    /// URLComponents would pass "+", "=" and "&"-adjacent characters through and corrupt tokens.
    static func formEncode(_ form: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return form.sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
    }
}

// MARK: - JWT

/// Signature-free JWT payload reader. Only used to read the ChatGPT account id — never to
/// authenticate anything — so no verification is needed.
enum JWT {
    static func payload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The ChatGPT account id, with the Codex CLI's fallback order: top-level claim → the
    /// `https://api.openai.com/auth` namespace → the first organization. id_token first.
    static func chatGPTAccountId(idToken: String?, accessToken: String?) -> String? {
        for token in [idToken, accessToken] {
            guard let claims = payload(token) else { continue }
            if let id = claims["chatgpt_account_id"] as? String, !id.isEmpty { return id }
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
               let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
            if let orgs = claims["organizations"] as? [[String: Any]],
               let id = orgs.first?["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }
}
