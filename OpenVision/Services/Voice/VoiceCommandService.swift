// OpenVision - VoiceCommandService.swift
// Wake word detection and voice command capture using Apple Speech Recognition

import Foundation
import Speech
import AVFoundation

/// Voice command service with wake word detection
///
/// Features:
/// - Wake word detection ("Ok Vision")
/// - Command capture after wake word
/// - Silence detection to end command
/// - Conversation mode (follow-ups without wake word)
/// - Barge-in support
@MainActor
final class VoiceCommandService: ObservableObject {
    // MARK: - Singleton

    static let shared = VoiceCommandService()

    // MARK: - Published State

    @Published var state: ListeningState = .idle
    @Published var isListening: Bool = false
    @Published var currentTranscription: String = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // MARK: - Listening State

    enum ListeningState: Equatable {
        /// Waiting for wake word
        case idle

        /// Wake word detected, capturing command
        case listening

        /// In conversation mode, waiting for follow-up
        case conversationMode

        /// Processing captured command
        case processing
    }

    // MARK: - Configuration

    var wakeWord: String {
        SettingsManager.shared.settings.wakeWord
    }

    var isWakeWordEnabled: Bool {
        SettingsManager.shared.settings.wakeWordEnabled
    }

    var playActivationSound: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    // MARK: - Callbacks

    /// Called when wake word is detected
    var onWakeWordDetected: (() -> Void)?

    /// Called when the user says a stop phrase ("stop", "ok vision stop") during TTS/processing.
    /// The app should halt everything and go quiet; the recognizer is reset to wake-word idle here.
    var onStopCommand: (() -> Void)?

    /// Called when a command is captured
    var onCommandCaptured: ((String) -> Void)?

    /// Called when user interrupts (barge-in)
    var onInterruption: (() -> Void)?

    /// Called when conversation mode times out (no speech detected)
    var onConversationTimeout: (() -> Void)?

    // MARK: - Barge-in Control

    /// When true, barge-in detection is paused (e.g., during TTS playback)
    var isBargeInPaused: Bool = false

    /// Returns true if TTS is currently playing (allows wake word to interrupt)
    var shouldAllowInterrupt: (() -> Bool)?

    // MARK: - Speech Recognition

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Identity of the CURRENT recognition task. A canceled SFSpeechRecognitionTask still delivers
    /// dying callbacks (stale partials, an empty final, a "canceled" error). Without this guard
    /// those zombie callbacks are indistinguishable from the live recognizer ending — each
    /// restart's own corpse then scheduled the next restart, tearing the recognizer down every
    /// second and chopping user speech into unrecognizable fragments (commands never transcribed).
    /// Every (re)start bumps the generation; callbacks from older generations are dropped.
    private var recognitionGeneration = 0

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    /// Throttle for the wake-word auto-restart. On some audio routes (notably the glasses'
    /// Bluetooth HFP mic) the recognizer finalizes immediately, and restarting with no delay
    /// spins a tight infinite loop that freezes the app. We coalesce restarts to at most one
    /// every `minRestartInterval`.
    private var lastRecognizerRestart = Date.distantPast
    private var wakeWordRestartScheduled = false
    private let minRestartInterval: TimeInterval = 0.6

    // MARK: - Timers

    private var silenceTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var conversationTimeoutTimer: Timer?
    private var wakeWordCooldownActive: Bool = false

    // MARK: - Voice activity detection

    /// Acoustic end-of-speech detection. When available it replaces the transcript-timing silence
    /// timer, which could never tell "still talking" from "done" — see SpeechActivityDetector.
    private let speechDetector = SpeechActivityDetector()

    /// True once VAD has told us speech stopped and we're waiting out `Constants.Voice
    /// .vadCommitGrace` before committing the turn. Cleared if speech resumes.
    private var vadCommitPending = false

    /// Tracks if user has started speaking in this turn
    private var hasSpokenThisTurn: Bool = false

    // MARK: - Audio Feedback

