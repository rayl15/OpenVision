// OpenVision - AppleFoundationService.swift
// On-device LLM via Apple's Foundation Models framework (Apple Intelligence).
//
// Unlike the MLX Gemma backend, this model is managed by the OS — no multi-GB download and no
// large per-process footprint, so it sidesteps the jetsam memory pressure entirely. Text-only.
// Requires iOS 26+ on Apple-Intelligence-capable hardware (iPhone 15 Pro and newer).
//
// Mirrors OpenGlasses' integration: SystemLanguageModel.default.availability +
// LanguageModelSession(instructions:).respond(to:).

import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels

/// Structured routing decision — Apple's model fills this via guided generation. Far more reliable
/// than prompting an aligned chat model to emit raw JSON (which it refuses, answering instead).
@available(iOS 26.0, *)
@Generable
struct AppleRouteDecision {
    @Guide(description: "One of: identify, remember, forget, list, other")
    let action: String
    @Guide(description: "The person's name — only for remember or forget, otherwise empty")
    let name: String
}

/// Native web-search tool for Apple's model. Because the model calls this itself and treats the
/// result as its OWN retrieval, it produces a grounded answer instead of "my knowledge ends in 2023".
@available(iOS 26.0, *)
struct AppleWebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information: news, weather, prices, sports scores, and recent events. Use whenever the user asks about anything current."

    @Generable
    struct Arguments {
        @Guide(description: "The search query")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = await WebSearchService.search(arguments.query)
        return result.isEmpty ? "No web results found for \"\(arguments.query)\"." : result
    }
}
#endif

@MainActor
final class AppleFoundationService: ObservableObject, LocalTextLLM {

    static let shared = AppleFoundationService()

    var onAgentMessage: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    /// Persistent answer session (type-erased so the property isn't iOS-26-gated). Reused across
    /// turns so Apple's model keeps conversation context natively. Cleared per session.
    private var answerSessionBox: Any?

    private init() {}

    /// Drop the conversation context — call when a new voice session starts.
    func resetContext() { answerSessionBox = nil }

    // MARK: - Availability

