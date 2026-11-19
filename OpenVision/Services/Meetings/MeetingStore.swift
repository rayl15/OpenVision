// OpenVision - MeetingStore.swift
// Meetings saved as one JSON file each in Documents/Meetings, so a long transcript never has to be
// rewritten alongside every other meeting.

import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// Newest first.
    @Published private(set) var meetings: [Meeting] = []

    private let directory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Meeting] = files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        // A meeting still "recording" or "summarizing" at launch was cut off when the app quit.
        // Keep the transcript and let the user summarise it.
        for i in loaded.indices where loaded[i].status == .recording || loaded[i].status == .summarizing {
            if loaded[i].endedAt == nil {
                loaded[i].endedAt = loaded[i].startedAt.addingTimeInterval(loaded[i].segments.last?.offset ?? 0)
            }
            loaded[i].status = .needsSummary
            loaded[i].summaryError = "The app closed before the summary was written."
            loaded[i].summaryWaitingForApp = true
            write(loaded[i])
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    func meeting(id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// Insert or replace, and write it to disk. False if the file couldn't be written (the
    /// meeting is still in memory for this session).
    @discardableResult
    func save(_ meeting: Meeting) -> Bool {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        return write(meeting)
    }

    /// Replace a meeting only if it still exists. For writes that land after an await (a
    /// summary, a reminder): the user may have deleted the meeting meanwhile, and a plain save
    /// would bring it back.
    @discardableResult
    func update(_ meeting: Meeting) -> Bool {
        guard meetings.contains(where: { $0.id == meeting.id }) else {
            NSLog("[Meeting] not saving a meeting that was deleted meanwhile")
            return false
        }
        return save(meeting)
    }

    func delete(id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    @discardableResult
    private func write(_ meeting: Meeting) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(meeting)
            // Transcripts are private: protect them while the phone is locked after first unlock.
            try data.write(to: url(for: meeting.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            NSLog("[Meeting] couldn't write meeting file: %@", "\(error)")
            return false
        }
    }

    // MARK: - Search (for the meetings tool)

    /// Finished meetings whose title, summary or transcript mention every word of `query`, newest first.
    func search(_ query: String) -> [Meeting] {
        let words = MeetingNotesLogic.normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return meetings.filter { m in
            guard m.status != .recording else { return false }
            let haystack = MeetingNotesLogic.normalized([
                m.title, m.summary?.overview ?? "",
                (m.summary?.decisions ?? []).joined(separator: " "),
                (m.summary?.actionItems ?? []).map(\.spoken).joined(separator: " "),
                m.transcript,
            ].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
