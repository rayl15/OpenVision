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
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)
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

        // Agentic web-search tool: the model calls it for current info, we run it, feed the result
        // back, and it can refine or answer — an iterative loop (OpenGlasses' cloud pattern).
        let webSearchTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current, real-time information — news, weather, prices, sports scores, recent events, or anything you're not certain of. Use it whenever the user asks about something current.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "The search query"]],
                    "required": ["query"]
                ]
            ]
        ]

        // Web search + on-device productivity tools (timers, reminders, calendar, notes, clipboard…).
        let tools = [webSearchTool] + NativeToolRegistry.shared.openAISpecs

        let maxIterations = 4
        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "model": settings.openAIModel,
                "messages": messages,
                "tools": tools,
                "max_tokens": 400
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60

            let (data, response) = try await Self.dataWithRetry(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenAIError.noResponse }
            guard (200...299).contains(http.statusCode) else {
                let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
                NSLog("[OpenAI] request failed: %@", detail)
                throw OpenAIError.api(detail)
            }
            guard let message = Self.firstMessage(from: data) else { throw OpenAIError.emptyReply }

            // Tool calls → execute (web_search or a native tool), feed results back, loop.
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                messages.append(message)   // the assistant turn carrying tool_calls
                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    let fn = call["function"] as? [String: Any]
                    let toolName = fn?["name"] as? String ?? ""
                    let argsStr = fn?["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]

                    let result: String
                    if toolName == "web_search" {
                        let query = (args["query"] as? String) ?? ""
                        NSLog("[OpenAI] web_search: \"%@\"", query)
                        let r = await WebSearchService.search(query)
                        result = r.isEmpty ? "No results found for \"\(query)\"." : r
                    } else {
                        NSLog("[OpenAI] native tool: %@", toolName)
                        result = await NativeToolRegistry.shared.execute(name: toolName, args: args)
                    }
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                }
                continue
            }

            // No tool call → final spoken answer.
            guard let reply = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw OpenAIError.emptyReply
            }
            ConversationContext.shared.record(user: text, assistant: reply)
            onAgentMessage?(reply)
            return
        }
        throw OpenAIError.api("search loop didn't converge")
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        // Keep replies short — they're spoken aloud. Append the user's custom instructions.
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var parts = ["You are OpenVision, a helpful voice assistant for smart glasses. Answer conversationally and briefly (1-3 short sentences) since your reply is spoken aloud. If the user asks about current or real-time information, or anything you're not certain of, call the web_search tool and answer from its results — never say you can't access real-time data.",
                     "You can also handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search notes auto-tagged with place and time), and copy_to_clipboard. For a specific time of day (e.g. '6pm', '9:30am') pass the tool's hour (24-hour) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for 'in N minutes'. The current time is \(today).",
                     "After a tool runs, briefly confirm what you did in one sentence."]
        let custom = settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Response parsing

    /// Chat Completions can drop a keep-alive connection between the multiple round-trips of a
    /// tool-calling loop (URLError -1005 "network connection lost", or a transient timeout). These
    /// are almost always recoverable, so retry once on a fresh connection before surfacing an error.
    private static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where
            [.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
            NSLog("[OpenAI] transient network error (%d) — retrying once", error.errorCode)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    /// The full assistant message dict (content and/or tool_calls) from a Chat Completions response.
    private static func firstMessage(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message
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
