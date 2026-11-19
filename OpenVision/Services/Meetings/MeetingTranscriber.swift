// OpenVision - MeetingTranscriber.swift
// Long-form, on-device transcription for meeting notes.
//
// Two engines behind one interface:
// - iOS 26+: SpeechAnalyzer + SpeechTranscriber, Apple's long-form recognizer (no time limit,
//   better accuracy, Hindi and other Indian languages, and "mul_IN" for Hinglish). If the
//   language's model isn't installed: when the fallback can transcribe the language on the phone
//   (English), the download starts for next time and this meeting uses the fallback; otherwise
//   (Hindi) the model is downloaded first. Speech never goes to Apple's servers.
// - Otherwise: SFSpeechRecognizer on-device, run in ~50 s segments because one recognition task
//   stops after about a minute. Audio switches to the new segment between two mic buffers, so
//   nothing is lost, though a word spoken exactly at the switch can come out split.
//
// It owns its own mic engine (the wake-word listener is paused during a meeting) and follows the
// rules in the audio pitfalls notes: OVCatchException around installTap, validate the input format,
// recreate the engine after a configuration change, and never let a dead task trigger a restart.

import AVFoundation
import Speech

@MainActor
final class MeetingTranscriber {

    /// Finished text for a stretch of speech. Delivered on the main actor.
    var onFinal: ((String) -> Void)?
    /// In-progress text for the stretch being spoken now (replaced on every update).
    var onVolatile: ((String) -> Void)?
    /// The mic couldn't be (re)started; the meeting should end with what it has.
    var onFailure: ((String) -> Void)?
    /// Something to show while starting, e.g. a one-time model download. nil when done.
    var onStatus: ((String?) -> Void)?

    private(set) var isRunning = false
    private(set) var engineName = ""
    let locale: Locale

    private var audioEngine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private let sink = AudioSink()

    // SFSpeech fallback
    private let speechRecognizer: SFSpeechRecognizer?
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var requests: [Int: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var latestText: [Int: String] = [:]
    private var committed: Set<Int> = []
    private var currentTaskID = 0
    private var rotationTimer: Timer?
    private var lastTaskStart = Date.distantPast
    private var quickFailures = 0

    // SpeechAnalyzer (iOS 26). Type-erased so the class still loads on iOS 18.
    private var analyzerSession: AnyObject?
    /// The analyzer's in-progress text, kept so a restart doesn't lose it.
    private var lastVolatile = ""

    // Watchdog
    private var watchdogTimer: Timer?
    private var restartTimes: [Date] = []
    private var isRestarting = false
    /// Recognizer restarts this meeting, for the health log.
    private(set) var restartCount = 0

    static let segmentLength: TimeInterval = 50

    init(locale: Locale = .current) {
        self.locale = locale
        // No silent switch to another language: a Hindi meeting transcribed as English is useless.
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// The fallback can transcribe this language without sending audio off the phone.
    private var fallbackIsOnDevice: Bool {
        speechRecognizer?.supportsOnDeviceRecognition == true
    }

    private var languageName: String {
        if locale.identifier == MeetingLanguage.mixedIndia { return "Hinglish" }
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Stopped while still setting up (e.g. during a model download): undo and report it.
    private func abandonIfStopped() async throws {
        guard !isRunning else { return }
        NSLog("[Meeting] stopped during setup — not starting the mic")
        onStatus?(nil)
        await tearDown()
        throw MeetingNotesError.cancelled
    }

    // MARK: - Start / stop

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        var usingAnalyzer = false
        if #available(iOS 26.0, *) {
            do {
                if let session = try await AnalyzerSession.make(
                    locale: locale, owner: self, downloadIfMissing: !fallbackIsOnDevice,
                    languageName: languageName, onStatus: { [weak self] status in
                        // A download keeps reporting after a cancel; only pass it on while starting.
                        guard let self, self.isRunning else { return }
                        self.onStatus?(status)
                    }) {
                    analyzerSession = session
                    sink.handler = { [weak session] buffer in session?.feed(buffer) }
                    usingAnalyzer = true
                    engineName = "SpeechAnalyzer \(locale.identifier)"
                }
            } catch {
                try await abandonIfStopped()
                isRunning = false
                onStatus?(nil)
                throw error
            }
            onStatus?(nil)
            try await abandonIfStopped()
        }
        if !usingAnalyzer {
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                isRunning = false
                throw speechRecognizer == nil ? MeetingNotesError.languageNotSupported(languageName) : MeetingNotesError.recognizerUnavailable
            }
            guard recognizer.supportsOnDeviceRecognition else {
                // It would work through Apple's servers, but meeting audio stays on the phone.
                isRunning = false
                throw MeetingNotesError.languageNotSupported(languageName)
            }
            engineName = "SFSpeech on-device \(locale.identifier)"
            startRecognitionTask()
            rotationTimer = Timer.scheduledTimer(withTimeInterval: Self.segmentLength, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rotate() }
            }
        }

