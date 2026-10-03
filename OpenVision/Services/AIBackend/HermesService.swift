// OpenVision - HermesService.swift
// Backend for a Hermes Agent server (Nous Research) through its OpenAI-compatible API server.
//
// Hermes is an agent, not a model: it runs its own tools (terminal, files, web search, memory,
// skills) on the machine it's installed on and answers with the result. So OpenVision offers it
// no tools of its own and sets no token cap, only a short "you're speaking through glasses"
// prompt, which Hermes layers on top of its own system prompt. Photos from the glasses go along
// as data: URLs, which the API server accepts on /v1/chat/completions.
//
// The server is the user's own (`hermes gateway` with API_SERVER_ENABLED, reached over the
// internet or a tailnet). Requests carry a stable X-Hermes-Session-Key so Hermes' long-term
// memory treats the glasses as one ongoing channel, like a Telegram or Discord chat.

import Foundation
import UIKit

@MainActor
final class HermesService: ObservableObject {

    static let shared = HermesService()

    /// Hermes ignores a bare `model` on the OpenAI-compatible endpoints unless the server opts in
    /// (`direct_model_requests`), so the advertised alias is safe to send: the server's own model
    /// configuration wins.
    nonisolated static let modelAlias = "hermes-agent"

    /// An agent run can use tools for a while, and the request isn't streamed.
    nonisolated static let requestTimeout: TimeInterval = 180

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": stateless HTTP, so just validate config.
    func connect() async throws {
        guard settings.isHermesConfigured else { throw HermesError.notConfigured }
        isConnected = true
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard settings.isHermesConfigured else { throw HermesError.notConfigured }
        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        if let command = HermesGatewayClient.spokenSlashCommand(text), imageData == nil {
            // "Ok Vision, slash usage": Hermes' slash commands, through the gateway.
            let reply = settings.hermesAuthMode == .password
                ? try await HermesGatewayClient.shared.runSlash(command)
                : "Slash commands need the Username and Password connection to Hermes."
            let spoken = ChatGPTSubscription.capForSpeech(reply)
            ConversationContext.shared.record(user: text, assistant: spoken)
            onAgentMessage?(spoken)
            return
        }

        if settings.hermesAuthMode == .password {
            // Web UI sign-in: chat over the gateway WebSocket, like Hermes Desktop.
            let reply = try await HermesGatewayClient.shared.ask(text, imageData: imageData)
            let spoken = ChatGPTSubscription.capForSpeech(reply)
            ConversationContext.shared.record(user: text, assistant: spoken)
            onAgentMessage?(spoken)
            return
        }

        guard let base = Self.apiBase(from: settings.hermesServerURL) else { throw HermesError.notConfigured }

        let key = settings.hermesAPIKey
        let sessionKey = Self.sessionKey
        let reply = try await CloudChat.chatCompletionsReply(
            text: text, imageData: imageData, model: Self.modelAlias, label: "Hermes",
            system: Self.systemPrompt(custom: settings.userPrompt),
            offerTools: false, maxTokens: nil
        ) { body in
            var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            Self.authorize(&request, key: key, sessionKey: sessionKey)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = Self.requestTimeout
            // No transient retry: a dropped connection mid-run may still have run the agent's
            // tools, and repeating the turn could repeat what they did.
            return try await URLSession.shared.data(for: request)
        }
        let spoken = ChatGPTSubscription.capForSpeech(reply)
        ConversationContext.shared.record(user: text, assistant: spoken)
        onAgentMessage?(spoken)
    }

    // MARK: - Connection test

    struct ServerInfo: Equatable {
        let model: String
    }

