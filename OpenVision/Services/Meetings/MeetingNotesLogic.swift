// OpenVision - MeetingNotesLogic.swift
// The pure parts of meeting notes (voice phrases, transcript chunking, summary prompts and parsing),
// kept free of audio and UI so they're unit-tested.

import Foundation

enum MeetingNotesLogic {

    // MARK: - Voice phrases

    /// Phrases that start meeting notes. Deliberately not "take a note", which saves a quick note.
    static let startPhrases = [
        "start taking notes", "start meeting notes", "take meeting notes", "start note taking",
        "start the meeting notes", "take notes for this meeting", "take notes of this meeting",
        "record this meeting", "record the meeting", "transcribe this meeting", "transcribe the meeting",
        "start transcribing", "meeting mode",
        // Hinglish. The wake-word recognizer is English, so these arrive romanized.
        "notes lena shuru karo", "notes shuru karo", "meeting notes shuru karo", "notes lena start karo",
        "notes start karo", "notes likhna shuru karo",
    ]

    /// Phrases that end meeting notes, heard in the meeting transcript itself.
    static let stopPhrases = [
        "stop taking notes", "stop the notes", "stop meeting notes", "stop the meeting notes",
        "stop note taking", "end meeting notes", "end the meeting notes", "finish taking notes",
        "stop transcribing", "stop recording the meeting", "end the meeting recording",
        // Hindi, as the Hindi recognizer writes it.
        "मीटिंग नोट्स बंद करो", "नोट्स लेना बंद करो", "नोट्स लेना बंद कर दो", "नोट्स बंद करो",
        "नोट्स बंद कर दो", "नोट बंद करो",
        // Hinglish, as the mixed-language recognizer may write it.
        "notes lena band karo", "notes lena band kar do", "notes band karo", "notes band kar do", "note band karo",
    ]

    /// What to tell the user to say to stop, for the chosen language. The Stop button always works.
    static func stopHint(localeID: String) -> String {
        let id = localeID.isEmpty ? Locale.current.identifier : localeID
        if id.hasPrefix("hi") { return "\"stop taking notes\" or \"नोट्स बंद करो\"" }
        if id == MeetingLanguage.mixedIndia { return "\"stop taking notes\" or \"notes band karo\"" }
        return "\"stop taking notes\""
    }

    /// Words that don't change what a command means: the wake word and politeness.
    private static let commandFillers: Set<String> = [
        "ok", "okay", "hey", "vision", "please", "now", "can", "you", "could", "would", "just",
        "go", "ahead", "and", "thanks", "thank", "ji", "abhi", "yaar",
    ]

    /// A start phrase that is the whole command: every other word must be a filler (wake word,
    /// politeness). Matching anywhere started recording on "remind me to record the meeting at 3",
    /// and allowing any one extra word let "don't record this meeting" through.
    static func isStartCommand(_ text: String) -> Bool {
        let t = normalized(text)
        return startPhrases.contains { phrase in
            guard t.contains(phrase) else { return false }
            return t.replacingOccurrences(of: phrase, with: " ").split(separator: " ")
                .allSatisfy { commandFillers.contains(String($0)) }
        }
    }

    /// Fillers allowed after a stop phrase ("stop taking notes please", "notes band karo abhi").
    private static let trailingFillers = "please|now|thanks|thank you|ji|abhi|yaar|अभी|जी|कृपया|धन्यवाद"