        do {
            try startMic()
        } catch {
            await tearDown()
            throw error
        }
        sink.resetWatch()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        NSLog("[Meeting] transcriber started (%@)", engineName)
    }

    /// Stop listening and deliver any remaining text through `onFinal` before returning.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        stopMic()
        rotationTimer?.invalidate()
        rotationTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if #available(iOS 26.0, *), let session = analyzerSession as? AnalyzerSession {
            // A stuck analyzer must not hang "stop"; keep its unfinished words either way.
            if !(await Self.finish(session, within: 5)) { commitVolatile() }
        } else if let request = requests[currentTaskID] {
            // Let the last segment deliver its final result, then commit whatever is left.
            request.endAudio()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !requests.keys.allSatisfy({ committed.contains($0) }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await tearDown()
    }

    private func tearDown() async {
        stopMic()
        for id in requests.keys.sorted() { commit(id) }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        requests.removeAll()
        latestText.removeAll()
        committed.removeAll()
        analyzerSession = nil
        lastVolatile = ""
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        sink.handler = nil
        isRunning = false
    }

    // MARK: - SFSpeech segments

    private func startRecognitionTask() {
        guard let recognizer = speechRecognizer else { return }
        currentTaskID += 1
        let id = currentTaskID
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true   // start() only gets here when it's supported
        requests[id] = request
        lastTaskStart = Date()

        // New audio goes to the new request from now on. The previous one is ended by `rotate`.
        sink.handler = { buffer in request.append(buffer) }

        tasks[id] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in self?.handleTask(id, text: text, isFinal: isFinal, error: error) }
        }
    }

    /// Each task's callbacks are tracked by its own id, so a finished or cancelled task can only
    /// commit its own text once and can never restart recognition (only the current task can).
    private func handleTask(_ id: Int, text: String?, isFinal: Bool, error: Error?) {
        guard !committed.contains(id) else { return }
        if let text, !text.isEmpty {
            sink.noteResult()
            latestText[id] = text
            if id == currentTaskID { onVolatile?(text) }
        }
        guard isFinal || error != nil else { return }
        commit(id)

        // The current segment ended by itself (a pause, an error, the time limit): start the next.
        guard isRunning, id == currentTaskID, analyzerSession == nil else { return }
        if Date().timeIntervalSince(lastTaskStart) < 1, latestText[id] == nil {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        if quickFailures >= 5 {
            NSLog("[Meeting] recognizer keeps failing immediately: %@", "\(error.map { "\($0)" } ?? "no error")")
            onFailure?("Speech recognition stopped working.")
            return
        }
        // Back off a little when a task dies straight away, so a broken recognizer can't spin.
        let delay = quickFailures > 0 ? 0.5 * Double(quickFailures) : 0
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, self.isRunning, id == self.currentTaskID else { return }
            self.startRecognitionTask()
        }
    }

    /// Hand off to a fresh segment before the current one hits the time limit.
    private func rotate() {
        guard isRunning, analyzerSession == nil else { return }
        let old = currentTaskID
        startRecognitionTask()
        requests[old]?.endAudio()   // its final result arrives shortly and is committed
    }

    private func commit(_ id: Int) {
        guard !committed.contains(id) else { return }
        committed.insert(id)
        tasks[id] = nil
        requests[id] = nil
        let text = (latestText.removeValue(forKey: id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinal?(text) }
    }

    // MARK: - Analyzer callbacks

    fileprivate func analyzerText(_ text: String, isFinal: Bool, from session: AnyObject) {
        // A replaced session can still deliver late results; they'd be duplicates.
        guard session === analyzerSession else { return }
        sink.noteResult()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !t.isEmpty { onFinal?(t) }
            lastVolatile = ""
            onVolatile?("")
        } else {
            lastVolatile = t
            onVolatile?(t)
        }
    }

    /// The analyzer's results ended by themselves (an error) while the meeting is running.
    fileprivate func analyzerEnded(_ session: AnyObject, reason: String) {
        guard isRunning, session === analyzerSession else { return }
        NSLog("[Meeting] watchdog: recognizer ended (%@) — restarting", reason)
        restartRecognizer(stalled: false)
    }

    private func commitVolatile() {
        if !lastVolatile.isEmpty { onFinal?(lastVolatile) }
        lastVolatile = ""
    }

    // MARK: - Watchdog

    /// Every 5 s: the mic should be delivering audio, and when people are clearly talking the
    /// recognizer should be producing text. Silence is fine; loud audio with no text isn't.
    private func checkHealth() {
        guard isRunning, !isRestarting else { return }
        let (sinceBuffer, loudSinceResult) = sink.watch()
        if sinceBuffer > 6 {
            NSLog("[Meeting] watchdog: no mic audio for %.0f s — re-arming", sinceBuffer)
            sink.resetWatch()
            rearm(attempt: 1)
        } else if loudSinceResult > 20 {
            // A 5-minute soak test froze for ~70 s with a 30 s threshold on 10 s checks; this
            // keeps the worst-case gap near 25 s.
            NSLog("[Meeting] watchdog: %.0f s of speech with no text — restarting recognizer", loudSinceResult)
            restartRecognizer(stalled: true)
        }
    }

    /// Replace the recognizer, keeping the mic running. At most 5 restarts in 10 minutes: past
    /// that, a recognizer that keeps ending ends the meeting, while a "stall" (loud audio, no
    /// text) is left alone — it may just be music or noise, and the meeting carries on.
    private func restartRecognizer(stalled: Bool) {
        guard isRunning, !isRestarting else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 600 }
        guard restartTimes.count < 5 else {
            if stalled {
                sink.resetWatch()
                NSLog("[Meeting] watchdog: restart limit reached — leaving the recognizer running")
            } else {
                onFailure?("Speech recognition keeps stopping.")
            }
            return
        }
        restartTimes.append(now)
        restartCount += 1
        sink.resetWatch()

        guard #available(iOS 26.0, *), let old = analyzerSession as? AnalyzerSession else {
            rotate()   // SFSpeech: a fresh segment
            return
        }
        isRestarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestarting = false }
            // Start the new recognizer first and switch the mic to it, so audio keeps flowing to
            // a live recognizer; then retire the old one. Only its unfinished words are lost to
            // it, and those are committed here.
            let session = try? await AnalyzerSession.make(
                locale: self.locale, owner: self, downloadIfMissing: false,
                languageName: self.languageName, onStatus: { _ in })
            guard self.isRunning else { return }
            self.commitVolatile()
            self.analyzerSession = session   // late results from the old session are ignored
            if let session {
                self.sink.handler = { [weak session] buffer in session?.feed(buffer) }
            }
            _ = await Self.finish(old, within: 3)
            guard self.isRunning else { return }
            if session != nil {
                NSLog("[Meeting] watchdog: recognizer restarted (%d)", self.restartCount)
            } else if self.fallbackIsOnDevice {
                NSLog("[Meeting] watchdog: SpeechAnalyzer unavailable — switching to SFSpeech")
                self.engineName = "SFSpeech on-device \(self.locale.identifier) (after restart)"
                self.startRecognitionTask()
                self.rotationTimer = Timer.scheduledTimer(withTimeInterval: Self.segmentLength, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.rotate() }
                }
            } else {
                self.onFailure?("Speech recognition stopped and couldn't restart.")
            }
        }
    }

    /// Finish a session, but give up waiting after `seconds`. True if it finished in time.
    @available(iOS 26.0, *)
    private static func finish(_ session: AnalyzerSession, within seconds: Double) async -> Bool {
        let done = DownloadOutcome()
        Task.detached { await session.finish(); done.set(nil) }
        let deadline = Date().addingTimeInterval(seconds)
        while !done.isDone, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !done.isDone { NSLog("[Meeting] recognizer didn't finish within %.0f s", seconds) }
        return done.isDone
    }

    // MARK: - Mic

    private func startMic() throws {
        try installTap()
        observeEngine()
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                // A call or Siri took the mic; take it back when they're done.
                Task { @MainActor in self?.rearm(attempt: 1) }
            }
        }
    }

    private func installTap() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingNotesError.micUnavailable }
        let sink = self.sink
        if let reason = OVCatchException({
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in sink.feed(buffer) }
        }) {
            NSLog("[Meeting] installTap failed: %@", reason)
            throw MeetingNotesError.micUnavailable
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// The notification is per engine object, so this is re-registered whenever the engine is rebuilt.
    private func observeEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearm(attempt: 1) }
        }
    }

    /// After a route change or interruption: a stopped engine reports the old input format, so
    /// build a new one, wait for the route to settle, and retry a few times.
    private func rearm(attempt: Int) {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.isRunning else { return }
            self.audioEngine = AVAudioEngine()
            do {
                try self.installTap()
                self.observeEngine()
                NSLog("[Meeting] mic re-armed (attempt %d)", attempt)
            } catch where attempt < 4 {
                self.rearm(attempt: attempt + 1)
            } catch {
                self.onFailure?("Lost the microphone.")
            }
        }
    }

    private func stopMic() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }
}

