// OpenVision - OpenAIService.swift
// Cloud backend for the OpenAI Chat Completions API (and any OpenAI-compatible endpoint).
//
// Simple request/response (non-streaming) — reliable for validating the cloud command + vision
// path. Supports text and images (base64 data URL). The reply is delivered via `onAgentMessage`,
// matching the other backends so VoiceAgentView can wire it up the same way.

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
        guard let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else {
            throw OpenAIError.badURL
        }

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        // Build the user content: plain string for text-only, or the multimodal array with an
        // image_url data URL when a photo is attached.
        let userContent: Any
        if let imageData {
            let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
            userContent = [
                ["type": "text", "text": text.isEmpty ? "Describe what you see." : text],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]
        } else {
            userContent = text
        }

        var messages: [[String: Any]] = []
        let system = systemPrompt()
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        // Prior turns so follow-up questions work ("what's its population?").
        for turn in ConversationContext.shared.turns {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": settings.openAIModel,
            "messages": messages,
            "max_tokens": 300
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw OpenAIError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            NSLog("[OpenAI] request failed: %@", detail)
            throw OpenAIError.api(detail)
        }

        guard let reply = Self.firstMessageContent(from: data), !reply.isEmpty else {
            throw OpenAIError.emptyReply
        }
        ConversationContext.shared.record(user: text, assistant: reply)
        onAgentMessage?(reply)
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        // Keep replies short — they're spoken aloud. Append the user's custom instructions.
        var parts = ["You are OpenVision, a helpful voice assistant for smart glasses. Answer conversationally and briefly (1-3 short sentences) since your reply is spoken aloud."]
        let custom = settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Response parsing

    private static func firstMessageContent(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    enum OpenAIError: LocalizedError {
        case notConfigured, badURL, noResponse, emptyReply, api(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI isn't configured. Add your API key in Settings → OpenAI."
            case .badURL: return "The OpenAI base URL is invalid."
            case .noResponse: return "No response from OpenAI."
            case .emptyReply: return "OpenAI returned an empty reply."
            case .api(let detail): return "OpenAI error: \(detail)"
            }
        }
    }
}
