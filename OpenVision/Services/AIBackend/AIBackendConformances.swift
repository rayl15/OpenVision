// OpenVision - AIBackendConformances.swift
// AIBackend conformances for the seven services, in one place so the adapters are easy to audit.
//
// Five services (OpenClaw, OpenAI, Grok, Hermes, Gemma) already match the protocol surface and conform for
// free; Apple Intelligence and Gemini Live get thin adapters where their native APIs differ.

import Foundation

// MARK: - OpenClaw

extension OpenClawService: AIBackend {
    var backendType: AIBackendType { .openClaw }
    var supportsImageInput: Bool { true }
}

// MARK: - OpenAI

extension OpenAIService: AIBackend {
    var backendType: AIBackendType { .openAI }
    var supportsImageInput: Bool { true }

    func completeText(system: String, prompt: String) async throws -> String? {
        let settings = SettingsManager.shared.settings
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        if settings.openAIAuthMode == .chatGPTSubscription {
            let model = settings.openAISubscriptionModel.isEmpty ? ChatGPTSubscription.defaultModel : settings.openAISubscriptionModel
            let items = try await ChatGPTSubscription.respond(
                model: model, instructions: system,
                input: [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
                tools: [])
            let text = items
                .filter { $0["type"] as? String == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                .joined()
            guard !text.isEmpty else { throw CloudChatError.emptyReply("ChatGPT") }
            return text
        }
        guard let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else { throw OpenAIError.badURL }
        let apiKey = settings.openAIAPIKey
        return try await PlainCompletion.chat(model: settings.openAIModel, system: system, prompt: prompt, label: "OpenAI") { body in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            request.timeoutInterval = 120
            return try await CloudChat.dataWithRetry(for: request)
        }
    }
}

// MARK: - Grok

extension GrokService: AIBackend {
    var backendType: AIBackendType { .grok }
    var supportsImageInput: Bool { true }

    func completeText(system: String, prompt: String) async throws -> String? {
        let settings = SettingsManager.shared.settings
        guard settings.isGrokConfigured else { throw GrokError.notConfigured }
        let model = settings.grokModel.isEmpty ? Self.defaultModel : settings.grokModel
        return try await PlainCompletion.chat(model: model, system: system, prompt: prompt, label: "Grok") { body in
            try await Self.send { bearer in
                var request = URLRequest(url: URL(string: "\(Self.baseURL)/chat/completions")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = 120
                return request
            }
        }
    }
}

// MARK: - Hermes

extension HermesService: AIBackend {
    var backendType: AIBackendType { .hermes }
    var supportsImageInput: Bool { true }
}

// MARK: - Local Gemma (MLX)

extension GemmaLocalService: AIBackend {
    var backendType: AIBackendType { .localGemma }
    var supportsImageInput: Bool { true }
    var localLLM: LocalTextLLM? { self }
    /// Small MLX models; sized like the original Apple model so long input is split safely.
    var textContextTokens: Int? { 4_096 }
    // completeText is implemented in GemmaLocalService.swift (it needs the private model container).
}

// MARK: - Apple Intelligence

extension AppleFoundationService: AIBackend {
    var backendType: AIBackendType { .appleFoundation }
    var localLLM: LocalTextLLM? { self }
    var textContextTokens: Int? { modelContextTokens }
    func canWriteLanguage(_ localeID: String?) -> Bool { supportsLanguage(localeID) }

    func completeText(system: String, prompt: String) async throws -> String? {
        if let reason = availabilityMessage { throw AppleFMError.unavailable(reason) }
        guard let text = await generate(system: system, user: prompt) else {
            throw AppleFMError.unavailable("Apple Intelligence couldn't answer. It only runs while the app is open.")
        }
        return text
    }

    /// Text-only backend — sends the prompt and ignores the image (supportsImageInput is false,
    /// so callers route photo commands elsewhere).
    func sendMessage(_ text: String, imageData: Data?) async throws {
        await sendMessage(text)
    }
}

// MARK: - Gemini Live

extension GeminiLiveService: AIBackend {
    var backendType: AIBackendType { .geminiLive }

    /// Gemini Live is a streaming session: replies arrive via onOutputTranscription /
    /// onTurnComplete (wired by the voice agent), not a whole-message callback — so the
    /// request/response callbacks are intentionally inert here.
    var onAgentMessage: ((String) -> Void)? {
        get { nil }
        set {}
    }
    var onProcessingChanged: ((Bool) -> Void)? {
        get { nil }
        set {}
    }

    /// Video frames stream continuously in live mode; a "message" is just a text turn.
    func sendMessage(_ text: String, imageData: Data?) async throws {
        try await sendText(text)
    }

    /// The Live socket is for audio, so one-off text goes to the regular REST API with the same key.
    func completeText(system: String, prompt: String) async throws -> String? {
        let key = SettingsManager.shared.settings.geminiAPIKey
        guard !key.isEmpty else { throw AIBackendError.notConfigured }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Constants.GeminiLive.textModelName):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
        ])
        let (data, response) = try await CloudChat.dataWithRetry(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw CloudChatError.api("Gemini", message ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let parts = ((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = (parts ?? []).compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw CloudChatError.emptyReply("Gemini") }
        return text
    }
}

// MARK: - Plain Chat Completions (no history, tools or document context)

@MainActor
enum PlainCompletion {
    static func chat(model: String, system: String, prompt: String, label: String,
                     send: (Data) async throws -> (Data, URLResponse)) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "max_tokens": 1500,
        ]
        let (data, response) = try await send(try JSONSerialization.data(withJSONObject: body))
        guard let http = response as? HTTPURLResponse else { throw CloudChatError.noResponse(label) }
        guard (200...299).contains(http.statusCode) else {
            throw CloudChatError.api(label, CloudChat.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        guard let text = (CloudChat.firstMessage(from: data)?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw CloudChatError.emptyReply(label)
        }
        return text
    }
}