enum MeetingNotesError: LocalizedError {
    case recognizerUnavailable, micUnavailable, notAuthorized, alreadyRunning
    case languageNotSupported(String)
    case languageNeedsDownload(String)
    /// Stopped before listening began (usually during a model download).
    case cancelled

    var errorDescription: String? {
        switch self {
        case .languageNotSupported(let name):
            return "\(name) can't be transcribed on this phone. Pick another language in Settings → Voice → Meeting Notes."
        case .cancelled:
            return "Stopped before listening started."
        case .languageNeedsDownload(let name):
            return "The \(name) speech model needs a one-time download. Connect to the internet and try again."
        case .recognizerUnavailable: return "Speech recognition isn't available right now."
        case .micUnavailable: return "The microphone isn't available. Is a call in progress?"
        case .notAuthorized: return "Meeting notes need microphone and speech recognition access."
        case .alreadyRunning: return "Meeting notes are already running."
        }
    }
}

/// Result of a background model download, read from the main actor while it runs.
private final class DownloadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var _error: Error?

    func set(_ error: Error?) { lock.lock(); done = true; _error = error; lock.unlock() }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
}

/// Hands mic buffers from the audio thread to whichever recognizer is active. The handler is
/// swapped on the main actor and read on the render thread, so it's guarded by a lock.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: ((AVAudioPCMBuffer) -> Void)?

    var handler: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    // Watchdog readings, written on the render thread.
    private var lastBufferAt = CFAbsoluteTimeGetCurrent()
    private var loudSecondsSinceResult: Double = 0

    func feed(_ buffer: AVAudioPCMBuffer) {
        // Peak level of the first channel: speech is well above 0.02 on the phone mic; a quiet
        // room stays below it.
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var i = 0
            while i < n { peak = max(peak, abs(data[i])); i += 4 }
        }
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        lock.lock()
        lastBufferAt = CFAbsoluteTimeGetCurrent()
        if peak > 0.02 { loudSecondsSinceResult += seconds }
        let h = _handler
        lock.unlock()
        h?(buffer)
    }

    /// Text arrived: the recognizer is alive.
    func noteResult() { lock.lock(); loudSecondsSinceResult = 0; lock.unlock() }

    func resetWatch() {
        lock.lock(); lastBufferAt = CFAbsoluteTimeGetCurrent(); loudSecondsSinceResult = 0; lock.unlock()
    }

    /// (seconds since the last mic buffer, seconds of loud audio since the last text)
    func watch() -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }
        return (CFAbsoluteTimeGetCurrent() - lastBufferAt, loudSecondsSinceResult)
    }
}