    /// GET /v1/capabilities: checks the URL, the key and that it's really a Hermes API server.
    static func testConnection(serverURL: String, apiKey: String) async throws -> ServerInfo {
        guard let base = apiBase(from: serverURL) else { throw HermesError.badURL }
        var request = URLRequest(url: base.appendingPathComponent("capabilities"))
        authorize(&request, key: apiKey, sessionKey: nil)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw HermesError.unauthorized }
        guard (200...299).contains(status) else {
            throw HermesError.server(CloudChat.errorMessage(from: data) ?? "HTTP \(status)")
        }
        guard let info = parseCapabilities(data) else { throw HermesError.notHermes }
        return info
    }

    nonisolated static func parseCapabilities(_ data: Data) -> ServerInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["object"] as? String)?.hasPrefix("hermes.") == true
                || json["platform"] as? String == "hermes-agent" else { return nil }
        return ServerInfo(model: json["model"] as? String ?? modelAlias)
    }

    /// Before opening the login sheet: is this a Hermes web UI that supports app sign-in? Reads
    /// the public /api/status (`auth_flows` lists "native_pkce" on gateways that do).
    static func checkAppSignIn(base: URL) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/status"))
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError.notHermes
        }
        if let problem = appSignInProblem(status: json) { throw HermesError.server(problem) }
    }

    /// Why app sign-in won't work for this /api/status, or nil if it will.
    nonisolated static func appSignInProblem(status: [String: Any]) -> String? {
        guard status["auth_required"] as? Bool == true else {
            return "this web UI has no login (it's only reachable on the server itself). Bind it to a reachable address with a username and password."
        }
        guard (status["auth_flows"] as? [String])?.contains("native_pkce") == true else {
            return "this Hermes version doesn't support signing in from apps. Update Hermes."
        }
        return nil
    }

    // MARK: - Helpers

    /// The `/v1` base for whatever the user typed: `https://host`, `https://host/v1`, a profile
    /// prefix (`https://host/p/work`), with or without a trailing slash. Nil if it isn't http(s).
    nonisolated static func apiBase(from serverURL: String) -> URL? {
        var text = withScheme(serverURL)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url.appendingPathComponent("v1")
    }

    /// Whether requests to this URL would cross the network unencrypted. The key grants the
    /// agent's tools (terminal included), so the settings screen warns about plain http unless
    /// the host is clearly local or on a tailnet.
    nonisolated static func isUnencryptedRemote(_ serverURL: String) -> Bool {
        guard let base = apiBase(from: serverURL), base.scheme?.lowercased() == "http",
              let host = base.host?.lowercased() else { return false }
        return !isLocalHost(host) && !host.hasSuffix(".ts.net")
    }

    /// Loopback, `.local`, or a private / Tailscale IPv4 address.
    nonisolated static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true   // Tailscale CGNAT range
        default: return false
        }
    }

    /// The address with a scheme, for one typed without (`myhost.ts.net`, `100.88.1.2:8642`):
    /// http for a local or Tailscale IP (servers there rarely have a certificate), https otherwise.
    nonisolated static func withScheme(_ address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("://") else { return text }
        let hostAndPort = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostAndPort.split(separator: ":").first.map(String.init) ?? hostAndPort
        return (isLocalHost(host) ? "http://" : "https://") + text
    }

    private static func authorize(_ request: inout URLRequest, key: String, sessionKey: String?) {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let sessionKey { request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key") }
    }

    /// Stable per install, so Hermes' memory sees one ongoing "OpenVision" channel.
    private static var sessionKey: String {
        "openvision:glasses:" + (UIDevice.current.identifierForVendor?.uuidString.lowercased() ?? "device")
    }

    /// Fallback for a Hermes gateway without the "voice-live" surface: prompt.submit has no
    /// system prompt, so the voice instructions ride along with each prompt instead.
    nonisolated static let voicePreamble = "(Spoken through OpenVision smart glasses: reply in 1-3 short sentences, no markdown.) "

    nonisolated static func systemPrompt(custom: String) -> String {
        var parts = ["The user is talking to you through OpenVision, a voice assistant on smart glasses. "
            + "Your reply is spoken aloud: answer conversationally in 1-3 short sentences, with no "
            + "markdown, lists or links. If they share a photo, it's what they're looking at."]
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    enum HermesError: LocalizedError, Equatable {
        case notConfigured, badURL, unauthorized, notHermes
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Hermes isn't configured. Add your server and sign in, or an API key, in Settings → Hermes."
            case .badURL: return "That isn't a server address. Enter one like hermes.example.com or 100.88.1.2:8642."
            case .unauthorized: return "The server rejected the API key. Use the API_SERVER_KEY from your Hermes server."
            case .notHermes: return "That address answered, but it isn't a Hermes API server."
            case .server(let detail): return "Hermes: \(detail)"
            }
        }
    }
}