    private var activationSound: AVAudioPlayer?

    // MARK: - Initialization

    private init() {
        setupActivationSound()
        setupSpeechDetector()
    }

    /// Wire VAD events and load the model. The model load is async and may fail (no assets, older
    /// device); until/unless it succeeds `speechDetector.isAvailable` stays false and end-of-turn
    /// silently keeps using the transcript-timing timer.
    private func setupSpeechDetector() {
        speechDetector.onSpeechStart = { [weak self] in
            guard let self else { return }
            // Speech resumed — whatever pause we were counting out was mid-sentence, not the end.
            self.vadCommitPending = false
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
        }
        speechDetector.onSpeechEnd = { [weak self] in
            self?.handleSpeechEnded()
        }
        Task { await speechDetector.start() }
    }

    /// VAD says the mic went quiet. This is the signal the old timer was only ever approximating,
    /// so the wait after it can be short: Silero has already absorbed ~0.75s of hysteresis, and
    /// speech resuming cancels this via `onSpeechStart`.
    private func handleSpeechEnded() {
        // Only the command-capture states commit a turn; idle/processing ignore end-of-speech.
        guard state == .listening || state == .conversationMode else { return }
        guard hasSpokenThisTurn, !currentTranscription.isEmpty else { return }

        print("[VoiceCommand] VAD end-of-speech → committing in \(Constants.Voice.vadCommitGrace)s: '\(currentTranscription)'")
        // Turn latency starts counting from the moment the user actually stopped talking.
        MetricsCollector.shared.markSpeechEnd()
        vadCommitPending = true
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.Voice.vadCommitGrace, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.vadCommitPending else { return }
                self.vadCommitPending = false
                self.handleSilenceTimeout()
            }
        }
    }

    // MARK: - Authorization

    /// Request speech recognition authorization
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self.authorizationStatus = status
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Start/Stop

    /// While true, the mic belongs to something else (meeting notes) and `startListening` does
    /// nothing. Every other restart path already requires `isListening`, so this one guard keeps
    /// the wake-word listener off until whoever suspended it calls `resume`.
    private(set) var isSuspended = false

    /// Stop listening and keep it stopped, whoever asks to start it, until `resume()`.
    func suspend() {
        isSuspended = true
        stopListening()
    }

    func resume() {
        isSuspended = false
    }

    /// Start listening for wake word or commands
    func startListening() throws {
        guard authorizationStatus == .authorized else {
            throw VoiceCommandError.notAuthorized
        }

        guard !isListening else { return }
        guard !isSuspended else {
            print("[VoiceCommand] Suspended (meeting notes own the mic) — not starting")
            return
        }

        // Setup audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw VoiceCommandError.requestCreationFailed
        }

        configureRecognitionRequest(recognitionRequest)

        // Get input node
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against an invalid input format. This happens when the mic is unavailable —
        // most commonly while the user is on a phone/FaceTime call, where the input route
        // reports 0 Hz / 0 channels. Installing a tap with that format throws (SIGABRT),
        // so bail gracefully instead of crashing.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable (format \(recordingFormat.sampleRate)Hz/\(recordingFormat.channelCount)ch) — mic likely in use by a call. Skipping listen.")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Install tap — wrapped so an AVAudioEngine NSException (mic busy / bad route, e.g.
        // during a phone call) fails gracefully instead of aborting the process.
        //
        // The block runs on the Core Audio render thread, so it must stay allocation-light and
        // must not touch main-actor state. `feed` only converts + buffers, handing full chunks to
        // the detector's own consumer (see SpeechActivityDetector's threading note).
        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
        }) {
            print("[VoiceCommand] installTap failed: \(reason)")
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Start audio engine first (before recognition task)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[VoiceCommand] Failed to start audio engine: \(error)")
            // Clean up
            audioEngine.inputNode.removeTap(onBus: 0)
            self.recognitionRequest = nil
            self.audioEngine = nil
            throw VoiceCommandError.audioEngineUnavailable
        }

        // Start recognition task after audio engine is running
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }  // zombie task
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        isListening = true
        state = isWakeWordEnabled ? .idle : .listening
        print("[VoiceCommand] Started listening - audio engine running")
    }

    /// Prime the recognizer for the wake phrase and short-phrase detection. `contextualStrings`
    /// biases recognition toward "Ok Vision", which is the single biggest factor in reliably
    /// hearing the wake word over the low-quality glasses Bluetooth-HFP mic (8 kHz). `.search`
    /// (short phrase) beats `.dictation` (long-form) for a quick wake word + command.
    private func configureRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest) {
        request.shouldReportPartialResults = true
        request.taskHint = .search
        var phrases = ["Ok Vision", "Okay Vision", "Hey Vision", "Vision"]
        if !wakeWord.isEmpty { phrases.insert(wakeWord, at: 0) }
        request.contextualStrings = phrases
    }

    /// SFSpeechRecognizer stops after ~1 minute or when it emits a final result / errors. While
    /// idling for the wake word that would silently kill listening ("responds once in a while"),
    /// so restart a fresh recognizer whenever the task ends and we're still meant to be listening.
    private func restartIfRecognizerEnded(result: SFSpeechRecognitionResult?, error: Error?) {
        let ended = (error != nil) || (result?.isFinal ?? false)
        // Idle (wake-word) AND conversation mode both rely on an always-running recognizer with no
        // other flow to revive it. Restricting this to `.idle` caused a deaf-mic race: an empty
        // final result arriving while still in conversationMode skipped the restart here, then the
        // conversation timeout returned to idle with a dead recognizer — and every "Ok Vision"
        // after that hit silence. (`.listening`/`.processing` are excluded on purpose: their
        // restarts are owned by handleCommandComplete / the TTS flow.)
        let needsAlwaysOnRecognizer = (state == .idle && isWakeWordEnabled) || state == .conversationMode
        guard ended, isListening, needsAlwaysOnRecognizer else { return }
        if let error { print("[VoiceCommand] Recognizer ended (\(error.localizedDescription)) — will relaunch listener") }
        scheduleWakeWordRestart()
    }

    /// Relaunch the wake-word recognizer, but never more than once per `minRestartInterval`.
    /// If the recognizer keeps ending immediately (e.g. a flaky Bluetooth HFP mic), this makes it
    /// retry ~1×/second instead of spinning thousands of times a second and freezing the app.
    private func scheduleWakeWordRestart() {
        guard !wakeWordRestartScheduled else { return }   // coalesce a burst of "ended" callbacks
        wakeWordRestartScheduled = true
        let delay = max(0, minRestartInterval - Date().timeIntervalSince(lastRecognizerRestart))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.wakeWordRestartScheduled = false
            // Same states as restartIfRecognizerEnded: idle wake-word listening or conversation
            // mode. The state may legitimately have flipped between scheduling and firing (e.g.
            // conversationMode → timeout → idle); both still need a live recognizer.
            let stillNeedsRecognizer = (self.state == .idle && self.isWakeWordEnabled)
                || self.state == .conversationMode
            guard self.isListening, stillNeedsRecognizer else { return }
            self.lastRecognizerRestart = Date()
            self.restartRecognition()
        }
    }

    /// Stop listening
    func stopListening() {
        recognitionGeneration += 1   // orphan any in-flight callbacks from the dying task
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // The tap is gone, so no more audio reaches VAD; drop buffered samples and any pending
        // commit so a restart begins clean.
        speechDetector.reset()
        vadCommitPending = false

        silenceTimer?.invalidate()
        silenceTimer = nil
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil

        isListening = false
        state = .idle
        currentTranscription = ""
        hasSpokenThisTurn = false
        print("[VoiceCommand] Stopped listening")
    }

    /// Enter conversation mode (no wake word needed for follow-ups)
    func enterConversationMode() {
        // Restart recognition to clear accumulated transcription
        restartRecognition()

        state = .conversationMode
        hasSpokenThisTurn = false
        currentTranscription = ""

        // Start conversation timeout (exits if no speech for 4 seconds)
        startConversationTimeout()

        print("[VoiceCommand] Entered conversation mode")
    }

    /// Restart speech recognition to clear buffer
    private func restartRecognition() {
        guard isListening else { return }

        // Stop current recognition. Bump the generation FIRST so the canceled task's dying
        // callbacks (delivered async) are orphaned immediately, not just once the new task exists.
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Remove tap and stop engine briefly
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Create new recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        configureRecognitionRequest(recognitionRequest)

        // Reinstall tap
        guard let audioEngine = audioEngine else { return }

        // The glasses camera's Bluetooth route change can silently STOP the running engine (the
        // recognizer then looks alive but hears nothing). Revive the same engine instead of tearing
        // it down — a rebuild would force a fresh HFP/SCO negotiation the glasses can't service
        // right after streaming, leaving the mic deaf. This mirrors OpenGlasses' persistent engine.
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                print("[VoiceCommand] Engine had stopped (route change) — restarted in place")
            } catch {
                print("[VoiceCommand] Engine restart failed: \(error)")
            }
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0) // defensive: never install over an existing tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Skip if the mic is unavailable (e.g. on a call) — installing a tap with a
        // 0 Hz / 0 channel format throws.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("[VoiceCommand] Input unavailable on reinstall — skipping tap")
            self.recognitionRequest = nil
            return
        }

        // Reinstall may follow a route change (phone mic <-> glasses HFP), so the detector's
        // cached converter is built for the OLD format and would emit garbage — drop it.
        speechDetector.reset()
        let detector = speechDetector
        if let reason = OVCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                detector.feed(buffer)
            }
        }) {
            print("[VoiceCommand] installTap (reinstall) failed: \(reason)")
            self.recognitionRequest = nil
            return
        }

        // Start new recognition task
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }  // zombie task
                self.handleRecognitionResult(result: result, error: error)
                self.restartIfRecognizerEnded(result: result, error: error)
            }
        }

        print("[VoiceCommand] Restarted recognition (cleared buffer)")
        // Restart churn is the proxy for recognizer health: a high rate here is what shreds
        // transcripts into fragments like "53258 Okay Vision".
        MetricsCollector.shared.count("recognition_restart")
    }

    /// Exit conversation mode
    func exitConversationMode() {
        state = isWakeWordEnabled ? .idle : .listening
        vadCommitPending = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil
        hasSpokenThisTurn = false
        // Don't trust the recognizer to still be alive here: if it emitted its final result while
        // we were still in conversationMode, no restart fired and idle would sit deaf to the wake
        // word. Relaunch unconditionally — this also clears any stale transcript buffer.
        restartRecognition()
        print("[VoiceCommand] Exited conversation mode")
    }

    /// Start conversation timeout (auto-exit after silence)
    private func startConversationTimeout() {
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleConversationTimeout()
            }
        }
    }

    /// Handle conversation timeout - exit if user hasn't spoken
    private func handleConversationTimeout() {
        guard state == .conversationMode else { return }

        if hasSpokenThisTurn {
            // User spoke, wait for them to finish (silence timer handles this)
            print("[VoiceCommand] User is speaking, extending conversation")
        } else {
            // No speech detected, exit conversation mode
            print("[VoiceCommand] Conversation timeout - no speech detected")
            exitConversationMode()
            onConversationTimeout?()
        }
    }

    // MARK: - Recognition Handling

    /// Handle recognition result
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        // Guard: must be actively listening
        guard isListening else {
            print("[VoiceCommand] Ignoring result - not listening")
            return
        }

        guard let result = result else {
            if let error = error {
                let errorMsg = error.localizedDescription
                // Ignore common non-critical errors
                if !errorMsg.contains("No speech detected") && !errorMsg.contains("canceled") {
                    print("[VoiceCommand] Recognition error: \(error)")
                }
            }
            return
        }

        let transcription = result.bestTranscription.formattedString
        print("[VoiceCommand] 🎤 heard(\(state)): \"\(transcription)\"")

        switch state {
        case .idle:
            currentTranscription = transcription
            // Check for wake word
            if detectWakeWord(in: transcription) {
                handleWakeWordDetected()
            }

        case .listening, .conversationMode:
            // Strip wake word from transcription (like xmeta does)
            var command = transcription
            for ww in [wakeWord.lowercased(), "ok vision", "okay vision", "hey vision", "hi vision"] {
                if let range = command.lowercased().range(of: ww) {
                    command = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            currentTranscription = command

            // Mark that user has started speaking
            if command.count > 3 {
                hasSpokenThisTurn = true
                // Cancel conversation timeout since user is speaking
                conversationTimeoutTimer?.invalidate()
            }

            // Reset silence timer on new speech
            resetSilenceTimer()

            // Check for command completion
            if result.isFinal && !command.isEmpty {
                handleCommandComplete(command)
            }

        case .processing:
            // Check for wake word to interrupt TTS (e.g., "ok vision stop")
            let allowInterrupt = shouldAllowInterrupt?() ?? false

            // "Ok Vision stop" / "stop" during TTS → FULL STOP. Handle this before the general
            // barge-in: halt everything and go quiet. Critically, reset recognition to clear the
            // buffer — the transcript still starts with "ok vision", so without a reset it would
            // re-match this branch on every partial result and churn listening/processing forever.
            if allowInterrupt && isStopPhrase(transcription) {
                print("[VoiceCommand] Stop phrase during TTS — halting")
                onStopCommand?()
                currentTranscription = ""
                hasSpokenThisTurn = false
                silenceTimer?.invalidate(); silenceTimer = nil
                state = isWakeWordEnabled ? .idle : .listening
                restartRecognition()   // clear the stale "ok vision ... stop" buffer
                return
            }

            // The at-start requirement is ECHO defense: while a reply plays, the mic transcribes
            // the reply's own audio, and a wake word mid-buffer is suspect. But during THINKING
            // no reply audio exists — everything in the buffer is the user — and requiring the
            // wake word first discarded genuine interrupts whenever the user led with natural
            // preamble ("hey, ...ok vision, new question"): the log showed eight detections, all
            // dropped. isBargeInPaused is true exactly while either engine is audible, so it is
            // the precise boundary between the two regimes.
            if allowInterrupt && detectWakeWord(in: transcription, bypassCooldown: true)
                && (wakeWordAtStart(transcription) || !isBargeInPaused) {
                // A BARE "Ok Vision" with nothing after it, mid-reply, is almost always the mic
                // hallucinating the wake word from the reply audio the speaker is playing (echo) —
                // NOT a deliberate interrupt. Real interrupts carry a follow-up ("Ok Vision, what
                // about Mars?"). Require that command; otherwise ignore and let the reply finish.
                // (To simply silence a reply, "Ok Vision stop" is handled by the stop-phrase branch
                // above.)
                let command = extractCommandAfterWakeWord(transcription)
                guard !command.isEmpty else { return }

                print("[VoiceCommand] Wake word + command during TTS - interrupting: '\(command)'")

                // Notify to stop TTS immediately
                onWakeWordDetected?()

                // Switch to listening mode - like xmeta's isCapturingCommand = true
                state = .listening
                currentTranscription = command
                hasSpokenThisTurn = true

                // Start silence timer to wait for user to finish speaking
                resetSilenceTimer()

                // If result is already final, process it
                if result.isFinal {
                    print("[VoiceCommand] Result is final, processing command immediately")
                    handleCommandComplete(command)
                }
                return
            }

            // NOTE: no naive "any speech" barge-in here. detectSpeechStart is just `count > 3`, so
            // during the processing→speaking window it fired on our OWN audio — the command echo
            // (before TTS starts, when isBargeInPaused is still false) and the reply the mic hears
            // back — flipping the UI to "Listening" mid-reply and tearing the session down. Deliberate
            // interruption is handled above: "Ok Vision …" (wake word at start) or a stop phrase.
        }
    }

    /// True when the user asked to stop during TTS: the transcript contains BOTH the wake word and
    /// a stop word. Requiring the wake word means the TTS reply's own words (which the mic hears
    /// through the glasses) can't false-trigger a stop. Excludes "stop video/stream" — that's a
    /// live-video command handled elsewhere.
    private func isStopPhrase(_ text: String) -> Bool {
        guard detectWakeWord(in: text, bypassCooldown: true) else { return false }
        let lower = text.lowercased()
        if lower.contains("video") || lower.contains("stream") { return false }
        let stopWords = ["stop", "be quiet", "shut up", "silence", "quiet", "enough", "cancel"]
        return stopWords.contains { lower.contains($0) }
    }

    /// True when a wake-word variation sits at (or very near) the START of the transcript — i.e. a
    /// deliberate "Ok Vision …" barge-in. During TTS the mic also hears the reply itself, whose
    /// transcription can incidentally contain a "…vision…" buried mid-sentence; requiring the wake
    /// word up front rejects those phantoms while still catching a real interrupt.
    private func wakeWordAtStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        let variations = [
            wakeWord.lowercased(),
            "ok vision", "okay vision", "o.k. vision", "o k vision",
            "hey vision", "hi vision",
            "a vision", "heavy vision", "have vision", "obey vision", "oak vision"
        ]
        for v in variations {
            if let r = lower.range(of: v) {
                // Characters of speech before the wake word. A little leeway ("uh, ok vision")
                // is fine; a whole sentence in front of it means it's echo, not a barge-in.
                if lower.distance(from: lower.startIndex, to: r.lowerBound) <= 12 { return true }
            }
        }
        return false
    }

    /// Detect wake word in transcription
    private func detectWakeWord(in text: String, bypassCooldown: Bool = false) -> Bool {
        guard bypassCooldown || !wakeWordCooldownActive else { return false }

        let lowercased = text.lowercased()
        let wakeWordLower = wakeWord.lowercased()

        // Check for exact match or common variations/misrecognitions
        let variations = [
            wakeWordLower,
            // OK Vision variants (most reliable)
            "ok vision",
            "okay vision",
            "o.k. vision",
            "o k vision",
            // Ok Vision variants
            "hey vision",
            "hi vision",
            // Common misrecognitions
            "a vision",
            "heavy vision",
            "have vision",
            "obey vision",
            "oak vision"
        ]

        let detected = variations.contains { lowercased.contains($0) }
        if detected {
            print("[VoiceCommand] Detected wake word in: '\(text)'")
        }
        return detected
    }

    /// Extract command text after wake word
    private func extractCommandAfterWakeWord(_ text: String) -> String {
        let lowercased = text.lowercased()
        let wakeWordLower = wakeWord.lowercased()

        let variations = [
            wakeWordLower,
            "ok vision", "okay vision", "o.k. vision", "o k vision",
            "hey vision", "hi vision",
            "a vision", "heavy vision", "have vision", "obey vision", "oak vision"
        ]

        for variation in variations {
            if let range = lowercased.range(of: variation) {
                let afterWakeWord = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return afterWakeWord
            }
        }
        return ""
    }

    /// Handle wake word detection
    private func handleWakeWordDetected() {
        print("[VoiceCommand] Wake word detected!")
        MetricsCollector.shared.count("wake_word_detected")

        // Activate cooldown
        wakeWordCooldownActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Voice.wakeWordCooldown) { [weak self] in
            self?.wakeWordCooldownActive = false
        }

        // Play activation sound
        if playActivationSound {
            playActivation()
        }

        // Transition to listening
        state = .listening
        currentTranscription = ""

        // Start command timeout
        startCommandTimeout()

        onWakeWordDetected?()
    }

    /// Handle command complete
    private func handleCommandComplete(_ text: String) {
        // Remove wake word from beginning
        var command = text
        let wakeWordLower = wakeWord.lowercased()

        for prefix in [wakeWordLower, "hey vision", "ok vision", "okay vision"] {
            if command.lowercased().hasPrefix(prefix) {
                command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !command.isEmpty else { return }

        print("[VoiceCommand] Command captured: \(command)")
        MetricsCollector.shared.count("command_captured")

        state = .processing
        silenceTimer?.invalidate()
        commandTimeoutTimer?.invalidate()
        // Turn is committed; a late VAD speech-end must not fire a second commit.
        vadCommitPending = false

        // Clear transcription to prevent re-sending the same command
        currentTranscription = ""

        // Reset the recognizer's OWN buffer too. `currentTranscription = ""` only clears our copy;
        // the live SFSpeechRecognitionResult keeps accumulating the whole utterance. Without this,
        // the captured command ("…sun and the moon") lingers in the buffer during TTS, and a single
        // misheard "Okay Vision" (from the reply audio / ambient) tacks onto it and false-fires the
        // wake-word interrupt — cutting the reply off and flipping the UI back to "Listening".
        restartRecognition()

        onCommandCaptured?(command)
    }

    /// Handle barge-in (user interrupts AI)
    private func handleBargeIn() {
        print("[VoiceCommand] Barge-in detected")
        state = .listening
        onInterruption?()
    }

    /// Detect if user started speaking
    private func detectSpeechStart(in text: String) -> Bool {
        return text.count > 3 // Simple heuristic
    }

    // MARK: - Timers

    /// Reset the transcript-timing silence timer — the FALLBACK end-of-turn path.
    ///
    /// When VAD is available the turn is committed from `onSpeechEnd` instead, and this does
    /// nothing: re-arming here on every partial result would fight the VAD commit, and the long
    /// timeout would silently win whenever a partial happened to land during the grace window.
    ///
    /// Without VAD we keep the historical behaviour. The timeout stays deliberately long because
    /// this signal measures "no new transcript for N seconds", NOT silence — SFSpeechRecognizer
    /// emits partials in bursts with ~1s gaps mid-sentence, so anything short cuts the user off.
    private func resetSilenceTimer() {
        guard !speechDetector.isAvailable else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSilenceTimeout()
            }
        }
    }

    /// Handle silence timeout
    private func handleSilenceTimeout() {
        guard state == .listening || state == .conversationMode else { return }

        // Covers the no-VAD fallback path; idempotent, so it's a no-op when VAD already marked it.
        MetricsCollector.shared.markSpeechEnd()

        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else if state == .conversationMode {
            exitConversationMode()
        }
    }

    /// Start command timeout
    private func startCommandTimeout() {
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.Voice.commandTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleCommandTimeout()
            }
        }
    }

    /// Handle command timeout
    private func handleCommandTimeout() {
        guard state == .listening else { return }

        print("[VoiceCommand] Command timeout")

        if !currentTranscription.isEmpty {
            handleCommandComplete(currentTranscription)
        } else {
            state = .idle
            currentTranscription = ""
        }
    }

    // MARK: - Audio Feedback

    /// Setup activation sound
    private func setupActivationSound() {
        if let soundURL = Bundle.main.url(forResource: "activation_chime", withExtension: "wav") {
            activationSound = try? AVAudioPlayer(contentsOf: soundURL)
            activationSound?.prepareToPlay()
        }
    }

    /// Play activation sound
    private func playActivation() {
        activationSound?.currentTime = 0
        activationSound?.play()
    }
}

// MARK: - Errors

enum VoiceCommandError: LocalizedError {
    case notAuthorized
    case audioEngineUnavailable
    case requestCreationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized"
        case .audioEngineUnavailable: return "Audio engine unavailable"
        case .requestCreationFailed: return "Failed to create speech recognition request"
        }
    }
}
