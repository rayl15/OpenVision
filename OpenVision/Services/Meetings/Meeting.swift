// OpenVision - Meeting.swift
// A recorded meeting: timestamped transcript, plus the summary written when it ends.

import Foundation

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Still being transcribed.
        case recording
        /// Summary being written now.
        case summarizing
        /// Summary written.
        case ready
        /// Saved without a summary (no model available, the app was in the background, or it
        /// failed). The user can summarise it later from the meeting's page.
        case needsSummary
    }

    struct Segment: Codable, Equatable {
        /// Seconds from the start of the meeting.
        var offset: TimeInterval
        var text: String
    }

    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    var segments: [Segment] = []
    var summary: MeetingSummary?
    var status: Status = .recording
    /// Why the summary is missing, shown on the meeting's page.
    var summaryError: String?
    /// Which model wrote the summary, e.g. "OpenAI".
    var summarizedWith: String?
    /// The transcription language, e.g. "hi_IN" or "mul_IN". nil for meetings saved before
    /// languages were selectable (they were transcribed in the phone's language).
    var localeID: String?
    /// The summary couldn't be written because the app was in the background (on-device models
    /// can't run there). It's written automatically the next time the app is opened.
    var summaryWaitingForApp: Bool?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// The summary's title, or a dated fallback.
    var title: String {
        if let t = summary?.title, !t.isEmpty { return t }
        return "Meeting, " + startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// The whole transcript as plain text, one segment per line.
    var transcript: String { segments.map(\.text).joined(separator: "\n") }

    /// Transcript with [mm:ss] stamps, for sharing and for the model.
    var timestampedTranscript: String {
        segments.map { "[\(MeetingNotesLogic.clock($0.offset))] \($0.text)" }.joined(separator: "\n")
    }

    var wordCount: Int { MeetingNotesLogic.wordCount(transcript) }
}

struct MeetingSummary: Codable, Equatable {
    var title: String
    var overview: String
    var decisions: [String]
    var actionItems: [ActionItem]
}

struct ActionItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var task: String
    var owner: String?
    var due: String?
    /// Set once the user adds it to Apple Reminders, so the button can't add it twice.
    var addedToReminders = false

    enum CodingKeys: String, CodingKey { case id, task, owner, due, addedToReminders }

    init(task: String, owner: String? = nil, due: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decode(String.self, forKey: .task)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        addedToReminders = try c.decodeIfPresent(Bool.self, forKey: .addedToReminders) ?? false
    }

    /// "Send the deck (Priya, Friday)".
    var spoken: String {
        let extras = [owner, due].compactMap { $0 }.filter { !$0.isEmpty }
        return extras.isEmpty ? task : "\(task) (\(extras.joined(separator: ", ")))"
    }
}

/// Languages meeting notes can transcribe on the phone. Apple's on-device SpeechAnalyzer supports
/// all of these on iOS 26+ (checked on device with SpeechTranscriber.supportedLocales). An empty
/// id means "the phone's language".
enum MeetingLanguage {
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let automatic = ""
    /// Apple's multilingual Indian model: for meetings that switch between Hindi, English and other
    /// Indian languages mid-sentence (Hinglish).
    static let mixedIndia = "mul_IN"

    static let options: [Option] = [
        Option(id: automatic, name: "Phone language"),
        Option(id: "en_IN", name: "English (India)"),
        Option(id: "en_US", name: "English (US)"),
        Option(id: "en_GB", name: "English (UK)"),
        Option(id: "hi_IN", name: "हिन्दी Hindi"),
        Option(id: mixedIndia, name: "Hinglish / mixed Indian languages"),
        Option(id: "bn_IN", name: "বাংলা Bengali"),
        Option(id: "mr_IN", name: "मराठी Marathi"),
        Option(id: "gu_IN", name: "ગુજરાતી Gujarati"),
        Option(id: "pa_IN", name: "ਪੰਜਾਬੀ Punjabi"),
        Option(id: "ta_IN", name: "தமிழ் Tamil"),
        Option(id: "te_IN", name: "తెలుగు Telugu"),
        Option(id: "kn_IN", name: "ಕನ್ನಡ Kannada"),
        Option(id: "ml_IN", name: "മലയാളം Malayalam"),
        Option(id: "ur_IN", name: "اردو Urdu"),
    ]

    /// The locale to transcribe with for a setting value.
    static func locale(for id: String) -> Locale {
        id.isEmpty ? Locale.current : Locale(identifier: id)
    }

    static func name(for id: String) -> String {
        options.first { $0.id == id }?.name ?? Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Display name for a meeting's locale id, e.g. "हिन्दी Hindi".
    static func displayName(localeID: String?) -> String? {
        guard let localeID else { return nil }
        return options.first { $0.id == localeID }?.name
            ?? Locale.current.localizedString(forIdentifier: localeID)
    }
}

/// Which microphone meeting notes listen with (Settings → Voice → Meeting notes).
enum MeetingMicSource: String, Codable, CaseIterable, Identifiable {
    /// The phone on the table hears the whole room.
    case phone
    /// The glasses' Bluetooth mic mostly hears the wearer. Unavailable while the camera streams.
    case glasses
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .phone: return "Phone"
        case .glasses: return "Glasses"
        }
    }
}
