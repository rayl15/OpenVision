// OpenVision - GrokService.swift
// Cloud backend for xAI Grok — with an xAI API key or a SuperGrok subscription sign-in.
//
// Grok's public API (api.x.ai/v1) is OpenAI-compatible Chat Completions, so the conversation,
// photos, web search and native tools all come from CloudChat; this file only adds auth.
//
// SuperGrok sign-in reuses the Grok CLI's public OAuth client (loopback redirect on
// 127.0.0.1:56121, endpoints from auth.x.ai's OIDC discovery). Its `api:access` scope makes the
// resulting token work as a bearer on the public API — verified against it with text, photos and
// tool calls. Only the sign-in is the CLI's integration surface; the API itself is documented.

import Foundation

@MainActor
final class GrokService: ObservableObject {

    static let shared = GrokService()

    nonisolated static let provider = OAuthProvider(
        id: "xai",
        displayName: "SuperGrok",
        authorizeURL: URL(string: "https://auth.x.ai/oauth2/authorize")!,
        tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!,
        clientId: "b1a00492-073a-47ea-816f-4c329264a828",
        scope: "openid profile email offline_access grok-cli:access api:access",
        // The Grok CLI client id is registered against this loopback redirect.
        redirectHost: "127.0.0.1",
        redirectPort: 56121,
        redirectPath: "/callback",
        refreshSkew: 120,
        discoveryURL: URL(string: "https://auth.x.ai/.well-known/openid-configuration")!,
        trustedHost: "x.ai"
    )

    nonisolated static let baseURL = "https://api.x.ai/v1"

    /// Fastest vision-capable Grok at the time of writing (~1s for a photo answer); latency
    /// matters most for a voice assistant. The alias (currently grok-4.20-0309-non-reasoning)
    /// follows xAI's updates, so a saved default doesn't go stale. Users can pick any model
    /// from the live list.
    nonisolated static let defaultModel = "grok-4.20-non-reasoning"

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": stateless HTTP, so just validate config.
    func connect() async throws {
        guard settings.isGrokConfigured else { throw GrokError.notConfigured }
        isConnected = true
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard settings.isGrokConfigured else { throw GrokError.notConfigured }
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        let model = settings.grokModel.isEmpty ? Self.defaultModel : settings.grokModel
        let reply = try await CloudChat.chatCompletionsReply(
            text: text, imageData: imageData, model: model, label: "Grok"
        ) { body in
            try await Self.send { bearer in
                var request = URLRequest(url: URL(string: "\(Self.baseURL)/chat/completions")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = 60
                return request
            }
        }
        ConversationContext.shared.record(user: text, assistant: reply)
        onAgentMessage?(reply)
    }

    // MARK: - Models

    /// Chat models the account can use.
    static func fetchModels() async throws -> [String] {
        let (data, response) = try await send { bearer in
            var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            return request
        }
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
            throw CloudChatError.api("Grok", CloudChat.errorMessage(from: data) ?? "couldn't load models")
        }
        return parseModels(data)
    }

    nonisolated static func parseModels(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return [] }
        // Chat models only: skip the image/video generators, voice models and the coding agent.
        return models.compactMap { $0["id"] as? String }.filter {
            !$0.contains("imagine") && !$0.hasPrefix("grok-voice") && !$0.hasPrefix("grok-build")
        }
    }

    // MARK: - Transport

    /// Send with the API key, or a fresh SuperGrok token — on 401, force one refresh and retry
    /// (the token may have been revoked or rotated before its stated expiry).
    /// `retryTransient: false` skips the one retry on a dropped connection or timeout, for requests
    /// where waiting twice is worse than failing (a voice clip in the middle of a reply).
    static func send(retryTransient: Bool = true,
                     _ makeRequest: (String) -> URLRequest) async throws -> (Data, URLResponse) {
        func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
            retryTransient ? try await CloudChat.dataWithRetry(for: request) : try await URLSession.shared.data(for: request)
        }
        let settings = SettingsManager.shared.settings
        guard settings.grokAuthMode == .superGrok else {
            return try await load(makeRequest(settings.grokAPIKey))
        }
        var credentials = try await OAuthTokenStore.shared.freshCredentials(for: provider)
        let (data, response) = try await load(makeRequest(credentials.accessToken))
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { return (data, response) }
        credentials = try await OAuthTokenStore.shared.freshCredentials(for: provider, force: true)
        return try await load(makeRequest(credentials.accessToken))
    }

    enum GrokError: LocalizedError {
        case notConfigured
        var errorDescription: String? {
            "Grok isn't configured. Add an xAI API key or sign in to SuperGrok in Settings → Grok."
        }
    }
}
