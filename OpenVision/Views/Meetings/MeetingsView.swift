// OpenVision - MeetingsView.swift
// The Meetings tab: start or stop meeting notes, follow the live transcript, and browse past
// meetings grouped by day.

import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var controller = MeetingNotesController.shared
    @State private var searchText = ""

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var finished: [Meeting] {
        (isSearching ? store.search(searchText) : store.meetings).filter { $0.status != .recording }
    }

    var body: some View {
        NavigationStack {
            List {
                if !isSearching {
                    Section { recorderCard }
                    if !openActionItems.isEmpty { actionItemsSection }
                }

                if finished.isEmpty {
                    Section {
                        Text(isSearching ? "No meetings mention “\(searchText)”." : "Your meetings will appear here, with a summary, decisions and action items.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(MeetingsView.groupByDay(finished), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.meetings) { meeting in
                                NavigationLink {
                                    MeetingDetailView(meetingID: meeting.id)
                                } label: {
                                    row(meeting)
                                }
                            }
                            .onDelete { offsets in
                                offsets.map { group.meetings[$0].id }.forEach(store.delete(id:))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $searchText, prompt: "Search meetings")
            .animation(.default, value: controller.isActive)
        }
    }

    // MARK: - Recorder

    @ViewBuilder
    private var recorderCard: some View {
        if controller.isActive {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Taking notes", systemImage: "waveform")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Spacer()
                    if let started = controller.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(MeetingNotesLogic.clock(context.date.timeIntervalSince(started)))
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
                Text(controller.statusLine ?? (controller.liveLine.isEmpty ? "Listening…" : controller.liveLine))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    controller.onToggleRequested?()
                } label: {
                    Label("Stop and summarise", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.vertical, 4)
        } else if controller.summarizingID != nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("Writing the notes…").foregroundColor(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    controller.onToggleRequested?()
                } label: {
                    Label("Start meeting notes", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Language: \(MeetingLanguage.name(for: SettingsManager.shared.settings.meetingLanguage)). Or say “Ok Vision, start taking notes”. Transcription runs on your phone; your AI backend writes the summary when you stop.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Open action items

    private var openActionItems: [(meeting: Meeting, item: ActionItem)] {
        store.meetings.prefix(10).flatMap { m in
            (m.summary?.actionItems ?? []).filter { !$0.addedToReminders }.map { (m, $0) }
        }
    }

    private var actionItemsSection: some View {
        Section {
            ForEach(openActionItems.prefix(5), id: \.item.id) { entry in
                NavigationLink {
                    MeetingDetailView(meetingID: entry.meeting.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.task)
                        Text([entry.item.owner, entry.item.due, entry.meeting.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Open action items")
        } footer: {
            if openActionItems.count > 5 {
                Text("\(openActionItems.count - 5) more in your recent meetings.")
            }
        }
    }

    // MARK: - Rows

    private func row(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(m.startedAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(MeetingNotesLogic.clock(m.duration))
                if let n = m.summary?.actionItems.count, n > 0 {
                    Text("·")
                    Text("\(n) action item\(n == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            switch m.status {
            case .summarizing:
                Label("Writing notes…", systemImage: "hourglass").font(.caption).foregroundColor(.secondary)
            case .needsSummary:
                Label("No summary yet", systemImage: "exclamationmark.circle").font(.caption).foregroundColor(.orange)
            case .ready, .recording:
                if let overview = m.summary?.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Grouping

    struct DayGroup {
        let title: String
        let meetings: [Meeting]
    }

    /// Today, Yesterday, then one section per day ("Monday 17 November"), keeping the order given.
    static func groupByDay(_ meetings: [Meeting], calendar: Calendar = .current, now: Date = Date()) -> [DayGroup] {
        var groups: [DayGroup] = []
        for m in meetings {
            let title: String
            if calendar.isDate(m.startedAt, inSameDayAs: now) {
                title = "Today"
            } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(m.startedAt, inSameDayAs: y) {
                title = "Yesterday"
            } else {
                let sameYear = calendar.component(.year, from: m.startedAt) == calendar.component(.year, from: now)
                title = sameYear
                    ? m.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
                    : m.startedAt.formatted(.dateTime.day().month(.wide).year())
            }
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = DayGroup(title: title, meetings: last.meetings + [m])
            } else {
                groups.append(DayGroup(title: title, meetings: [m]))
            }
        }
        return groups
    }
}
