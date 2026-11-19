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

    /// The system prompt, split by whether it changes between turns.
    ///
    /// The split exists for KV prefix caching: a backend can prefill `stable` once and reuse that
    /// cache on every turn, which is the difference between paying ~3s of prompt prefill per turn
    /// and paying it once. Anything that varies — the clock, focused-document excerpts — must sit
    /// AFTER the cached region or it invalidates everything downstream of it.
    ///
    /// Backends that don't cache simply concatenate the two and behave exactly as before.
    struct Prompt {
        /// Identical every turn for a given `PromptDetail`: rules, tool schemas, examples.
        let stable: String
        /// Varies per turn: current time, focused-document excerpts. Empty when there is none.
        let perTurn: String

        /// The whole prompt as one string — for backends with no caching.
        var combined: String {
            perTurn.isEmpty ? stable : stable + "\n\n" + perTurn
        }
    }

    /// A backend's generation primitive: (prompt, priorTurns, userText) -> text (nil on failure).
    typealias Generate = (_ prompt: Prompt, _ history: [ConversationContext.Turn], _ user: String) async -> String?

    /// How much hand-holding the routing prompt gives the model.
    ///
    /// This is a LATENCY knob, not a style one. The prompt is re-prefilled on every turn, and
    /// prefill is compute-bound: telemetry put time-to-first-token at ~5s of a ~6.4s wait on
    /// Bonsai-8B, against ~2s of actual decode at 30 tok/s. The verbose prompt is ~6,850
    /// characters, most of it worked examples.
    ///
    /// Those examples exist because Gemma 4 E2B (2B effective) mis-routed without them — three
    /// prompt iterations failed to stop it treating "is <name> authorized" as a face action. A
    /// stronger model doesn't need them, and shouldn't pay seconds per turn for them.
    enum PromptDetail {
        /// Full worked examples. Correct default for small models; unchanged from what shipped.
        case verbose
        /// Rules and tool schemas only. For models big enough to generalise from them (~7B+).
        case concise
    }

    /// ONE generation that either routes a face command, requests a web search, or answers directly.
    /// `history` gives the model recent turns so follow-up questions work.
    ///
    /// `detail` defaults to `.verbose` so any caller that hasn't been assessed keeps today's
    /// behaviour — opting a model in is a deliberate act.
    static func route(_ command: String, history: [ConversationContext.Turn],
                      detail: PromptDetail = .verbose, generate: Generate) async -> RouteResult {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        // Document-focus mode: while the user works with a document, its relevant excerpts ride
        // along on every request — in the PER-TURN section, since they change with the query.
        //
        // Timed because it sits inside commit→first-token, the window that dominates latency.
        // KV prefix caching barely moved that window, which disproved the assumption that it was
        // mostly prompt prefill — so every other step in here is now a suspect.
        let docStart = Date()
        let docContext = await DocumentFocus.shared.contextForQuery(command)
        let docElapsed = Date().timeIntervalSince(docStart)
        if docElapsed > 0.05 {
            NSLog("[OV] ttft breakdown: docContext %.3fs", docElapsed)
        }
        let stable = detail == .concise ? concisePrompt() : """
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

        Questions about documents, letters, manuals, recipes, or their contents are NEVER face actions — the person is named IN TEXT, not standing in front of the user. Answer from the document excerpts (if provided below) or use the search_docs tool:
        User: is Mansi authorized in this letter → (answer from the document)
        User: who exactly is authorized in my document → (answer from the document)
        User: whose name is in the letter → (answer from the document)
        User: summarize the authorization letter → (answer from the document)
        User: is Mansi Kumari authorized to collect my belongings → (answer from the document)

        NEVER choose "identify" when the user's request already NAMES a person — identify exists only for an UNKNOWN person physically present ("who is this"). A named person means the question is about a document, general knowledge, or a search — never a face action.

        Use a web search if EITHER is true: the user asks about current/real-time information (news, weather, sports scores, prices, recent events), OR you don't know the answer, aren't fully confident, or your knowledge may be outdated. In that case reply with ONLY: {"tool":"web_search","query":"A_CONCISE_SEARCH_QUERY"}. Never tell the user you don't know without searching first.
        User: what's the weather in Tokyo → {"tool":"web_search","query":"weather in Tokyo"}
        User: who won the game last night → {"tool":"web_search","query":"latest game result"}
        User: what's the price of bitcoin → {"tool":"web_search","query":"bitcoin price"}
        User: who is the CEO of a small startup you don't know → {"tool":"web_search","query":"CEO of that startup"}

        You can also perform on-device actions. When the user clearly wants one, reply with ONLY one JSON object and nothing else:
        - Timer: {"tool":"set_timer","seconds":300,"label":"pasta"}   (label optional)
        - Pomodoro: {"tool":"start_pomodoro"}
        - Reminder (clock time): {"tool":"create_reminder","title":"call mom","hour":17}
        - Reminder (relative): {"tool":"create_reminder","title":"leave","minutes_from_now":20}
        - Calendar add (clock time): {"tool":"calendar","action":"add","title":"Focus","hour":15,"duration_minutes":25}
        - Calendar read: {"tool":"calendar","action":"today"}   (or "upcoming")
        - Note save: {"tool":"note","action":"save","content":"parked in lot B"}
        - Note search: {"tool":"note","action":"search","query":"parking"}
        - Copy text: {"tool":"copy_to_clipboard","text":"the text to copy"}
        - Document search (the user's imported manuals/recipes/guides): {"tool":"search_docs","action":"search","query":"router error 5"}
        - Open/focus a document to work with it: {"tool":"search_docs","action":"focus","query":"router manual"}
        - Close the open document: {"tool":"search_docs","action":"unfocus"}
        - Recorded meetings: {"tool":"meetings","action":"latest"}   (or "list", "action_items", or "search" with "query")
        TIME RULES (the tool does the date math — never compute a date or minute count yourself):
        - A specific time of day like "6pm", "9:30am", "at 6" → give "hour" in 24-hour form (6pm=18, 9am=9) and "minute" if any; add "day_offset":1 for tomorrow.
        - Only "in N minutes/hours from now" → give "minutes_from_now".
        Action examples:
        User: set a 5 minute timer → {"tool":"set_timer","seconds":300}
        User: remind me to go to the gym at 6pm → {"tool":"create_reminder","title":"go to the gym","hour":18}
        User: remind me to leave in 20 minutes → {"tool":"create_reminder","title":"leave","minutes_from_now":20}
        User: add a meeting tomorrow at 9:30am → {"tool":"calendar","action":"add","title":"meeting","hour":9,"minute":30,"day_offset":1}
        User: what's on my calendar today → {"tool":"calendar","action":"today"}
        User: note that I parked in lot B → {"tool":"note","action":"save","content":"parked in lot B"}
        User: what does my manual say about error 5 → {"tool":"search_docs","action":"search","query":"error 5"}
        User: how long does the recipe say to bake it → {"tool":"search_docs","action":"search","query":"baking time"}
        User: open my router manual → {"tool":"search_docs","action":"focus","query":"router manual"}
        User: what did we decide in the meeting → {"tool":"meetings","action":"latest"}
        User: let's work with the lasagna recipe → {"tool":"search_docs","action":"focus","query":"lasagna recipe"}
        User: close the document → {"tool":"search_docs","action":"unfocus"}

        Only answer directly (no search or action) when you are genuinely confident it's stable, well-known info — math, definitions, general facts. Then answer in 1-3 short sentences. Do NOT mention faces, tools, or JSON.

        You DO have conversation memory: the earlier messages in this chat are your record of the conversation so far. Use them for follow-ups — e.g. for "what were we talking about?" summarize those earlier messages; for "what about X?" resolve it against the previous topic. Never claim you can't remember when earlier messages exist.
        """
        // Everything that changes between turns lives here, AFTER the cacheable region: the clock
        // (a timestamp mid-prompt would invalidate every token following it) and the focused
        // document's excerpts, which are selected per query.
        var perTurn = "The current time is \(now)."
        if let docContext { perTurn += "\n\n" + docContext }
        let prompt = Prompt(stable: stable, perTurn: perTurn)

        guard let output = await generate(prompt, history, command) else {
            return .answer("Sorry, I couldn't process that — please try again.")
        }

        let result = await resolve(output, command: command)

        // Focused-document override (deterministic — prompt rules alone failed 3× on device):
        // the small local model persistently misroutes "is <name> authorized …" to face-identify.
        // While a document is FOCUSED, an identify with no physical-presence cue in the command is
        // a document question — answer it from the excerpts instead of firing the camera.
        if case .face(let intent) = result, intent.action == "identify", let docContext {
            let lower = command.lowercased()
            let presenceCues = ["this person", "in front", "looking at", "this face",
                                "who is this", "who am i looking"]
            if !presenceCues.contains(where: { lower.contains($0) }) {
                NSLog("[OV] route override: identify → document answer (focus active, no presence cue)")
                // One-off prompt with document excerpts baked in — not worth caching, and the
                // excerpts change per query anyway, so it all goes in the per-turn half.
                let answerPrompt = Prompt(
                    stable: "You are a voice assistant for smart glasses. Answer briefly "
                        + "(1-3 short sentences) since your reply is spoken aloud.",
                    perTurn: docContext
                )
                if let answer = await generate(answerPrompt, history, command) {
                    return .answer(answer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return result
    }

    /// Rules-only routing prompt for models strong enough to generalise without worked examples.
    ///
    /// Every RULE from the verbose prompt is preserved — what's dropped is the ~40 example lines.
    /// The two must be kept in behavioural sync: if a routing rule changes, change it here too.
    /// They are deliberately separate literals rather than one built from parts, because the
    /// verbose text is hard-won (three on-device iterations) and must not shift by accident.
    private static func concisePrompt() -> String {
        """
        You are a voice assistant for smart glasses that can recognize faces the user has taught you.

        FACE ACTIONS — only for an UNKNOWN person PHYSICALLY IN FRONT of the user right now, seen through the camera. Reply with ONLY one JSON object:
        - {"face":"identify","name":""} — who is this person in view
        - {"face":"remember","name":"THE_NAME"} — save the person in view
        - {"face":"forget","name":"THE_NAME"}
        - {"face":"list","name":""}
        NEVER a face action when: the request already NAMES a person; the subject is public/famous/historical; the question is about a document, letter, manual or recipe (that person is named in text, not standing there); or it's a general "who is…" question. Those are answered, searched, or read from documents.

        WEB SEARCH — reply with ONLY {"tool":"web_search","query":"A_CONCISE_SEARCH_QUERY"} if EITHER: the user asks about current/real-time information (news, weather, sports, prices, recent events), OR you don't know, aren't fully confident, or your knowledge may be outdated. Never say you don't know without searching first.

        ON-DEVICE ACTIONS — reply with ONLY one JSON object:
        - {"tool":"set_timer","seconds":300,"label":"pasta"}   (label optional)
        - {"tool":"start_pomodoro"}
        - {"tool":"create_reminder","title":"call mom","hour":17}
        - {"tool":"create_reminder","title":"leave","minutes_from_now":20}
        - {"tool":"calendar","action":"add","title":"Focus","hour":15,"duration_minutes":25}
        - {"tool":"calendar","action":"today"}   (or "upcoming")
        - {"tool":"note","action":"save","content":"parked in lot B"}
        - {"tool":"note","action":"search","query":"parking"}
        - {"tool":"copy_to_clipboard","text":"the text to copy"}
        - {"tool":"search_docs","action":"search","query":"router error 5"}
        - {"tool":"search_docs","action":"focus","query":"router manual"}   (open a document to work with)
        - {"tool":"search_docs","action":"unfocus"}
        - {"tool":"meetings","action":"latest"}   (recorded meeting notes; or "list", "action_items", or "search" with "query")

        TIME RULES (the tool does the date math — never compute a date or minute count yourself):
        - A time of day ("6pm", "9:30am", "at 6") → "hour" in 24-hour form (6pm=18) plus "minute" if any; add "day_offset":1 for tomorrow.
        - Only "in N minutes/hours from now" → "minutes_from_now".

        OTHERWISE answer directly, in 1-3 short sentences, only when genuinely confident it's stable well-known info (math, definitions, general facts). Do NOT mention faces, tools, or JSON.

        You DO have conversation memory: the earlier messages in this chat are your record of the conversation. Use them for follow-ups and never claim you can't remember when earlier messages exist.
        """
    }


    /// Turn the model's raw output into a RouteResult (parse face/search/tool JSON, else answer).
    private static func resolve(_ output: String, command: String) async -> RouteResult {
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
            // On-device productivity tool (timer, reminder, calendar, note, clipboard, pomodoro).
            // The tiny model emits the same JSON-in-text shape it uses for faces/search; we run the
            // tool via the shared registry and speak its result. (Gemma 4's native <|tool_call> tokens
            // aren't parsed by mlx-swift-lm 3.31.3 yet — issue #259 — so we keep the proven JSON path.)
            if let toolName = (obj["tool"] as? String)?.lowercased(),
               NativeToolRegistry.shared.isNativeTool(toolName) {
                var toolArgs = obj
                toolArgs.removeValue(forKey: "tool")
                // The registry sanity-checks time args against the utterance (relative-time guard)
                // — record it so "15 minutes from now" can override the model's clock math.
                NativeToolContext.shared.set(command)
                let toolResult = await NativeToolRegistry.shared.execute(name: toolName, args: toolArgs)
                return .answer(toolResult)
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
        if let out = await generate(Prompt(stable: system, perTurn: ""), [], user),
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
    /// Like `routeCommand`, but emits the cumulative output via `onPartial` while generating, so
    /// the caller can pipeline speech behind generation. Backends that can't stream fall back to
    /// the plain route (default implementation) — `onPartial` simply never fires.
    func routeCommandStreaming(_ command: String, onPartial: @escaping (String) -> Void) async -> LocalAgent.RouteResult
    func answerWithSearchResult(question: String, result: String) async -> String
    /// Given a search query that returned nothing, propose ONE better query (or nil to give up).
    /// Enables an agentic retry so a weak first query doesn't sink the whole search.
    func reformulateSearchQuery(question: String, triedQuery: String) async -> String?
}

extension LocalTextLLM {
    func routeCommandStreaming(_ command: String, onPartial: @escaping (String) -> Void) async -> LocalAgent.RouteResult {
        await routeCommand(command)
    }
}

extension LocalAgent {
    /// System prompt for reformulating a failed web-search query. Shared by the backends.
    static let reformulateSystemPrompt = """
    You help a voice assistant search the web. A previous search returned no results. Suggest ONE different, simpler, more general web-search query that is more likely to find results for the user's question. Reply with ONLY the new query text — no quotes, no punctuation, no explanation.
    """

    /// Clean a model's reformulated-query output into a usable query (nil if empty or unchanged).
    static func cleanReformulatedQuery(_ raw: String?, triedQuery: String) -> String? {
        guard let raw else { return nil }
        let firstLine = raw.components(separatedBy: .newlines).first ?? raw
        let clean = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'.?!"))
        guard !clean.isEmpty, clean.count <= 120, clean.lowercased() != triedQuery.lowercased() else { return nil }
        return clean
    }
}