    /// If `text` ENDS with a stop phrase (allowing a filler like "please" after it), the
    /// transcript before it, with a wake word such as "ok vision" just before it removed. nil
    /// otherwise — a stop phrase in the middle of a sentence ("we should stop transcribing
    /// invoices manually") is ordinary speech.
    static func textBeforeStopCommand(_ text: String) -> String? {
        // Words may be separated by any punctuation or spaces ("Stop, taking notes."); matched
        // case-insensitively on the original text. The earliest match wins, so the longest of
        // two overlapping phrases ("मीटिंग नोट्स बंद करो" over "नोट्स बंद करो") is cut.
        let full = NSRange(text.startIndex..., in: text)
        let earliest = stopPhrases.compactMap { phrase -> NSRange? in
            let pattern = "\\b" + phrase.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[\\s\\p{P}]+")
                + "\\b(?:[\\s\\p{P}]+(?:\(trailingFillers))\\b)*[\\s\\p{P}]*$"
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
                .firstMatch(in: text, range: full)?.range
        }.min { $0.location < $1.location }
        guard let match = earliest, let range = Range(match, in: text) else { return nil }
        var before = String(text[..<range.lowerBound])
        // Drop a wake word said right before the stop phrase ("..., ok vision, stop taking notes").
        let wake = try? NSRegularExpression(
            pattern: "[\\s,.!?।]*(ok(ay)?|hey|ओके|ओकेय|हे)?[\\s,]*(vision|विज़न|विजन)[\\s,.!?।]*$",
            options: .caseInsensitive)
        if let wake {
            before = wake.stringByReplacingMatches(in: before, range: NSRange(before.startIndex..., in: before), withTemplate: "")
        }
        return before.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Lowercased, punctuation turned into spaces, whitespace collapsed.
    static func normalized(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Formatting

    /// "4:05" for under an hour, "1:02:03" above.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Chunking

    /// Split a transcript into pieces of at most `maxChars`, breaking between lines, then between
    /// sentences, and only mid-sentence for a single overlong sentence.
    static func chunks(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        // Units: lines, with any line longer than the budget split into sentences, and any
        // sentence still too long hard-split.
        var units: [String] = []
        for line in trimmed.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.count <= maxChars { units.append(line); continue }
            for sentence in TextChunking.sentences(line) {
                if sentence.count <= maxChars { units.append(sentence); continue }
                var rest = Substring(sentence)
                while !rest.isEmpty {
                    units.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
            }
        }

        var result: [String] = []
        var current = ""
        for unit in units {
            let joined = current.isEmpty ? unit : current + "\n" + unit
            if joined.count > maxChars, !current.isEmpty {
                result.append(current)
                current = unit
            } else {
                current = joined
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Summary prompts

    /// System prompt for the summary. `writeInEnglish` when the model can't write the meeting's
    /// language (Apple Intelligence has no Hindi).
    static func summarySystem(localeID: String?, writeInEnglish: Bool) -> String {
        let language: String
        if writeInEnglish {
            language = "Write the notes in English, even though the meeting may be in another language."
        } else if localeID == MeetingLanguage.mixedIndia {
            language = "The meeting mixes languages (for example Hindi and English); write the notes in English."
        } else {
            language = "Write in the language the meeting was held in."
        }
        return "You write meeting notes from a raw speech-to-text transcript. The transcript has no speaker names "
            + "and may contain recognition mistakes; fix obvious ones from context, but never invent facts, names, "
            + "numbers or dates that aren't in it. " + language
    }

    // MARK: - Request size

    /// Transcript characters per request. Cloud models take the whole meeting; on-device models
    /// get what fits their context window (`contextTokens`) after room for instructions and the
    /// reply. Latin script averages 3+ characters per token; Devanagari and other scripts can be
    /// about one, so they get smaller pieces.
    static func chunkChars(contextTokens: Int?, sample: String) -> Int {
        guard let contextTokens else { return 60_000 }
        let inputTokens = max(1_000, contextTokens - 2_000)
        return isMostlyLatin(sample) ? inputTokens * 3 : inputTokens
    }

    /// True when most letters in `text` are Latin (English, romanized Hinglish).
    static func isMostlyLatin(_ text: String) -> Bool {
        var latin = 0, other = 0
        for scalar in text.unicodeScalars.prefix(4_000) where scalar.properties.isAlphabetic {
            if scalar.value < 0x0250 { latin += 1 } else { other += 1 }
        }
        return latin >= other
    }

    /// Final pass: reply with JSON only, in this shape.
    static let jsonInstructions = """
    Reply with ONLY a JSON object, no markdown, with these keys: "title" (3 to 6 words), "overview" \
    (2 or 3 sentences), "decisions" (a list of strings), and "action_items" (a list of objects with \
    "task", "owner" and "due"). Example shape: {"title": "", "overview": "", "decisions": [], \
    "action_items": [{"task": "", "owner": "", "due": ""}]}
    A decision is only something the people explicitly agreed or decided; topics that were merely \
    discussed are not decisions. An action item is only a task someone committed to. Many \
    conversations have neither: then use empty lists. Fill "owner" and "due" only with a name or \
    time said in the transcript, otherwise leave them as empty strings.
    """

    /// Prompt for one piece of a long meeting: condensed notes the final pass merges.
    static func partPrompt(_ chunk: String, part: Int, of total: Int) -> String {
        """
        This is part \(part) of \(total) of a meeting transcript. Write condensed notes for this part \
        only: the topics discussed, any decisions made, and any action items with who and when if \
        said. Plain text, at most 12 short lines.

        Transcript part \(part):
        \(chunk)
        """
    }

    /// Prompt for the final summary, from the full transcript or from the parts' notes.
    static func finalPrompt(_ material: String, isPartNotes: Bool) -> String {
        let what = isPartNotes ? "Notes from each part of the meeting, in order" : "Meeting transcript"
        return "\(jsonInstructions)\n\n\(what):\n\(material)"
    }

    // MARK: - Parsing

    /// Parse the model's reply. Accepts JSON wrapped in code fences or prose. When there is no
    /// usable JSON, the reply text becomes the overview so the work isn't lost.
    static func parseSummary(_ reply: String) -> MeetingSummary {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let data = String(text[start...end]).data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let title = clean(obj["title"] as? String) ?? ""
            let overview = clean(obj["overview"] as? String ?? obj["summary"] as? String) ?? ""
            let decisions = (obj["decisions"] as? [Any] ?? []).compactMap { clean($0 as? String) }
            let rawItems = obj["action_items"] as? [Any] ?? obj["actionItems"] as? [Any] ?? []
            let items: [ActionItem] = rawItems.compactMap { item in
                if let s = clean(item as? String) { return ActionItem(task: s) }
                guard let d = item as? [String: Any], let task = clean(d["task"] as? String) else { return nil }
                return ActionItem(task: task, owner: clean(d["owner"] as? String), due: clean(d["due"] as? String))
            }
            if !overview.isEmpty || !decisions.isEmpty || !items.isEmpty {
                return MeetingSummary(title: title, overview: overview, decisions: decisions, actionItems: items)
            }
        }
        let prose = text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSummary(title: "", overview: prose, decisions: [], actionItems: [])
    }

    /// Trimmed, or nil when empty or a placeholder like "none" / "N/A".
    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // Includes words small models copy from the prompt's description of the fields.
        let placeholders: Set<String> = ["none", "n/a", "na", "unknown", "empty", "-", "null", "tbd", "unspecified",
                                         "who", "when", "what", "who, or empty", "when, or empty", "what to do",
                                         "owner", "due", "task", "name", "date", "not specified", "not mentioned"]
        return placeholders.contains(t.lowercased()) ? nil : t
    }

    // MARK: - Spoken recap

    /// What's said aloud when the summary is ready: short, because the full notes are in the app.
    static func spokenRecap(_ s: MeetingSummary) -> String {
        var parts: [String] = []
        // The voices speak English; a summary in Devanagari or another script would come out as
        // noise, so it's left to the screen.
        if !s.overview.isEmpty, isMostlyLatin(s.overview) {
            parts.append(TextChunking.sentences(s.overview).first ?? s.overview)
        }
        func count(_ n: Int, _ word: String) -> String { "\(n == 0 ? "no" : String(n)) \(word)\(n == 1 ? "" : "s")" }
        var tally = "\(count(s.decisions.count, "decision")) and \(count(s.actionItems.count, "action item"))."
        tally = tally.prefix(1).uppercased() + tally.dropFirst()
        parts.append(tally)
        if let first = s.actionItems.first {
            parts.append("First action item: \(first.spoken).")
        }
        parts.append("The full notes are in the Meetings tab.")
        return parts.joined(separator: " ")
    }
}
