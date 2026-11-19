// OpenVision - MeetingSummarizer.swift
// Writes a meeting's summary with the current backend, falling back to Apple Intelligence when that
// backend can't do one-off text (Hermes, OpenClaw) or fails.

import Foundation

@MainActor
enum MeetingSummarizer {

    enum SummaryError: LocalizedError {
        case emptyTranscript
        case noModel(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "Nothing was transcribed."
            case .noModel(let why): return why
            }
        }
    }

    /// Whether writing a summary right now needs the app on screen: on-device models (Apple
    /// Intelligence, MLX) can't run in the background, and Hermes and OpenClaw fall back to Apple.
    static var needsForeground: Bool {
        let backend = AIBackendRegistry.backend(for: SettingsManager.shared.settings.aiBackend)
        return backend.textContextTokens != nil || [.hermes, .openClaw].contains(backend.backendType)
    }

    /// The summary and the name of the model that wrote it.
    static func summarize(_ meeting: Meeting) async throws -> (MeetingSummary, String) {
        let transcript = meeting.timestampedTranscript
        guard MeetingNotesLogic.wordCount(meeting.transcript) > 0 else { throw SummaryError.emptyTranscript }

        let current = AIBackendRegistry.backend(for: SettingsManager.shared.settings.aiBackend)
        var candidates: [AIBackend] = [current]
        if current.backendType != .appleFoundation { candidates.append(AppleFoundationService.shared) }

        var lastError: Error?
        for backend in candidates {
            do {
                let english = !backend.canWriteLanguage(meeting.localeID)
                if let summary = try await summarize(transcript, localeID: meeting.localeID,
                                                     writeInEnglish: english, with: backend) {
                    let name = backend.backendType.displayName
                    return (summary, english ? "\(name), in English" : name)
                }
            } catch {
                NSLog("[Meeting] summary with %@ failed: %@", backend.backendType.displayName, "\(error)")
                lastError = error
            }
        }
        throw lastError ?? SummaryError.noModel(
            "\(current.backendType.displayName) can't write summaries and Apple Intelligence isn't available. Pick another AI backend, then tap Summarise.")
    }

    /// nil when the backend doesn't support one-off text.
    private static func summarize(_ transcript: String, localeID: String?, writeInEnglish: Bool,
                                  with backend: AIBackend) async throws -> MeetingSummary? {
        let size = MeetingNotesLogic.chunkChars(contextTokens: backend.textContextTokens, sample: transcript)
        let parts = MeetingNotesLogic.chunks(transcript, maxChars: size)
        let system = MeetingNotesLogic.summarySystem(localeID: localeID, writeInEnglish: writeInEnglish)

        var material = transcript
        var isPartNotes = false
        var pieces = parts
        // Condense part by part until everything fits in one request. Very long meetings on a
        // small model can need a second round (notes of notes); three rounds is plenty.
        var round = 0
        while pieces.count > 1, round < 3 {
            round += 1
            var notes: [String] = []
            for (i, piece) in pieces.enumerated() {
                guard let text = try await backend.completeText(
                    system: system, prompt: MeetingNotesLogic.partPrompt(piece, part: i + 1, of: pieces.count)) else { return nil }
                notes.append("Part \(i + 1):\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            material = notes.joined(separator: "\n\n")
            isPartNotes = true
            pieces = MeetingNotesLogic.chunks(material, maxChars: size)
        }
        guard let reply = try await backend.completeText(
            system: system, prompt: MeetingNotesLogic.finalPrompt(material, isPartNotes: isPartNotes)) else { return nil }
        return MeetingNotesLogic.parseSummary(reply)
    }
}
