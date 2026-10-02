// OpenVision - CloudChat.swift
// Conversation plumbing shared by the cloud chat backends (OpenAI, Grok): the system prompt, the
// tool set, tool execution, and the Chat Completions tool-calling loop.
//
// Each backend only supplies where to send a request and how to authenticate it (`send`), so a
// new OpenAI-compatible provider gets history, photos, document focus, web search and the native
// productivity tools for free.

import Foundation

@MainActor
enum CloudChat {

    /// Runs the Chat Completions loop for one user turn and returns the spoken reply. `send`
    /// performs a single POST of the given JSON body and returns the raw response.
    static func chatCompletionsReply(
        text: String,
        imageData: Data?,
        model: String,
        label: String,
        send: (Data) async throws -> (Data, URLResponse)
    ) async throws -> String {
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
        // Document-focus mode: while the user is working with a document, its most relevant
        // excerpts ride along on EVERY request — deterministic grounding, no tool-call judgment.
        if let docContext = DocumentFocus.shared.contextForQuery(text) {
            messages.append(["role": "system", "content": docContext])
        }
        // Prior turns so follow-up questions work ("what's its population?").
        for turn in ConversationContext.shared.turns {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userContent])

        let tools = toolSpecs()

        let maxIterations = 4
        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": tools,
                "max_tokens": 400
            ]
            let (data, response) = try await send(try JSONSerialization.data(withJSONObject: body))
            guard let http = response as? HTTPURLResponse else { throw CloudChatError.noResponse(label) }
            guard (200...299).contains(http.statusCode) else {
                let detail = errorMessage(from: data) ?? "HTTP \(http.statusCode)"
                NSLog("[%@] request failed: %@", label, detail)
                throw CloudChatError.api(label, detail)
            }
            guard let message = firstMessage(from: data) else { throw CloudChatError.emptyReply(label) }

            // Tool calls → execute (web_search or a native tool), feed results back, loop.
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                messages.append(message)   // the assistant turn carrying tool_calls
                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    let fn = call["function"] as? [String: Any]
                    let toolName = fn?["name"] as? String ?? ""
                    let result = await runTool(toolName, arguments: fn?["arguments"] as? String)
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                }
                continue
            }

            // No tool call → final spoken answer.
            guard let reply = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw CloudChatError.emptyReply(label)
            }
            return reply
        }
        throw CloudChatError.api(label, "search loop didn't converge")
    }

    // MARK: - Prompt

    static func systemPrompt() -> String {
        // Keep replies short — they're spoken aloud. Append the user's custom instructions.
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var parts = ["You are OpenVision, a helpful voice assistant for smart glasses. Answer conversationally and briefly (1-3 short sentences) since your reply is spoken aloud. If the user asks about current or real-time information, or anything you're not certain of, call the web_search tool and answer from its results — never say you can't access real-time data.",
                     "You can also handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search notes auto-tagged with place and time), copy_to_clipboard, and search_docs (search the user's imported manuals/recipes/guides — use it whenever they ask about their documents, and answer only from what it returns). For a specific time of day (e.g. '6pm', '9:30am') pass the tool's hour (24-hour) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for 'in N minutes'. The current time is \(today).",
                     "After a tool runs, briefly confirm what you did in one sentence."]
        let custom = SettingsManager.shared.settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Tools

    /// Agentic web search + on-device productivity tools (timers, reminders, calendar, notes,
    /// clipboard…), in Chat Completions format.
    static func toolSpecs() -> [[String: Any]] {
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
        return [webSearchTool] + NativeToolRegistry.shared.openAISpecs
    }

    /// Execute one tool call (web_search or a native tool) and return its result text.
    static func runTool(_ toolName: String, arguments: String?) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data((arguments ?? "{}").utf8))) as? [String: Any] ?? [:]
        if toolName == "web_search" {
            let query = (args["query"] as? String) ?? ""
            NSLog("[CloudChat] web_search: \"%@\"", query)
            let r = await WebSearchService.search(query)
            return r.isEmpty ? "No results found for \"\(query)\"." : r
        }
        NSLog("[CloudChat] native tool: %@", toolName)
        return await NativeToolRegistry.shared.execute(name: toolName, args: args)
    }

    // MARK: - Transport

    /// Chat Completions can drop a keep-alive connection between the multiple round-trips of a
    /// tool-calling loop (URLError -1005 "network connection lost", or a transient timeout). These
    /// are almost always recoverable, so retry once on a fresh connection before surfacing an error.
    nonisolated static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where
            [.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
            NSLog("[CloudChat] transient network error (%d) — retrying once", error.errorCode)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    /// The full assistant message dict (content and/or tool_calls) from a Chat Completions response.
    nonisolated static func firstMessage(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message
    }

    nonisolated static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        // xAI returns {"error": "…"} / {"code": …, "error": "…"} with a plain string.
        return obj["error"] as? String
    }
}

enum CloudChatError: LocalizedError {
    case noResponse(String)
    case emptyReply(String)
    case api(String, String)

    var errorDescription: String? {
        switch self {
        case .noResponse(let label): return "No response from \(label)."
        case .emptyReply(let label): return "\(label) returned an empty reply."
        case .api(let label, let detail): return "\(label) error: \(detail)"
        }
    }
}
