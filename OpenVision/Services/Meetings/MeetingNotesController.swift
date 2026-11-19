// OpenVision - MeetingNotesController.swift
// Runs one meeting at a time: transcribes it, saves it as it goes, notices "stop taking notes",
// and writes the summary at the end. The voice agent owns everything around it (pausing the wake
// word, the audio route, speaking), so this stays free of UI and session logic.

import AVFoundation
import Speech
import UIKit

@MainActor
final class MeetingNotesController: ObservableObject {
    static let shared = MeetingNotesController()

    /// True from the moment a meeting starts (including while it spins up) until it stops.
    @Published private(set) var isActive = false
    @Published private(set) var startedAt: Date?
    /// The words being transcribed right now, for the banner.
    @Published private(set) var liveLine = ""
    /// Shown while starting, e.g. "Downloading the Hindi speech model (one time)…".
    @Published private(set) var statusLine: String?
    /// The meeting whose summary is being written, if any.
    @Published private(set) var summarizingID: UUID?

    /// Start or stop from somewhere other than the voice screen (the Meetings tab). The voice
    /// agent handles it, since it owns the wake word, the audio route and speaking.
    var onToggleRequested: (() -> Void)?

    /// Setup has to wait (a one-time speech model download); the voice agent says so.
    var onPreparing: ((String) -> Void)?

    /// "Stop taking notes" was heard, or the meeting hit its time limit.
    var onStopRequested: (() -> Void)?
    /// The mic or recognizer failed mid-meeting. The voice agent stops the meeting (keeping the
    /// transcript so far) and tells the user.
    var onFailure: ((String) -> Void)?

    /// Meetings stop by themselves after this long, so a forgotten one doesn't run all day.
    static let maxDuration: TimeInterval = 4 * 60 * 60

    private let store = MeetingStore.shared
    private var meeting: Meeting?
    private var transcriber: MeetingTranscriber?
    private var autosaveTimer: Timer?
    private var limitTimer: Timer?
    private var stopHeard = false
    /// The finished segment containing the stop phrase has arrived.
    private var stopSegmentSeen = false
    private(set) var isStopping = false
    /// A stop phrase ended the in-progress text; fires after a short pause unless cancelled.
    private var pendingStop: Task<Void, Never>?
    /// The in-progress text that armed `pendingStop`.
    private var pendingStopText: String?
    /// When the words now being transcribed began, so a segment is stamped with its start time.
    private var segmentStartedAt: Date?

    private var healthTimer: Timer?

