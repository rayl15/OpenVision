// OpenVision - LocalAgent.swift
// Shared agentic routing for the on-device text backends (Gemma via MLX, Apple Foundation Models).
//
// The prompts + parsing live here ONCE; each backend supplies a `generate(system, user)` closure.
// This keeps face-recognition + web-search routing identical across local models — no prompt drift.

import Foundation

@MainActor
enum LocalAgent {

    struct FaceIntent {
        let action: String   // "remember" | "identify" | "forget" | "list"
        let name: String     // person's name (may be empty for identify/list)
    }

    enum RouteResult {
        case face(FaceIntent)
        case webSearch(String)   // search query
        case answer(String)
    }

    /// A backend's generation primitive: (systemPrompt, priorTurns, userText) -> text (nil on failure).
    typealias Generate = (_ system: String, _ history: [ConversationContext.Turn], _ user: String) async -> String?

    /// ONE generation that either routes a face command, requests a web search, or answers directly.
    /// `history` gives the model recent turns so follow-up questions work.
    static func route(_ command: String, history: [ConversationContext.Turn], generate: Generate) async -> RouteResult {
        let system = """
        You are a voice assistant for smart glasses that can recognize faces the user has taught you.

        Face actions apply ONLY to a real person PHYSICALLY IN FRONT of the user right now (seen through the glasses camera). If the user names a person, or asks about a public/famous/historical figure, or asks a general "who is…" question, that is NOT a face action — answer it or search instead.

        If (and only if) the user wants a face action, reply with ONLY one JSON object and nothing else:
        - Identify the person currently in view: {"face":"identify","name":""}
        - Save/remember the person in view under a name: {"face":"remember","name":"THE_NAME"}
        - Forget a saved person: {"face":"forget","name":"THE_NAME"}
        - List the people you know: {"face":"list","name":""}

        Examples (face actions — someone is in front of the user):
        User: who is this → {"face":"identify","name":""}
        User: who is this person → {"face":"identify","name":""}
        User: who am I looking at → {"face":"identify","name":""}
        User: do you know this person in front of me → {"face":"identify","name":""}
        User: remember this is Sara → {"face":"remember","name":"Sara"}
        User: save his face as Alex → {"face":"remember","name":"Alex"}
        User: forget Sara → {"face":"forget","name":"Sara"}
        User: who do you know → {"face":"list","name":""}

        Examples (NOT face actions — answer or search, never a face action):
        User: who is Elon Musk → (answer normally)
        User: who is the prime minister of India → (search / answer)
        User: who won the match → (search)
        User: who wrote Hamlet → (answer normally)

        Use a web search if EITHER is true: the user asks about current/real-time information (news, weather, sports scores, prices, recent events), OR you don't know the answer, aren't fully confident, or your knowledge may be outdated. In that case reply with ONLY: {"tool":"web_search","query":"A_CONCISE_SEARCH_QUERY"}. Never tell the user you don't know without searching first.
        User: what's the weather in Tokyo → {"tool":"web_search","query":"weather in Tokyo"}
        User: who won the game last night → {"tool":"web_search","query":"latest game result"}
        User: what's the price of bitcoin → {"tool":"web_search","query":"bitcoin price"}
        User: who is the CEO of a small startup you don't know → {"tool":"web_search","query":"CEO of that startup"}

        Only answer directly (no search) when you are genuinely confident it's stable, well-known info — math, definitions, general facts. Then answer in 1-3 short sentences. Do NOT mention faces, tools, or JSON.
        """
        guard let output = await generate(system, history, command) else {
            return .answer("Sorry, I couldn't process that — please try again.")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[OV] route(\"%@\") -> %@", command, String(trimmed.prefix(120)))
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
           let data = String(trimmed[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let action = (obj["face"] as? String)?.lowercased(),
               ["remember", "identify", "forget", "list"].contains(action) {
                let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .face(FaceIntent(action: action, name: name))
            }
            if (obj["tool"] as? String)?.lowercased() == "web_search",
               let query = (obj["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                return .webSearch(query)
            }
        }
        return .answer(trimmed)
    }

    /// Phrase a concise spoken answer to `question` using a web-search `result`. Falls back to the
    /// model's own knowledge (flagged as uncertain) when the result is empty.
    static func answerWithSearchResult(question: String, result: String, generate: Generate) async -> String {
        let system = """
        You are a voice assistant for smart glasses. Use the web search result to answer the user's question in 1-3 short spoken sentences. If the result is empty or unrelated, answer from your own knowledge and briefly say you're not certain of the very latest details. Do not mention "search result" or JSON.
        """
        let context = result.isEmpty ? "(no web result found)" : result
        let user = "Question: \(question)\n\nWeb search result: \(context)"
        if let out = await generate(system, [], user),
           !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? "I couldn't find that right now." : result
    }
}

/// The surface VoiceAgentView needs from any on-device text model (Gemma or Apple).
@MainActor
protocol LocalTextLLM: AnyObject {
    func routeCommand(_ command: String) async -> LocalAgent.RouteResult
    func answerWithSearchResult(question: String, result: String) async -> String
}