    /// nil when Apple Intelligence is ready; otherwise a user-facing reason.
    var availabilityMessage: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    return "Apple Intelligence is still downloading — try again shortly."
                @unknown default:
                    return "Apple Intelligence is unavailable right now."
                }
            @unknown default:
                return "Apple Intelligence is unavailable right now."
            }
        } else {
            return "Apple Intelligence requires iOS 26 or later."
        }
        #else
        return "This build was compiled without Apple Intelligence support."
        #endif
    }

    var isAvailable: Bool { availabilityMessage == nil }

    /// Lightweight connect — the OS manages the model, so we just verify availability.
    func connect() async throws {
        if let reason = availabilityMessage { throw AppleFMError.unavailable(reason) }
        isConnected = true
    }

    // MARK: - Model limits

    /// The system model's context window. iOS 27 reports 8,192 tokens (iOS 26's model had 4,096);
    /// iOS before 26.4 can't report it, so assume the smaller window there.
    var modelContextTokens: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4_096
    }

    /// Whether the system model supports a language (locale id like "hi_IN"; nil = the phone's).
    func supportsLanguage(_ localeID: String?) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.supportsLocale(localeID.map { Locale(identifier: $0) } ?? .current)
        }
        #endif
        return false
    }

    // MARK: - Core generation

    /// One-shot generation: `system` becomes the session instructions, `user` the prompt.
    func generate(system: String, user: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard isAvailable else { return nil }
            guard UIApplication.shared.applicationState != .background else { return nil }
            do {
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(to: user)
                return response.content
            } catch {
                NSLog("[OV] Apple FM generate failed: %@", "\(error)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - LocalTextLLM (routing via Apple guided generation)

    private static let routingInstructions = """
    You are a router for a smart-glasses voice assistant. Face actions apply ONLY to a real person physically in front of the user right now (seen through the glasses camera) — NOT to named, famous, or historical people, and NOT to general "who is…" questions. Classify the user's request into one action:
    - identify: who is the person IN FRONT of me right now ("who is this", "who is this person", "who am I looking at")
    - remember: save the face of the person in view under a name (extract the name)
    - forget: remove a saved person (extract the name)
    - list: list the people you know
    - other: anything else — a question, chat, a request for current info, or any "who is <named or famous person>" (e.g. "who is Elon Musk", "who is the president")

    When unsure, choose "other". Only pick a face action when the user clearly means a person physically present.

    Questions about documents, letters, manuals, recipes, or their contents are NEVER face actions — always "other". This includes "who is the document addressing", "the person's name in the document/letter", and "summarize the letter": the person is named IN TEXT, not standing in front of the user.
    """

    private static func assistantInstructions() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        return """
    You are OpenVision, a helpful voice assistant for smart glasses. Answer briefly (1-3 short sentences) since your reply is spoken aloud.

    The current date and time is \(now) in the user's local time zone. For a specific time of day (e.g. "6pm", "9:30am") pass the tool's hour (24-hour form) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for "in N minutes / from now". Never compute an absolute date yourself.

    You have a web_search tool with live internet access. Use it whenever EITHER is true:
    - the user asks about current or real-time information (news, weather, prices, sports scores, recent events), OR
    - you are not fully confident in your answer, you don't know, or your knowledge might be outdated or incomplete.

    NEVER tell the user you don't know, that you can't help, or that your knowledge ends at a past date. Always run web_search first and answer from the results. Prefer searching over guessing. Only answer directly, without searching, when you are genuinely confident the information is stable and well-known (e.g. math, definitions, general facts). EXCEPTION: questions about the user's own documents (their letter, manual, recipe) are answered from search_docs or the provided excerpts — never from web_search; the web knows nothing about their personal documents.

    CRITICAL: web_search returns its results immediately, inside this same reply. You must read those results and give the final answer now. NEVER say you will search "later", "shortly", "in a moment", or provide the answer "once it's available" — there is no later; this is your only turn. If the search returns nothing useful, simply say you couldn't find that right now — do not promise to follow up.

    You can also handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search/list notes auto-tagged with place and time), copy_to_clipboard, search_docs (search the user's imported manuals/recipes/guides — use it whenever they ask about their documents, and answer only from what it returns), and meetings (the user's recorded meeting notes — use it for questions about their meetings, decisions or action items). After a tool runs, briefly confirm what you did in one sentence.
    """
    }

    #if canImport(FoundationModels)
    /// The persistent web-search-equipped answer session (kept across turns for conversation
    /// memory), created on demand. Callers discard `answerSessionBox` and call again to retry
    /// with a fresh session after a generation failure.
    @available(iOS 26.0, *)
    private func answerSession() -> LanguageModelSession {
        if let existing = answerSessionBox as? LanguageModelSession { return existing }
        var tools: [any Tool] = [AppleWebSearchTool()]
        tools.append(contentsOf: AppleNativeTools.all)
        let session = LanguageModelSession(tools: tools, instructions: Self.assistantInstructions())
        answerSessionBox = session
        return session
    }
    #endif

    func routeCommand(_ command: String) async -> LocalAgent.RouteResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable, UIApplication.shared.applicationState != .background {
            do {
                // 1) Guided face-intent check (structured — reliable).
                let router = LanguageModelSession(instructions: Self.routingInstructions)
                let decision = try await router.respond(to: command, generating: AppleRouteDecision.self).content
                let action = decision.action.lowercased()
                NSLog("[OV] Apple route -> action=%@ name=%@", action, decision.name)
                if ["identify", "remember", "forget", "list"].contains(action) {
                    return .face(.init(action: action, name: decision.name))
                }
                // 2) Everything else → answer with a web-search-equipped session that PERSISTS
                //    across turns, so the model keeps conversation context (follow-up questions
                //    work) and calls web_search itself when it needs live info.
                // Record the utterance so the tool registry's relative-time guard can override
                // model-computed clock times ("15 minutes from now" is parsed from these words).
                NativeToolContext.shared.set(command)
                // Document-focus mode: while the user works with a document, its relevant
                // excerpts ride along on every request.
                var prompt = command
                if let docContext = DocumentFocus.shared.contextForQuery(command) {
                    prompt = docContext + "\n\nUser request: " + command
                }
                do {
                    let response = try await answerSession().respond(to: prompt)
                    return .answer(response.content)
                } catch {
                    // The cached session fails transiently (com.apple.tokengeneration Code=10)
                    // and permanently once its accumulated transcript nears the 4096-token
                    // window. Either way the cure is the same: discard it and retry ONCE with a
                    // fresh session — losing conversation memory but keeping tools, so a
                    // web-search answer still comes from live results instead of the old
                    // fallback's from-memory reply.
                    NSLog("[OV] Apple answer session failed (%@) — retrying with a fresh session", "\(error)")
                    answerSessionBox = nil
                    let response = try await answerSession().respond(to: prompt)
                    return .answer(response.content)
                }
            } catch {
                NSLog("[OV] Apple route failed: %@", "\(error)")
                // Last-resort fallback (no tools). Must keep document grounding: without it, a
                // context overflow on a document question produced a confident "I don't have
                // access to any document."
                var user = command
                if let docContext = DocumentFocus.shared.contextForQuery(command) {
                    user = docContext + "\n\nUser request: " + command
                }
                let answer = await generate(system: Self.assistantInstructions(), user: user)
                return .answer(answer ?? "Sorry, I couldn't answer that right now.")
            }
        }
        #endif
        return .answer(availabilityMessage ?? "Apple Intelligence isn't available right now.")
    }

    func answerWithSearchResult(question: String, result: String) async -> String {
        // Plain natural-language summary works fine on Apple's model.
        await LocalAgent.answerWithSearchResult(question: question, result: result) { [weak self] prompt, _, user in
            await self?.generate(system: prompt.combined, user: user)
        }
    }

    func reformulateSearchQuery(question: String, triedQuery: String) async -> String? {
        // Apple's routeCommand searches via its native tool loop, so this is rarely hit — but keep
        // it for protocol conformance and any direct .webSearch routing.
        let out = await generate(system: LocalAgent.reformulateSystemPrompt,
                                 user: "User's question: \(question)\nQuery that found nothing: \(triedQuery)")
        return LocalAgent.cleanReformulatedQuery(out, triedQuery: triedQuery)
    }

    // MARK: - Direct chat (fallback path)

    func sendMessage(_ text: String) async {
        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }
        let system = "You are OpenVision, a helpful voice assistant for smart glasses. Answer conversationally and briefly (1-3 short sentences) since your reply is spoken aloud."
        let reply = await generate(system: system, user: text) ?? "Sorry, I couldn't answer that right now."
        onAgentMessage?(reply)
    }

    func interrupt() { /* single request/response — nothing to cancel */ }

    enum AppleFMError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let m): return m }
        }
    }
}
