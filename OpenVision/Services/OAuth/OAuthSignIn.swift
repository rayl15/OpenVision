// OpenVision - OAuthSignIn.swift
// Runs a subscription sign-in: login sheet + loopback redirect + code exchange.
//
// ASWebAuthenticationSession shows the provider's login page (sharing Safari's cookies, so an
// existing chatgpt.com login is reused). It is started with no callback scheme — the redirect is
// an http://localhost URL that only OAuthLoopbackServer can see — so the sheet never completes on
// its own: we cancel it once the listener has the code, and treat any other completion as the
// user closing it.

import AuthenticationServices
import UIKit

@MainActor
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// Sign in to `provider` and store the resulting credentials. Throws `.cancelled` if the user
    /// closes the sheet.
    @discardableResult
    static func signIn(_ provider: OAuthProvider) async throws -> OAuthCredentials {
        let flow = OAuthSignIn()
        let credentials = try await flow.run(provider)
        OAuthTokenStore.shared.save(credentials, for: provider)
        return credentials
    }

    private var session: ASWebAuthenticationSession?

    /// An abandoned sheet would otherwise hold the callback port until it's dismissed.
    private static let deadline: Duration = .seconds(300)

    private func run(_ provider: OAuthProvider) async throws -> OAuthCredentials {
        let provider = await OAuthClient.resolved(provider)
        let verifier = PKCE.randomString()
        let state = PKCE.randomString(byteCount: 16)
        let url = OAuthClient.authorizeURL(for: provider, challenge: PKCE.challenge(for: verifier), state: state)

        let server = OAuthLoopbackServer(port: provider.redirectPort, path: provider.redirectPath, expectedState: state)
        defer {
            server.stop()
            session?.cancel()
            session = nil
        }

        let query: [URLQueryItem] = try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            do {
                try server.start(
                    onCallback: { query in resume.resume(.success(query)) },
                    onFailure: { error in resume.resume(.failure(error)) }
                )
            } catch {
                resume.resume(.failure(error))
                return
            }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
                // With no callback scheme this only fires when the sheet is dismissed — by the
                // user, or by us after the loopback callback (which already resumed).
                resume.resume(.failure(OAuthError.cancelled))
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                resume.resume(.failure(OAuthError.provider("couldn't open the sign-in page")))
            }
            Task {
                try? await Task.sleep(for: Self.deadline)
                resume.resume(.failure(OAuthError.timedOut))   // no-op if already finished
            }
        }

        let code = try OAuthClient.authorizationCode(from: query, expectedState: state)
        NSLog("[OAuth] %@ sign-in: got authorization code, exchanging", provider.id)
        return try await OAuthClient.exchange(code: code, verifier: verifier, provider: provider)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}

/// Resumes a continuation at most once — the loopback callback and the sheet's dismissal race.
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
