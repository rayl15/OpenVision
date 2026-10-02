// OpenVision - OpenAIService.swift
// Cloud backend for the OpenAI Chat Completions API (and any OpenAI-compatible endpoint), or a
// ChatGPT subscription via the Responses API (see ChatGPTSubscription).
//
// Simple request/response (non-streaming) — reliable for validating the cloud command + vision
// path. Supports text and images (base64 data URL). The reply is delivered via `onAgentMessage`,
// matching the other backends so VoiceAgentView can wire it up the same way. The prompt, tools and
// tool loop are shared with the other cloud chat backends (CloudChat).

import Foundation
import UIKit

@MainActor
final class OpenAIService: ObservableObject {

    static let shared = OpenAIService()

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": OpenAI is stateless HTTP, so just validate config.
    func connect() async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        isConnected = true
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        let reply: String
        if settings.openAIAuthMode == .chatGPTSubscription {
            reply = try await sendViaSubscription(text, imageData: imageData)
        } else {
            guard let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else {
                throw OpenAIError.badURL
            }
            let apiKey = settings.openAIAPIKey
            reply = try await CloudChat.chatCompletionsReply(
                text: text, imageData: imageData, model: settings.openAIModel, label: "OpenAI"
            ) { body in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = 60
                return try await CloudChat.dataWithRetry(for: request)
            }
        }
        ConversationContext.shared.record(user: text, assistant: reply)
        onAgentMessage?(reply)
    }

    // MARK: - ChatGPT subscription (Responses API)

    /// Same conversation, tools and loop as the Chat Completions path, sent to the ChatGPT
    /// subscription backend in Responses format.
    private func sendViaSubscription(_ text: String, imageData: Data?) async throws -> String {
        var instructions = CloudChat.systemPrompt()
        if let docContext = DocumentFocus.shared.contextForQuery(text) {
            instructions += "\n\n" + docContext
        }

        var input: [[String: Any]] = ConversationContext.shared.turns.map { turn in
            let type = turn.role == "assistant" ? "output_text" : "input_text"
            return ["role": turn.role, "content": [["type": type, "text": turn.content]]]
        }
        var userContent: [[String: Any]] = [["type": "input_text", "text": text.isEmpty && imageData != nil ? "Describe what you see." : text]]
        if let imageData {
            userContent.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"])
        }
        input.append(["role": "user", "content": userContent])

        let tools = ChatGPTSubscription.responsesTools(fromChatTools: CloudChat.toolSpecs())
        let model = settings.openAISubscriptionModel.isEmpty ? ChatGPTSubscription.defaultModel : settings.openAISubscriptionModel

        for _ in 0..<4 {
            let items = try await ChatGPTSubscription.respond(model: model, instructions: instructions, input: input, tools: tools)
            // Echo every item (reasoning included) back — the backend is stateless (store:false).
            input.append(contentsOf: items)

            let calls = items.filter { $0["type"] as? String == "function_call" }
            if !calls.isEmpty {
                for call in calls {
                    let result = await CloudChat.runTool(call["name"] as? String ?? "", arguments: call["arguments"] as? String)
                    input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "", "output": result])
                }
                continue
            }

            let reply = items
                .filter { $0["type"] as? String == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw CloudChatError.emptyReply("ChatGPT") }
            return ChatGPTSubscription.capForSpeech(reply)
        }
        throw CloudChatError.api("ChatGPT", "search loop didn't converge")
    }

    enum OpenAIError: LocalizedError {
        case notConfigured, badURL
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI isn't configured. Add an API key or sign in to ChatGPT in Settings → OpenAI."
            case .badURL: return "The OpenAI base URL is invalid."
            }
        }
    }
}