    private init() {
        // Summaries that had to wait for the app (on-device models can't run in the background).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.summarizeWaitingMeetings() }
        }
        // The app may already be active by the time this is first created (at launch).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.summarizeWaitingMeetings()
        }
    }

    /// Whether a summary would have to wait for the app to be opened.
    var summaryMustWaitForApp: Bool {
        UIApplication.shared.applicationState != .active && MeetingSummarizer.needsForeground
    }

    private func summarizeWaitingMeetings() async {
        guard UIApplication.shared.applicationState == .active else { return }
        for meeting in store.meetings where meeting.summaryWaitingForApp == true && meeting.status == .needsSummary {
            NSLog("[Meeting] app opened — writing the summary that was waiting")
            await summarize(id: meeting.id)
        }
    }

    // MARK: - Start / stop

    func start() async throws {
        guard !isActive else { throw MeetingNotesError.alreadyRunning }
        isActive = true
        do {
            try await ensurePermissions()
            var meeting = Meeting(startedAt: Date())
            meeting.status = .recording
            self.meeting = meeting
            stopHeard = false
            stopSegmentSeen = false
            cancelPendingStop()
            segmentStartedAt = nil
            liveLine = ""

            let localeID = SettingsManager.shared.settings.meetingLanguage
            let transcriber = MeetingTranscriber(locale: MeetingLanguage.locale(for: localeID))
            meeting.localeID = transcriber.locale.identifier
            self.meeting = meeting
            transcriber.onStatus = { [weak self] status in
                guard let self else { return }
                if let status, self.statusLine == nil { self.onPreparing?(status) }
                self.statusLine = status
            }
            transcriber.onFinal = { [weak self] text in self?.handleFinal(text) }
            transcriber.onVolatile = { [weak self] text in self?.handleVolatile(text) }
            transcriber.onFailure = { [weak self] reason in self?.onFailure?(reason) }
            self.transcriber = transcriber
            try await transcriber.start()

            // The meeting starts when listening does, not when setup (a download) began.
            let listeningSince = Date()
            self.meeting?.startedAt = listeningSince
            startedAt = listeningSince
            if let meeting = self.meeting { store.save(meeting) }
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autosave() }
            }
            limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.onStopRequested?() }
            }
            healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.logHealth() }
            }
            NSLog("[Meeting] started (%@)", transcriber.engineName)
        } catch {
            // After a cancel, stop() has already reset everything (and a new meeting may exist).
            if case MeetingNotesError.cancelled = error { throw error }
            transcriber = nil
            meeting = nil
            statusLine = nil
            isActive = false
            throw error
        }
    }

    enum StopOutcome {
        case saved(Meeting)
        /// Listening ran but nothing was transcribed; nothing is kept.
        case nothingTranscribed
        /// Stopped before listening started (e.g. during a model download).
        case cancelledDuringSetup
        /// Transcribed, but the file couldn't be written (e.g. storage full). It's in the
        /// Meetings tab until the app quits; Share it to keep it.
        case savedInMemoryOnly(Meeting)
        /// Another stop is already handling it.
        case alreadyStopping
    }

    /// Stop transcribing and save. An empty meeting is deleted rather than kept.
    func stop() async -> StopOutcome {
        // A voice "stop" and a tap on Stop can arrive together; only the first one stops.
        guard isActive, !isStopping else { return .alreadyStopping }
        isStopping = true
        defer { isStopping = false }
        let wasListening = startedAt != nil
        autosaveTimer?.invalidate()
        limitTimer?.invalidate()
        healthTimer?.invalidate()
        autosaveTimer = nil
        limitTimer = nil
        healthTimer = nil
        logHealth()
        await transcriber?.stop()   // flushes the last words through handleFinal
        transcriber = nil
        isActive = false
        startedAt = nil
        statusLine = nil
        liveLine = ""

        guard var meeting else { return .nothingTranscribed }
        self.meeting = nil
        guard wasListening else {
            NSLog("[Meeting] stopped during setup")
            return .cancelledDuringSetup
        }
        meeting.endedAt = Date()
        guard meeting.wordCount > 0 else {
            store.delete(id: meeting.id)
            NSLog("[Meeting] stopped with nothing transcribed — discarded")
            return .nothingTranscribed
        }
        meeting.status = .needsSummary
        let written = store.save(meeting)
        NSLog("[Meeting] stopped: %d words, %.0f s%@", meeting.wordCount, meeting.duration, written ? "" : " — FILE NOT WRITTEN")
        return written ? .saved(meeting) : .savedInMemoryOnly(meeting)
    }

    // MARK: - Summary

    /// Write (or rewrite) a saved meeting's summary. Returns the updated meeting.
    @discardableResult
    func summarize(id: UUID) async -> Meeting? {
        guard var meeting = store.meeting(id: id), summarizingID == nil else { return nil }
        if summaryMustWaitForApp {
            meeting.status = .needsSummary
            meeting.summaryWaitingForApp = true
            meeting.summaryError = "Waiting for you to open the app: on-device AI can't run in the background."
            store.save(meeting)
            NSLog("[Meeting] summary waits for the app to be opened")
            return meeting
        }
        summarizingID = id
        defer { summarizingID = nil }
        meeting.status = .summarizing
        meeting.summaryError = nil
        store.save(meeting)
        do {
            let (summary, model) = try await MeetingSummarizer.summarize(meeting)
            // Keep "added to Reminders" marks when re-summarising produces the same items — read
            // from the latest copy, since one may have been added while the summary was written.
            var merged = summary
            let latest = store.meeting(id: id) ?? meeting
            let added = Set((latest.summary?.actionItems ?? []).filter(\.addedToReminders).map(\.task))
            for i in merged.actionItems.indices where added.contains(merged.actionItems[i].task) {
                merged.actionItems[i].addedToReminders = true
            }
            meeting.summary = merged
            meeting.summarizedWith = model
            meeting.status = .ready
            meeting.summaryWaitingForApp = nil
            NSLog("[Meeting] summary written with %@", model)
        } catch {
            meeting.status = .needsSummary
            meeting.summaryError = error.localizedDescription
            // Backgrounded part-way through: try again when the app is opened, not in a loop.
            meeting.summaryWaitingForApp = UIApplication.shared.applicationState != .active ? true : nil
        }
        // The summary took a while: if the meeting was deleted meanwhile, leave it deleted.
        guard store.update(meeting) else { return nil }
        return meeting
    }

    /// Add one action item to Apple Reminders and remember that it was added.
    func addToReminders(meetingID: UUID, itemID: UUID) async -> String {
        guard let meeting = store.meeting(id: meetingID),
              let item = meeting.summary?.actionItems.first(where: { $0.id == itemID }) else { return "That action item is gone." }
        let result = await NativeToolRegistry.shared.execute(name: "create_reminder", args: ["title": item.spoken])
        if result.hasPrefix("Reminder added") {
            // Re-read: the meeting may have been re-summarised or deleted while Reminders answered.
            // A re-summary gives every item a new id; then match by task, but only when exactly
            // one item has that task, so a duplicate can't be marked by mistake.
            if var current = store.meeting(id: meetingID), let items = current.summary?.actionItems,
               let j = items.firstIndex(where: { $0.id == itemID })
                    ?? (items.filter { $0.task == item.task }.count == 1 ? items.firstIndex { $0.task == item.task } : nil) {
                current.summary?.actionItems[j].addedToReminders = true
                store.update(current)
            }
        }
        return result
    }

    // MARK: - Transcript

    private func handleFinal(_ text: String) {
        guard var meeting else { return }
        // Anything finished after the stop phrase's own segment was said after "stop taking
        // notes" and isn't part of the meeting. Segments that finish late but were spoken before
        // it (the fallback recognizer's previous 50 s segment) are still kept.
        guard !stopSegmentSeen else { return }
        var text = text
        if let before = MeetingNotesLogic.textBeforeStopCommand(text) {
            text = before
            stopSegmentSeen = true
            requestStop()
        }
        guard !text.isEmpty else { return }
        let began = segmentStartedAt ?? Date()
        segmentStartedAt = nil
        meeting.segments.append(.init(offset: max(0, began.timeIntervalSince(meeting.startedAt)), text: text))
        self.meeting = meeting
        liveLine = ""
    }

    private func handleVolatile(_ text: String) {
        guard !stopHeard else { return }
        if !text.isEmpty, segmentStartedAt == nil { segmentStartedAt = Date() }
        if let before = MeetingNotesLogic.textBeforeStopCommand(text) {
            liveLine = before
            // In-progress text ends with a stop phrase, but the sentence may go on ("stop
            // transcribing… invoices manually"). Stop only after a short pause with no new words;
            // any update that no longer ends with the phrase cancels it. New words (a "please"
            // after the phrase) restart the pause; the same words repeated don't extend it.
            if pendingStop == nil || text != pendingStopText {
                pendingStop?.cancel()
                pendingStopText = text
                pendingStop = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    self?.pendingStop = nil
                    self?.requestStop()
                }
            }
        } else {
            cancelPendingStop()
            liveLine = text
        }
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
        pendingStopText = nil
    }

    private func requestStop() {
        cancelPendingStop()
        guard !stopHeard else { return }
        stopHeard = true
        NSLog("[Meeting] stop phrase heard")
        onStopRequested?()
    }

    /// One line a minute while recording, for long-meeting soak tests: progress, memory, heat,
    /// battery and whether the app is in the background. Counts only, never transcript text.
    private func logHealth() {
        guard let meeting else { return }
        let m = SystemMetricsReader.sample()
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "foreground"
        case .inactive: state = "inactive"
        default: state = "background"
        }
        NSLog("[Meeting] health %@ words=%d segments=%d engine=%@ restarts=%d mem=%.0fMB headroom=%.0fMB cpu=%.0f%% thermal=%@ battery=%@ app=%@",
              MeetingNotesLogic.clock(meeting.duration), meeting.wordCount, meeting.segments.count,
              transcriber?.engineName ?? "-", transcriber?.restartCount ?? 0,
              m.memoryFootprintMB, m.memoryAvailableMB, m.cpuPercent, m.thermalLabel,
              m.batteryLevel.map { "\(Int($0 * 100))%" } ?? "?", state)
    }

    private func autosave() {
        guard let meeting, isActive else { return }
        store.save(meeting)
    }

    // MARK: - Permissions

    private func ensurePermissions() async throws {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else { throw MeetingNotesError.notAuthorized }
    }
}
