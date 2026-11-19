// OpenVision - MeetingDetailView.swift
// One meeting: summary, decisions, action items (add to Reminders), and the full transcript.

import SwiftUI

struct MeetingDetailView: View {
    let meetingID: UUID

    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var controller = MeetingNotesController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reminderMessage: String?
    @State private var confirmDelete = false

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                Text("This meeting was deleted.").foregroundColor(.secondary)
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let meeting {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: MeetingExport.text(meeting), subject: Text(meeting.title)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(id: meetingID)
                dismiss()
            }
        } message: {
            Text("The transcript and notes are removed from this phone.")
        }
    }

    private func content(_ m: Meeting) -> some View {
        List {
            Section {
                LabeledContent("When", value: m.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Length", value: MeetingNotesLogic.clock(m.duration))
                LabeledContent("Words", value: "\(m.wordCount)")
                if let language = MeetingLanguage.displayName(localeID: m.localeID) {
                    LabeledContent("Language", value: language)
                }
                if let model = m.summarizedWith {
                    LabeledContent("Summary by", value: model)
                }
            }

            summarySections(m)

            Section {
                if m.segments.isEmpty {
                    Text("Nothing was transcribed.").foregroundColor(.secondary)
                } else {
                    ForEach(Array(m.segments.enumerated()), id: \.offset) { _, seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(MeetingNotesLogic.clock(seg.offset))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                            Text(seg.text).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                Text("Transcribed on your phone. There are no speaker names, and some words may be wrong.")
            }

            Section {
                if m.status != .recording {
                    Button {
                        Task { await controller.summarize(id: m.id) }
                    } label: {
                        Label(m.summary == nil ? "Summarise" : "Summarise again", systemImage: "sparkles")
                    }
                    .disabled(controller.summarizingID != nil)
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete meeting", systemImage: "trash")
                }
                .disabled(m.status == .recording)
            }
        }
    }

    @ViewBuilder
    private func summarySections(_ m: Meeting) -> some View {
        if controller.summarizingID == m.id || m.status == .summarizing {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Writing the notes…").foregroundColor(.secondary)
                }
            }
        } else if let s = m.summary {
            if !s.overview.isEmpty {
                Section("Summary") {
                    Text(s.overview).textSelection(.enabled)
                }
            }
            if !s.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(Array(s.decisions.enumerated()), id: \.offset) { _, d in
                        Label(d, systemImage: "checkmark.seal").textSelection(.enabled)
                    }
                }
            }
            if !s.actionItems.isEmpty {
                Section {
                    ForEach(s.actionItems) { item in
                        actionRow(item, meetingID: m.id)
                    }
                } header: {
                    Text("Action items")
                } footer: {
                    if let reminderMessage { Text(reminderMessage) }
                }
            }
        } else if let error = m.summaryError {
            Section("Summary") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }
        }
    }

    private func actionRow(_ item: ActionItem, meetingID: UUID) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                let extras = [item.owner, item.due].compactMap { $0 }
                if !extras.isEmpty {
                    Text(extras.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if item.addedToReminders {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Added to Reminders")
            } else {
                Button {
                    Task { reminderMessage = await controller.addToReminders(meetingID: meetingID, itemID: item.id) }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add to Reminders")
            }
        }
    }
}

/// Plain-text version of a meeting for sharing.
enum MeetingExport {
    static func text(_ m: Meeting) -> String {
        var out = ["\(m.title)", "\(m.startedAt.formatted(date: .complete, time: .shortened)) · \(MeetingNotesLogic.clock(m.duration))"]
        if let s = m.summary {
            if !s.overview.isEmpty { out += ["", "Summary", s.overview] }
            if !s.decisions.isEmpty { out += ["", "Decisions"] + s.decisions.map { "• \($0)" } }
            if !s.actionItems.isEmpty { out += ["", "Action items"] + s.actionItems.map { "• \($0.spoken)" } }
        }
        out += ["", "Transcript", m.timestampedTranscript]
        return out.joined(separator: "\n")
    }
}
