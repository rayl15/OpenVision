// OpenVision - MeetingsTool.swift
// Ask about recorded meetings: "what did we decide this morning?", "what are my action items?"

import Foundation

struct MeetingsTool: NativeTool {
    let name = "meetings"
    let description = "Look up the user's recorded meeting notes. Actions: 'latest' (summary of the most recent meeting), 'list' (recent meetings), 'search' (needs query: find meetings mentioning it and return their notes), 'action_items' (open action items from recent meetings). Meeting recording itself is started and stopped by voice ('start taking notes'), not with this tool."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "latest, list, search, or action_items"],
            "query": ["type": "string", "description": "Words to look for (for search)"]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "latest").lowercased()
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return await MainActor.run { Self.answer(action: action, query: query, meetings: MeetingStore.shared.meetings) }
    }

    /// Pure over the given meetings (newest first), so it's unit-tested.
    static func answer(action: String, query: String, meetings all: [Meeting]) -> String {
        let meetings = all.filter { $0.status != .recording }
        guard !meetings.isEmpty else { return "No meetings recorded yet. Say 'start taking notes' to record one." }

        switch action {
        case "list", "recent":
            return "Recent meetings: " + meetings.prefix(5).map {
                "\($0.title) (\($0.startedAt.formatted(date: .abbreviated, time: .shortened)), \(MeetingNotesLogic.clock($0.duration)))"
            }.joined(separator: "; ") + "."

        case "search", "find":
            guard !query.isEmpty else { return "What should I look for in your meetings?" }
            let words = MeetingNotesLogic.normalized(query).split(separator: " ").map(String.init)
            let hits = meetings.filter { m in
                let text = MeetingNotesLogic.normalized(notes(m) + " " + m.transcript)
                return words.allSatisfy { text.contains($0) }
            }
            guard !hits.isEmpty else { return "No meetings mention '\(query)'." }
            return hits.prefix(2).map { notes($0, transcriptExcerptFor: words) }.joined(separator: "\n---\n")

        case "action_items", "actions", "todo", "todos":
            let open = meetings.prefix(5).flatMap { m in
                (m.summary?.actionItems ?? []).filter { !$0.addedToReminders }.map { "\($0.spoken) — from \(m.title)" }
            }
            return open.isEmpty ? "No open action items from your recent meetings." : "Open action items: " + open.joined(separator: "; ") + "."

        default:
            return notes(meetings[0])
        }
    }

    /// A meeting's notes as text for the model, with a short transcript excerpt around the
    /// search words when given (or when there's no summary yet).
    static func notes(_ m: Meeting, transcriptExcerptFor words: [String] = []) -> String {
        var lines = ["Meeting: \(m.title), \(m.startedAt.formatted(date: .abbreviated, time: .shortened)), \(MeetingNotesLogic.clock(m.duration)) long."]
        if let s = m.summary {
            if !s.overview.isEmpty { lines.append("Summary: \(s.overview)") }
            if !s.decisions.isEmpty { lines.append("Decisions: " + s.decisions.joined(separator: "; ")) }
            if !s.actionItems.isEmpty { lines.append("Action items: " + s.actionItems.map(\.spoken).joined(separator: "; ")) }
        }
        let needsExcerpt = m.summary == nil || !words.isEmpty
        if needsExcerpt {
            let matching = words.isEmpty ? m.segments : m.segments.filter { seg in
                let t = MeetingNotesLogic.normalized(seg.text)
                return words.contains { t.contains($0) }
            }
            let excerpt = String(matching.map(\.text).joined(separator: " ").prefix(1500))
            if !excerpt.isEmpty { lines.append("From the transcript: \(excerpt)") }
        }
        return lines.joined(separator: "\n")
    }
}