// MARK: - SpeechAnalyzer (iOS 26)

@available(iOS 26.0, *)
private final class AnalyzerSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.analyzer = analyzer
        self.continuation = continuation
        self.format = format
    }

    /// nil when the language isn't supported, or its model isn't installed and `downloadIfMissing`
    /// is false (the download then starts in the background for next time). With
    /// `downloadIfMissing`, waits for the download and throws if it fails.
    @MainActor
    static func make(locale: Locale, owner: MeetingTranscriber, downloadIfMissing: Bool,
                     languageName: String, onStatus: @escaping (String?) -> Void) async throws -> AnalyzerSession? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            NSLog("[Meeting] SpeechAnalyzer doesn't support %@", locale.identifier)
            return nil
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard status == .supported || status == .downloading else { return nil }
            @Sendable func download(progress: (@MainActor (Double) -> Void)? = nil) async throws {
                try? await AssetInventory.reserve(locale: supported)
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
                // Report progress twice a second while the download runs.
                let reporter = Task { @MainActor in
                    var lastLogged = -1
                    while !Task.isCancelled {
                        let fraction = request.progress.fractionCompleted
                        progress?(fraction)
                        let pct = Int(fraction * 100)
                        if pct / 10 != lastLogged / 10 { NSLog("[Meeting] model download %d%%", pct); lastLogged = pct }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                defer { reporter.cancel() }
                try await request.downloadAndInstall()
                NSLog("[Meeting] SpeechAnalyzer model for %@ downloaded", supported.identifier)
            }
            guard downloadIfMissing else {
                Task.detached { try? await download() }
                NSLog("[Meeting] SpeechAnalyzer model for %@ not installed (%@) — on-device fallback this time", supported.identifier, "\(status)")
                return nil
            }
            onStatus("Downloading the \(languageName) speech model (one time)…")
            NSLog("[Meeting] downloading SpeechAnalyzer model for %@", supported.identifier)
            // The download runs on its own, so stopping during it returns at once; the download
            // carries on and the next meeting can use the model.
            let outcome = DownloadOutcome()
            Task.detached {
                do {
                    try await download(progress: { fraction in
                        onStatus("Downloading the \(languageName) speech model (one time)… \(Int(fraction * 100))%")
                    })
                    outcome.set(nil)
                } catch {
                    outcome.set(error)
                }
            }
            while !outcome.isDone {
                guard owner.isRunning else { throw MeetingNotesError.cancelled }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if let error = outcome.error {
                NSLog("[Meeting] model download failed: %@", "\(error)")
                throw MeetingNotesError.languageNeedsDownload(languageName)
            }
            guard owner.isRunning else { throw MeetingNotesError.cancelled }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw MeetingNotesError.languageNeedsDownload(languageName)
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let session = AnalyzerSession(analyzer: analyzer, continuation: continuation, format: format)
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            NSLog("[Meeting] SpeechAnalyzer failed to start: %@ — using SFSpeech", "\(error)")
            continuation.finish()
            return nil
        }
        session.resultsTask = Task { [weak owner, weak session] in
            var reason = "finished"
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        if let session { owner?.analyzerText(text, isFinal: isFinal, from: session) }
                    }
                }
            } catch {
                reason = "\(error)"
                NSLog("[Meeting] SpeechAnalyzer results ended: %@", reason)
            }
            // Ending is normal after finish(); the owner ignores it unless this is still the
            // live session of a running meeting.
            await MainActor.run {
                if let session { owner?.analyzerEnded(session, reason: reason) }
            }
        }
        return session
    }

    /// Called on the audio render thread: convert to the analyzer's format and queue it.
    func feed(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// Finish the input, wait for the last results, and stop.
    func finish() async {
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("[Meeting] SpeechAnalyzer finalize failed: %@", "\(error)")
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
    }
}
