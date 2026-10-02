// OpenVision - VoiceAgentViewModel.swift
// MVVM: all voice-session orchestration for the main screen lives here — session lifecycle,
// command routing, live video, face intents, photo capture, TTS streaming, and history.
// VoiceAgentView renders this state and forwards user interactions; it holds no logic.
//
// The services are app-wide singletons; this ViewModel is their single orchestrator. Service
// callbacks capture self weakly — the services outlive any owner, so strong captures would pin
// the ViewModel forever.

import SwiftUI
import Speech

@MainActor
final class VoiceAgentViewModel: ObservableObject {

    // MARK: - Dependencies

    let settingsManager = SettingsManager.shared
    let glassesManager = GlassesManager.shared
    let voiceCommandService = VoiceCommandService.shared
    let geminiVision = GeminiVisionService.shared
    let geminiLive = GeminiLiveService.shared
    let openAIRealtime = OpenAIRealtimeService.shared
    let ttsService = TTSService.shared
    let soundService = SoundService.shared
    let audioCapture = AudioCaptureService()
    let audioPlayback = AudioPlaybackService()
    let sessionRecorder = SessionRecorder.shared

    // MARK: - Published UI state

    @Published var isSessionActive = false
    @Published var agentState: AgentState = .idle
    @Published var userTranscript = ""
    @Published var aiTranscript = ""
    @Published var currentToolName: String?
    @Published var errorMessage: String?
    /// Live Video Mode - uses Gemini Live or OpenAI Realtime for real-time audio + video
    @Published var isLiveVideoMode = false
    /// True when voice recognition is ready (audio engine running)
    @Published var isVoiceReady = false
    /// True while a POV demo recording (glasses video + mic audio) is in progress.
    @Published var isRecording = false
    /// Transient status shown after a recording finishes ("Saved to Photos" / a failure). Auto-clears.
    @Published var recordingStatus: String?

    // MARK: - Internal state

    // De-dup: the last command we processed and when (drops duplicate recognizer emissions).
    private var lastProcessedCommand = ""
    private var lastProcessedAt = Date.distantPast
    private var hasRequestedSpeechAuth = false

    /// The live-video backend currently driving audio/video (Gemini or OpenAI Realtime).
    /// Set when live video mode starts; used by stop/callbacks so both backends route correctly.
    private var activeLiveService: (any LiveVideoService)?

    /// Sentence-streaming TTS (Apple only): how many characters of the streamed reply have
    /// already been handed to the speech queue, and whether a streamed utterance is open.
    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false {
        didSet { if !ttsStreaming { streamingNeuralTTS = nil } }
    }
    /// The neural engine the open streamed reply started on (nil = Apple TTS). Captured once at
    /// beginStreaming so a Speech Engine change mid-reply can't send endStreaming to a different
    /// engine and leave the first one stuck speaking.
    private var streamingNeuralTTS: NeuralSpeechEngine?

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
    /// system utterances ("Live video mode active", error prompts) out of the History tab.
    private var historyAwaitingReply = false
    /// History (live modes): last streamed AI turn already recorded, to dedupe turn-complete events.
    private var historyLastLiveReply = ""

    /// Frame counter for logging
    private var videoFrameCount: Int = 0

    // MARK: - Agent State

    enum AgentState: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case toolRunning
        case liveVideo  // Live video mode - Gemini handles audio + video

        var displayText: String {
            switch self {
            case .idle: return "Tap to start"
            case .connecting: return "Connecting..."
            case .listening: return "Listening..."
            case .thinking: return "Thinking..."
            case .speaking: return "Speaking..."
            case .toolRunning: return "Running tool..."
            case .liveVideo: return "Live Video"
            }
        }

        var accentColor: Color {
            switch self {
            case .idle: return .gray
            case .connecting: return .orange
            case .listening: return .blue
            case .thinking: return .purple
            case .speaking: return .green
            case .toolRunning: return .orange
            case .liveVideo: return .red  // Red for live video recording indicator
            }
        }
    }

    // MARK: - View lifecycle

    func onAppear() {
        setupVoiceCommandService()
        setupGlassesCallbacks()
        preloadLocalModelIfNeeded()
        // Resume wake-word listening when returning to this screen. onDisappear stops it
        // (e.g. when navigating to Settings), and the one-time .task doesn't re-run on return —
        // so without this, the wake word stayed dead until you tapped the mic button.
        if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    func onDisappear() {
        voiceCommandService.stopListening()
    }

    // MARK: - Observed state changes (forwarded from the view's onChange hooks)

    func ttsSpeakingChanged(_ isSpeaking: Bool) {
        if isSpeaking {
            agentState = .speaking
            // Pause barge-in detection while TTS is playing
            // (prevents microphone picking up TTS and triggering interruption)
            voiceCommandService.isBargeInPaused = true
        } else {
            // Playback finished — closes the turn and publishes it to the metrics sinks.
            MetricsCollector.shared.markSpokeDone()
            commandTurnActive = false   // reply fully played; ambient narration may resume

            // Resume barge-in detection
            voiceCommandService.isBargeInPaused = false

            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    // Neural voices (Kokoro, Grok) drive the same speaking-state flow as Apple TTS: keep the recognizer running
    // (in .processing) with barge-in paused so it stays in the conversation loop, then enter
    // conversation mode when playback finishes. (Don't stopListening — that trips the .idle
    // session-teardown observer and ends the conversation after every reply.)
    func neuralSpeakingChanged(_ speaking: Bool) {
        // Each neural engine reports separately. One finishing (say a Kokoro preview, or an ambient
        // line) mustn't end the turn while another is still speaking a reply.
        if !speaking && NeuralSpeech.isAnySpeaking { return }
        if speaking {
            agentState = .speaking
            voiceCommandService.isBargeInPaused = true
        } else {
            // Neural engines have their OWN speaking-state callback, so instrumenting only
            // ttsSpeakingChanged left every Kokoro/Grok turn unpublished — device metrics kept
            // flowing while turn metrics silently vanished whenever Kokoro was selected.
            MetricsCollector.shared.markSpokeDone()
            commandTurnActive = false   // reply fully played; ambient narration may resume

            voiceCommandService.isBargeInPaused = false
            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    /// Control thinking sound based on agent state.
    func agentStateChanged(_ newState: AgentState) {
        if newState == .thinking || newState == .toolRunning {
            soundService.startThinkingSound()
        } else {
            soundService.stopThinkingSound()
        }
    }

    func voiceStateChanged(_ newState: VoiceCommandService.ListeningState) {
        print("[VoiceAgent] VoiceCommandService state changed to: \(newState)")
        switch newState {
        case .idle:
            // In live video mode, a silence timeout must NOT end the mode — the user expects
            // to keep asking questions (camera stays on) until they say "stop video". Re-arm
            // conversation mode so the next question is heard without a fresh wake word.
            if isLiveVideoMode {
                print("[VoiceAgent] Idle during live video — re-arming conversation mode")
                voiceCommandService.enterConversationMode()
                agentState = .liveVideo
                return
            }
            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking/.toolRunning command processing, .speaking a reply) is a transient from
            // our own stop/restart — e.g. the camera capture restarts the recognizer mid-command
            // — and must NOT tear the session down. (This is what left the wake word dead after a
            // face/camera command: the restart flipped to .idle during .thinking and killed the
            // session, so the post-reply audio rebuild never ran.)
            if isSessionActive && agentState == .listening {
                print("[VoiceAgent] Voice service idle, stopping session")
                isSessionActive = false
                agentState = .idle
                // Disconnect AI backend
                Task {
                    switch settingsManager.settings.aiBackend {
                    case .openClaw:
                        await OpenClawService.shared.disconnect()
                    case .geminiLive:
                        await GeminiLiveService.shared.disconnect()
                    case .openAI, .grok:
                        break   // stateless HTTP — nothing to disconnect
                    case .appleFoundation:
                        break   // OS-managed — nothing to disconnect
                    case .localGemma:
                        // Keep the on-device model LOADED so the next "Ok Vision" is instant.
                        // Unloading + reloading the ~3.6GB model per conversation was the cause
                        // of the "connecting…" lag and hangs. It stays resident until the app
                        // backgrounds or the user switches backend.
                        break
                    }
                }
            }
        case .listening, .conversationMode:
            // Keep the live indicator up in live video mode (don't clobber it back to
            // plain .listening, which would let the next idle tear the session down).
            if isLiveVideoMode {
                agentState = .liveVideo
            } else if ttsService.isSpeaking || NeuralSpeech.isAnySpeaking {
                // The recognizer restarts (→ conversation mode) mid-reply for barge-in; don't
                // let that flip the UI to "Listening" while the assistant is still speaking.
                agentState = .speaking
            } else if isSessionActive {
                agentState = .listening
            }
        case .processing:
            agentState = .thinking
        }
    }

    // MARK: - Session lifecycle

    func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        // Check configuration
        guard settingsManager.settings.isCurrentBackendConfigured else {
            errorMessage = "Please configure \(settingsManager.settings.aiBackend.displayName) in Settings"
            return
        }

        isSessionActive = true
        agentState = .connecting

        // Model memory follows the History conversation window (5-min inactivity), NOT the wake
        // session — every "Ok Vision" starts a new session, so clearing here made "what were we
        // just talking about?" fail seconds after the previous answer. Only reset memory when
        // enough time has passed that History would start a new conversation anyway.
        if !ConversationManager.shared.isCurrentConversationFresh {
            ConversationContext.shared.clear()
            AppleFoundationService.shared.resetContext()
        }

        // Configure audio routing for glasses if registered
        configureAudioForGlasses()

        // Connect to AI backend
        Task {
            do {
                switch settingsManager.settings.aiBackend {
                case .openClaw:
                    try await OpenClawService.shared.connect()
                    // Note: Streaming NOT auto-started in OpenClaw mode
                    // User says "start video stream" → startLiveVideoMode()
                    // User says "take a photo" → captureAndSendPhoto() starts streaming on-demand

                case .openAI:
                    try await OpenAIService.shared.connect()
                    // Stateless HTTP — photos are captured on-demand like OpenClaw.

                case .grok:
                    try await GrokService.shared.connect()
                    // Stateless HTTP — photos are captured on-demand like OpenAI.

                case .appleFoundation:
                    try await AppleFoundationService.shared.connect()
                    // On-device Apple model — text only; camera commands guide to a cloud backend.

                case .geminiLive:
                    try await GeminiLiveService.shared.connect()
                    // Start glasses streaming for Gemini Live mode
                    if glassesManager.isRegistered && !glassesManager.isStreaming {
                        print("[VoiceAgent] Starting glasses stream for Gemini Live...")
                        await glassesManager.startStreaming()
                    }

                case .localGemma:
                    // On-device Gemma: load the model (must be downloaded first).
                    // Text-only in Phase 1 — no glasses streaming needed.
                    try await GemmaLocalService.shared.connect(
                        modelId: settingsManager.settings.localGemmaModelId
                    )
                }

                agentState = .listening
                userTranscript = ""
                aiTranscript = ""

                // Start voice command listening for speech capture
                if voiceCommandService.authorizationStatus == .authorized {
                    if !voiceCommandService.isListening {
                        try? voiceCommandService.startListening()
                    }
                    // Put in listening mode (not waiting for wake word)
                    voiceCommandService.enterConversationMode()
                } else {
                    errorMessage = "Speech recognition not authorized"
                }

            } catch {
                errorMessage = "Failed to connect: \(error.localizedDescription)"
                isSessionActive = false
                agentState = .idle
            }
        }
    }

    /// Resume listening after a spoken response ends — camera and text commands end identically:
    /// the persistent audio engine keeps running through a capture (never torn down — a rebuild
    /// would force a fresh Bluetooth HFP negotiation the glasses can't service right after
    /// streaming, leaving the mic deaf). Conversation mode's silence timeout then returns to idle.
    private func resumeListeningAfterSpeaking() {
        voiceCommandService.enterConversationMode()
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
    /// and they're the connected audio device, otherwise the phone's built-in mic + loud speaker.
    /// Attempting glasses is what makes iOS expose the HFP mic — so we try it directly rather than
    /// pre-checking availability (which can't see HFP until it's allowed). Returns true on glasses.
    @discardableResult
    private func applyPreferredAudioRoute() -> Bool {
        // Never pick the glasses HFP mic while the camera is streaming: video saturates the
        // Bluetooth link, so the SCO audio channel can't be serviced. configureForGlasses() can
        // still "succeed" in that state, but the mic is deaf — commands are never transcribed
        // (seen when recording starts the stream before a wake-word session). Phone mic instead.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,
           (try? AudioSessionManager.shared.configureForGlasses()) == true {
            return true
        }
        // Glasses mic off, glasses not connected as audio, or no HFP input available → phone.
        // Loud speaker so spoken replies are audible (not the quiet earpiece).
        print("[VoiceAgent] Using iPhone mic + speaker (glasses mic off or unavailable)")
        try? AudioSessionManager.shared.configureForPhone()
        return false
    }

    private func configureAudioForGlasses() {
        // If we're already on the glasses' Bluetooth (HFP) route and still listening, do NOT tear
        // the audio session down and re-activate it. That re-activation renegotiates the HFP SCO
        // link, which the glasses render as a "Bluetooth connecting/closing" blip — heard on every
        // wake after the first (the route stays on HFP between sessions, so the re-config is pure
        // churn). Skipping it keeps SCO stable, so the wake chime plays cleanly each time.
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           !glassesManager.isStreaming,   // HFP is deaf while the camera streams — reconfigure to phone
           AudioSessionManager.shared.isBluetoothHFPActive, voiceCommandService.isListening {
            return
        }
        let wasListening = voiceCommandService.isListening
        if wasListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()
        if wasListening {
            try? voiceCommandService.startListening()
        }
    }

    func stopSession() {
        // If in live video mode, stop it first
        if isLiveVideoMode {
            Task {
                await stopLiveVideoMode()
            }
        }

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw:
                await OpenClawService.shared.disconnect()
            case .geminiLive:
                await GeminiLiveService.shared.disconnect()
            case .openAI, .grok:
                break   // stateless HTTP — nothing to disconnect
            case .appleFoundation:
                break   // OS-managed — nothing to disconnect
            case .localGemma:
                // Keep the on-device model loaded — see note in the .idle handler. Reloading it
                // per conversation was what made "Ok Vision" slow/flaky.
                break
            }

            // Stop glasses streaming (turns off LED)
            if glassesManager.isStreaming {
                print("[VoiceAgent] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()
        NeuralSpeech.stopAll()

        // Set session inactive FIRST to prevent callbacks from processing
        isSessionActive = false
        agentState = .idle

        // Handle voice command service based on wake word setting
        if settingsManager.settings.wakeWordEnabled {
            // Exit conversation mode but keep listening for wake word
            voiceCommandService.exitConversationMode()
        } else {
            // Wake word disabled - stop listening entirely to prevent
            // processing speech after session ends
            voiceCommandService.stopListening()
        }
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isLiveVideoMode = false
    }

    /// Full stop for "Ok Vision stop": silence all output, cancel any in-flight generation, and go
    /// quiet back to wake-word listening. The recognizer buffer is already reset by
    /// VoiceCommandService (so the stale transcript can't re-fire); here we just halt + end the turn.
    private func performFullStop() {
        // "Ok Vision stop" is an interruption too: the user cut the reply off. Close the turn
        // deterministically before stopping the engines — delivered-then-stopped turns finish
        // here (markSpokeDone is gated on firstAudio); a stop mid-thinking leaves the turn open
        // to be recorded as failed by the next beginTurn.
        MetricsCollector.shared.markInterrupted()
        MetricsCollector.shared.markSpokeDone()
        commandTurnActive = false
        ttsService.stop()
        NeuralSpeech.stopAll()
        audioPlayback.stop()
        ttsStreaming = false

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw: await OpenClawService.shared.interrupt()
            case .geminiLive: await GeminiLiveService.shared.interrupt()
            case .openAI, .grok: break   // single request/response — nothing to interrupt
            case .appleFoundation: AppleFoundationService.shared.interrupt()
            case .localGemma: GemmaLocalService.shared.interrupt()
            }
        }

        // In live video mode, a stop means SHUT UP, not "tear down my camera session" — the
        // same rule as the command-level matcher, applied to the mid-reply stop-phrase route.
        // (Verified on device: "Ok Vision stop" during a reply used to exit the whole mode.)
        // "Stop video" remains the exit phrase.
        if isLiveVideoMode {
            NSLog("[OV] live: stop phrase — silenced, staying in live mode")
            voiceCommandService.enterConversationMode()
            agentState = .liveVideo
            return
        }

        // Go quiet: end the turn, return to wake-word idle. Say "Ok Vision" to start again.
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isSessionActive = false
        agentState = .idle
    }

    // MARK: - Voice Command Setup

    /// Warm up the on-device model in the background so the FIRST "Ok Vision" is instant
    /// (no multi-second load on wake). Only when Local Gemma is the selected, downloaded backend.
    private func preloadLocalModelIfNeeded() {
        guard settingsManager.settings.aiBackend == .localGemma,
              settingsManager.settings.localGemmaModelReady else { return }
        Task {
            do {
                try await GemmaLocalService.shared.connect(modelId: settingsManager.settings.localGemmaModelId)
                print("[VoiceAgent] Local model preloaded — wake word will be instant")
            } catch {
                print("[VoiceAgent] Local model preload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Request speech recognition authorization
    func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            print("[VoiceAgent] Speech recognition authorized")
            startWakeWordListening()
        } else {
            print("[VoiceAgent] Speech recognition not authorized")
            errorMessage = "Speech recognition not authorized. Please enable in Settings."
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        print("[VoiceAgent] Setting up voice command callbacks")

        // Interruptible whenever the assistant holds the floor. This gate exists to stop the
        // reply's own audio (heard through the mic) from false-triggering the wake word — so it
        // must be true exactly when the assistant is producing output:
        //  - a reply speaking on EITHER engine. Checking only Apple TTS left barge-in dead for
        //    every Kokoro user: "Ok Vision stop" did nothing while Kokoro spoke.
        //  - generation still thinking: no reply audio exists yet, so a wake word heard then is
        //    genuinely the user — and it's the only way to cancel a long generation by voice.
        voiceCommandService.shouldAllowInterrupt = { [weak self] in
            guard let self else { return false }
            return self.ttsService.isSpeaking
                || NeuralSpeech.isAnySpeaking
                || self.agentState == .thinking
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Wake word detected!")
            HapticFeedback.medium()
            self.soundService.playWakeWordSound()

            // If TTS is speaking, stop it immediately (interrupt)
            if self.ttsService.isSpeaking || NeuralSpeech.isAnySpeaking {
                print("[VoiceAgent] Stopping TTS due to wake word interrupt")
                // Also an interruption: the user said the wake word over a reply in progress.
                MetricsCollector.shared.markInterrupted()
                // Close the turn NOW, deterministically: delivered-then-cut-off turns finish
                // here (markSpokeDone is gated on firstAudio); pre-audio ones stay open and are
                // recorded as failed by the next beginTurn. Leaving this to the engine's async
                // speaking-changed callback raced the next turn's speechEnd.
                MetricsCollector.shared.markSpokeDone()
                self.ttsService.stop()
                self.ttsStreaming = false   // keep flag in sync with the cleared stream
                NeuralSpeech.stopAll()
                self.audioPlayback.stop()
                // Cancel any in-flight on-device generation too — otherwise its next streamed
                // token would immediately restart speech we just stopped.
                GemmaLocalService.shared.interrupt()
                self.agentState = .listening
            }

            // Auto-start session if not already active (use Task to avoid blocking)
            Task { @MainActor in
                if !self.isSessionActive && self.settingsManager.settings.isCurrentBackendConfigured {
                    print("[VoiceAgent] Starting session from wake word...")
                    self.startSession()
                }
            }
        }

        // "Ok Vision stop" during a reply → full stop, go quiet (the recognizer is already reset
        // to wake-word idle by VoiceCommandService; here we just halt output + end the turn).
        voiceCommandService.onStopCommand = { [weak self] in
            print("[VoiceAgent] Full stop requested")
            self?.performFullStop()
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { [weak self] (command: String) in
            guard let self else { return }
            print("[VoiceAgent] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                print("[VoiceAgent] Ignoring command - session not active")
                return
            }

            self.userTranscript = command
            // Suspend ambient narration for the WHOLE turn (through reply playback).
            self.commandTurnActive = true
            // And CANCEL any in-flight ambient inference right now — describeFrame checks
            // Task.isCancelled per token, so the GPU frees within one decode step instead of
            // the question queueing ~4s behind a caption nobody asked for.
            if self.watchTask != nil { self.startWatchLoop() }

            // Telemetry: the turn is now the backend's problem — everything after this is
            // think time, and everything before it was endpointing.
            //
            // The model must be the one ACTUALLY LOADED, not `settings.localGemmaModelId`:
            // that setting is the *selected local model* and doesn't change when the active
            // backend is Apple Intelligence or a cloud service, so turns served by something
            // else were mislabelled as the local model — which made model comparisons in
            // Grafana quietly meaningless.
            let backend = self.settingsManager.settings.aiBackend
            MetricsCollector.shared.markCommit(
                backend: backend.rawValue,
                model: backend == .localGemma ? GemmaLocalService.shared.activeModelId : nil,
                ttsEngine: self.usingAppleTTS ? "apple" : self.settingsManager.settings.ttsEngine.rawValue
            )

            // History: every captured command is a user message (Meta AI records all glasses
            // prompts to its History tab; same idea, on-device).
            ConversationManager.shared.addUserMessage(command)
            self.historyAwaitingReply = true

            // Send command to AI backend
            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Barge-in detected")
            // Interruption rate is a satisfaction signal: users talk over an agent that is slow,
            // wrong, or too verbose. Recorded on the turn being interrupted.
            MetricsCollector.shared.markInterrupted()

            // Stop TTS immediately
            self.ttsService.stop()
            NeuralSpeech.stopAll()

            // Stop current AI response
            Task {
                switch self.settingsManager.settings.aiBackend {
                case .openClaw:
                    await OpenClawService.shared.interrupt()
                case .geminiLive:
                    await GeminiLiveService.shared.interrupt()
                case .openAI, .grok:
                    break   // single request/response — nothing to interrupt
                case .appleFoundation:
                    AppleFoundationService.shared.interrupt()
                case .localGemma:
                    GemmaLocalService.shared.interrupt()
                }
            }
        }

        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = { [weak self] in
            guard let self else { return }
            // In live video mode, silence must not end the session — the .idle state handler
            // re-arms conversation mode so the user can keep asking until they say "stop video".
            if self.isLiveVideoMode {
                print("[VoiceAgent] Conversation timeout during live video — staying live")
                return
            }
            print("[VoiceAgent] Conversation timeout - returning to idle")
            self.stopSession()
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        print("[VoiceAgent] Voice command callbacks setup complete")
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // Shared reply/state wiring — every AIBackend reports through the same two callbacks,
        // so wire them once for all. (Gemini Live is a streaming session and delivers replies
        // via its own transcription callbacks below; its protocol callbacks are inert.)
        for backend in AIBackendRegistry.all {
            backend.onAgentMessage = { [weak self] (message: String) in
                guard let self else { return }
                // In local live video mode replies must flow even if the session timer lapsed
                // while the user was silently looking around.
                guard self.isSessionActive || self.isLiveVideoMode else { return }
                self.aiTranscript = message
                // Reply text is final. For non-streaming backends this is also the first output
                // we ever saw, and markFirstToken is first-wins, so it stays accurate either way.
                MetricsCollector.shared.markFirstToken()
                MetricsCollector.shared.markGenerationDone()
                if self.ttsStreaming {
                    // A streamed utterance is open (local model + Apple TTS pipelining):
                    // flush the unspoken tail and close the session.
                    self.feedStreamingSpeech(message, isFinal: true)
                } else {
                    self.speakResponse(message)
                }
            }
            backend.onProcessingChanged = { [weak self] (isProcessing: Bool) in
                guard let self else { return }
                if isProcessing {
                    self.agentState = .thinking
                    // New reply: reset the sentence-streaming cursor for a clean start.
                    self.ttsStreaming = false
                    self.ttsStreamSpokenChars = 0
                } else {
                    // Generation ended (always fires via defer, even when interrupted/superseded).
                    // If a streamed utterance is still open, onAgentMessage never fired to close it —
                    // close it here so streamingActive/isSpeaking don't stick true and freeze the
                    // wake-word listener (queued sentences still drain and reset isSpeaking).
                    if self.ttsStreaming {
                        // Close whichever engine has the open utterance — leaving a neural one open
                        // would strand isSpeaking true and freeze the wake-word listener.
                        if let neuralTTS = self.streamingNeuralTTS {
                            neuralTTS.endStreaming()
                        } else {
                            self.ttsService.endStreaming()
                        }
                        self.ttsStreaming = false
                    }
                    if !self.ttsService.isSpeaking && !NeuralSpeech.isAnySpeaking {
                        // Turn produced no speech (error/interrupt) — release the narration hold.
                        self.commandTurnActive = false
                    }
                    if self.agentState == .thinking
                        && !self.ttsService.isSpeaking && !NeuralSpeech.isAnySpeaking {
                        // Return to the live video indicator, not plain listening, while in live mode.
                        self.agentState = self.isLiveVideoMode ? .liveVideo
                            : (self.isSessionActive ? .listening : .idle)
                    }
                }
            }
        }

        // Local Gemma extra: token streaming (pipelines Apple TTS behind generation).
        GemmaLocalService.shared.onPartialResponse = { [weak self] (partial: String) in
            guard let self else { return }
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            // Show tokens as they stream so it doesn't look stuck on "thinking".
            self.aiTranscript = partial
            // First streamed token: the boundary between "backend thinking" and "producing".
            MetricsCollector.shared.markFirstToken()
            // Apple TTS: start speaking completed sentences as they arrive (pipeline speech
            // behind generation) instead of waiting for the whole reply. Big perceived speedup,
            // and Apple TTS isn't on the GPU so it doesn't fight the on-device model.
            if self.canStreamSpeech { self.feedStreamingSpeech(partial, isFinal: false) }
        }

        // OpenClaw extras: tool status + device-side tool calls.
        OpenClawService.shared.onToolStatusChanged = { [weak self] (toolName: String?, isRunning: Bool) in
            guard let self else { return }
            print("[VoiceAgent] Tool status: \(toolName ?? "none"), running: \(isRunning)")
            self.currentToolName = toolName
            if isRunning {
                self.agentState = .toolRunning
            }
        }

        // Handle tool calls (e.g., take_photo)
        OpenClawService.shared.onToolCall = { [weak self] (toolName: String, args: [String: Any], completion: @escaping (String) -> Void) in
            guard let self else { return }
            print("[VoiceAgent] Tool call: \(toolName) with args: \(args)")

            switch toolName {
            case "take_photo", "capture_photo", "take_picture":
                // Capture photo from glasses
                Task { @MainActor in
                    await self.handleTakePhotoTool(completion: completion)
                }

            case "describe_scene", "what_do_you_see", "look":
                // Query Gemini Vision for scene description
                Task { @MainActor in
                    await self.handleDescribeSceneTool(args: args, completion: completion)
                }

            default:
                print("[VoiceAgent] Unknown tool: \(toolName)")
                completion("Tool '\(toolName)' is not available on this device.")
            }
        }

        // Gemini Live callbacks (for Gemini Live mode, not hybrid)
        GeminiLiveService.shared.onOutputTranscription = { [weak self] (text: String) in
            self?.aiTranscript = text
        }

        GeminiLiveService.shared.onTurnComplete = { [weak self] in
            guard let self else { return }
            // Cloud live turns can only be COUNTED: the server does VAD, so the client never
            // sees when the user stopped speaking and a perceived-latency figure would be
            // fabricated. Counting keeps live-mode usage visible without inventing numbers.
            MetricsCollector.shared.count("live_turn_gemini")
            self.agentState = self.isSessionActive ? .listening : .idle
            self.voiceCommandService.enterConversationMode()
            // History: persist this Gemini Live exchange (transcript only, no frames).
            self.recordLiveTurn()
        }
    }

    /// Start listening for wake word
    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }

        // Configure audio for glasses before starting to listen
        configureAudioForGlasses()

        do {
            try voiceCommandService.startListening()
            isVoiceReady = true
            print("[VoiceAgent] Started wake word listening - READY")
        } catch {
            print("[VoiceAgent] Failed to start listening: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Command routing

    /// Send command to AI backend
    private func sendCommand(_ command: String) async {
        let lowerCommand = command.lowercased()

        // Check for "stop" command - stops TTS and waits for next command.
        // Matched on WORDS, not substrings: `.contains("stop")` treated "what's on the desktop"
        // as a stop command and killed the session mid-question.
        let commandWords = Set(lowerCommand.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let stopSingleWords: Set<String> = ["stop", "quiet", "silence", "enough"]
        let stopPhrases = ["be quiet", "shut up", "ok stop", "okay stop", "stop talking", "stop it"]
        let isStopCommand = (!commandWords.isDisjoint(with: stopSingleWords)
                             || stopPhrases.contains { lowerCommand.contains($0) })
                             && !lowerCommand.contains("video") && !lowerCommand.contains("stream")

        if isStopCommand {
            // In live video mode, "stop" means SHUT UP, not "tear down my camera session" —
            // silence everything and stay live. "Stop video" (excluded above) exits the mode.
            if isLiveVideoMode {
                NSLog("[OV] live: stop — silencing, staying in live mode")
                MetricsCollector.shared.markInterrupted()
                MetricsCollector.shared.markSpokeDone()
                ttsService.stop()
                NeuralSpeech.stopAll()
                ttsStreaming = false
                commandTurnActive = false
                GemmaLocalService.shared.interrupt()
                agentState = .liveVideo
                return
            }
            print("[VoiceAgent] Stop command detected - full stop")
            performFullStop()
            return
        }

        // Check for live video mode commands
        let startLiveKeywords = ["start video stream", "start live video", "start video", "start streaming",
                                 "enable video", "live mode", "go live", "video mode"]

        let isStartLiveCommand = startLiveKeywords.contains { lowerCommand.contains($0) }
        // Fuzzy stop match: any "video"/"stream" phrase with a stop-like word. Tolerates Apple STT
        // dropping the leading 's' ("stop video" → "top video"), which previously sailed past the
        // exact-keyword list and got sent to the model as a question instead of ending the mode.
        let mentionsVideo = lowerCommand.contains("video") || lowerCommand.contains("stream")
        let stopWords = ["stop", "top ", "end ", "exit", "disable", "close", "quit", "turn off"]
        let isStopLiveCommand = mentionsVideo && stopWords.contains { lowerCommand.contains($0) }

        // Handle live video mode commands
        if isStartLiveCommand {
            print("[VoiceAgent] Starting live video mode...")
            await startLiveVideoMode()
            return
        }

        // Vision-phrased questions OUTSIDE live mode must never reach the local model text-only:
        // FastVLM answered "please upload an image", that refusal entered conversation history,
        // and the model then parroted it on every later vision turn — image attached or not.
        // Photo-capture phrasings ("take a photo and...") are handled elsewhere and unaffected;
        // this catches the bare "what do you see" style, which has no image source outside live
        // mode, and answers with guidance instead of poisoning the session.
        if !isLiveVideoMode, settingsManager.settings.aiBackend == .localGemma {
            let visionPhrases = ["what do you see", "what am i looking at", "what are you looking at",
                                 "what's in front of me", "what is in front of me",
                                 "describe what you see", "describe the view", "describe the scene"]
            if visionPhrases.contains(where: { lowerCommand.contains($0) }),
               !lowerCommand.contains("photo") && !lowerCommand.contains("picture") {
                NSLog("[OV] vision question outside live mode — guiding instead of imageless model call")
                speakResponse("I can't see anything right now. Say 'take a photo' for a quick look, or 'start live video' and I'll watch continuously.")
                return
            }
        }

        if isStopLiveCommand {
            print("[VoiceAgent] Stopping live video mode...")
            await stopLiveVideoMode()
            return
        }

        // If in live video mode, route by which live backend is driving it.
        if isLiveVideoMode {
            if activeLiveService == nil {
                // Local (SmolVLM2) live mode: STT is the input path, so every command lands here.
                // Answer it against the latest glasses frame.
                await handleLocalLiveVideoCommand(command)
            } else if activeLiveService === geminiLive {
                // Cloud modes stream audio directly, so this shouldn't be reached — but Gemini
                // can accept a text turn as a fallback. OpenAI Realtime is audio-only here.
                do {
                    try await geminiLive.sendText(command)
                } catch {
                    print("[VoiceAgent] Failed to send to Gemini Live: \(error)")
                }
            }
            return
        }

        // Drop only EXACT-duplicate commands fired within a few seconds. The speech
        // recognizer can emit the same phrase twice (partial + final), which double-fired
        // photo capture. A *different* follow-up question must still go through, even while
        // the previous answer is generating/speaking.
        let now = Date()
        if command == lastProcessedCommand, now.timeIntervalSince(lastProcessedAt) < 4 {
            print("[VoiceAgent] Ignoring duplicate command within 4s: \(command)")
            return
        }
        lastProcessedCommand = command
        lastProcessedAt = now

        // Face recognition on CLOUD backends: classify via the on-device model (if loaded) up front.
        // On the Local backend we DON'T do this — routing is merged into the single generation below
        // so we never run two Gemma generations per command (memory/jetsam).
        if settingsManager.settings.aiBackend != .localGemma {
            if await handleFaceCommandIfNeeded(command) {
                agentState = isSessionActive ? .listening : .idle
                return
            }
        }

        agentState = .thinking

        // Check if this is a vision-related command
        // Keywords for "take a photo" - capture and send to OpenClaw
        let photoKeywords = ["take a photo", "take a picture", "take photo", "take picture",
                            "capture a photo", "capture photo", "snap a photo", "snap a picture",
                            "what do you see", "what are you looking at", "look at this",
                            "what's in front of me", "describe what you see", "what is this",
                            "what am i looking at", "can you see"]

        let isPhotoCommand = photoKeywords.contains { lowerCommand.contains($0) }

        // Drive whichever backend is selected through the AIBackend protocol — capabilities
        // (localLLM, supportsImageInput) decide the path, not concrete service types.
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        do {
            if let llm = backend.localLLM {
                // On-device routing brain (Gemma / Apple Intelligence): one generation that
                // routes faces, web search, native tools, or answers.
                await handleLocalCommand(command, llm: llm, isPhotoCommand: isPhotoCommand)
            } else if isPhotoCommand && backend.supportsImageInput {
                print("[VoiceAgent] Photo command on \(backend.backendType.displayName) — capturing...")
                await captureAndSendPhoto(withPrompt: command)
            } else {
                try await backend.sendMessage(command, imageData: nil)
            }
            // OpenAI and Grok are plain request/response with no session to keep "thinking" alive —
            // restore the listening state inline. The others restore via their callbacks.
            if backend.backendType == .openAI || backend.backendType == .grok {
                agentState = isSessionActive ? .listening : .idle
            }
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle
        }
    }

    // MARK: - Live Video Mode

    /// Start live video mode - Gemini handles both audio and video
    private func startLiveVideoMode() async {
        guard !isLiveVideoMode else {
            print("[VoiceAgent] Already in live video mode")
            return
        }

        guard glassesManager.isRegistered else {
            ttsService.speak("Please connect your glasses first")
            return
        }

        // Fully on-device live video: with SmolVLM2 loaded as the local backend, keep the glasses
        // camera streaming and answer each spoken question against the latest frame. No cloud,
        // no WebSocket — Apple STT keeps listening and the reply is spoken via the selected TTS.
        if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
            await startLocalLiveVideoMode()
            return
        }

        // Pick the live backend: OpenAI Realtime when OpenAI is the selected + configured backend,
        // otherwise Gemini Live (the default video provider for every other backend).
        guard let (service, label) = resolveLiveService() else {
            ttsService.speak("Please configure your Gemini or OpenAI API key in settings")
            return
        }
        activeLiveService = service

        print("[VoiceAgent] Starting live video mode via \(label)...")

        // Stop VoiceCommandService - the live backend will handle audio directly
        voiceCommandService.stopListening()

        // Stop TTS if speaking
        ttsService.stop()
        NeuralSpeech.stopAll()

        // Match the audio pipeline to the backend's sample rates (Gemini 16k in / 24k out,
        // OpenAI 24k in / 24k out) before starting capture/playback.
        audioCapture.targetSampleRate = Double(service.inputSampleRate)
        audioPlayback.inputSampleRate = Double(service.outputSampleRate)

        // Start glasses streaming
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }

        // Connect to the live backend
        do {
            try await service.connect()
        } catch {
            errorMessage = "Failed to connect to \(label): \(error.localizedDescription)"
            activeLiveService = nil
            // Cleanup: stop streaming and restart voice commands
            if glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
            do {
                try voiceCommandService.startListening()
                voiceCommandService.enterConversationMode()
            } catch {
                print("[VoiceAgent] Failed to restart voice commands: \(error)")
            }
            return
        }

        // Setup live backend callbacks
        setupLiveVideoCallbacks(service)

        // Setup audio capture → live backend
        audioCapture.onAudioCaptured = { [weak service] data in
            service?.sendAudio(data: data)
        }

        // Setup audio playback
        do {
            try audioPlayback.setup()
        } catch {
            print("[VoiceAgent] Failed to setup audio playback: \(error)")
        }

        // Start audio capture
        do {
            try audioCapture.startCapture()
        } catch {
            errorMessage = "Failed to start audio capture: \(error.localizedDescription)"
            await service.disconnect()
            activeLiveService = nil
            voiceCommandService.enterConversationMode()
            return
        }

        // Setup video frame routing to the live backend
        glassesManager.onVideoFrame = { [weak service] image in
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                service?.sendVideoFrame(imageData: jpegData)
            }
        }

        isLiveVideoMode = true
        agentState = .liveVideo

        print("[VoiceAgent] ✓ Live video mode active - \(label) handling audio + video")

        // Announce to user
        ttsService.speak("Live video mode active")
    }

    /// Resolve which live-video backend to use, or nil if none is configured.
    /// - OpenAI selected + API key → OpenAI Realtime
    /// - otherwise Gemini if configured (default video provider), else OpenAI if it has an API key.
    /// A ChatGPT subscription can't drive Realtime, so it falls through to Gemini.
    private func resolveLiveService() -> (service: any LiveVideoService, label: String)? {
        let settings = settingsManager.settings
        if settings.aiBackend == .openAI && settings.isOpenAIAPIAvailable {
            return (openAIRealtime, "OpenAI Realtime")
        }
        if settings.isGeminiConfigured {
            return (geminiLive, "Gemini Live")
        }
        if settings.isOpenAIAPIAvailable {
            return (openAIRealtime, "OpenAI Realtime")
        }
        return nil
    }

    /// Fully on-device live video (SmolVLM2). Unlike the cloud modes, audio stays on the normal
    /// Apple STT path — we just keep the glasses camera streaming and mark the mode active, so
    /// each spoken question is answered against the latest frame (see sendCommand). Replies
    /// speak through the selected TTS engine as usual.
    private func startLocalLiveVideoMode() async {
        print("[VoiceAgent] Starting local live video mode (SmolVLM2)...")

        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            ttsService.speak("I couldn't start the glasses camera")
            return
        }

        // The glasses' Bluetooth HFP mic can't run while their camera streams (it goes deaf —
        // the PR #15 lesson; photo mode survives because its stream is momentary). Live mode
        // streams continuously, so force the phone mic + speaker for the whole session and
        // rebuild recognition on that route. The preferred route is restored on stop.
        voiceCommandService.stopListening()
        try? AudioSessionManager.shared.configureForPhone()
        do {
            try voiceCommandService.startListening()
        } catch {
            print("[VoiceAgent] Failed to restart STT on phone mic: \(error)")
        }

        // Stay in conversation mode so follow-ups don't need the wake word.
        voiceCommandService.enterConversationMode()

        isLiveVideoMode = true
        agentState = .liveVideo

        // Continuous watch loop: describe the CURRENT view as it changes, instead of only
        // answering on the frame that was current when a question finished processing — the old
        // behaviour spoke about whatever it saw last, seconds behind a head turn.
        startWatchLoop()

        print("[VoiceAgent] ✓ Local live video mode active - watch loop + questions on latest frame")
        ttsService.speak("Live video mode active, on device")
    }

    /// Answer a spoken question in local live video mode using a fresh, settled glasses frame.
    private func handleLocalLiveVideoCommand(_ command: String) async {
        // Deterministic narration toggle — a code guard, not model routing, per the repo's
        // standing lesson that small models ignore subtle routing rules.
        let lower = command.lowercased()

        // Bare stop-words are a command to SHUT UP, never a vision question. The stop-phrase
        // branch in VoiceCommandService only runs while a reply is actively playing (.processing);
        // between replies, live mode sits in conversation mode, where "Ok Vision stop" had its
        // wake word stripped and "stop" arrived HERE — and got sent to the model as a question,
        // producing another description. Every stop attempt triggered more speech: "it keeps on
        // describing, it doesn't simply stop". Silence everything, stay in live mode ("stop
        // video" remains the phrase that exits).
        let stopWords: Set<String> = ["stop", "stop it", "stop talking", "be quiet", "quiet",
                                      "shut up", "enough", "cancel", "silence"]
        if stopWords.contains(lower.trimmingCharacters(in: .whitespacesAndNewlines)) {
            NSLog("[OV] live: bare stop — silencing, staying in live mode")
            MetricsCollector.shared.markInterrupted()
            MetricsCollector.shared.markSpokeDone()
            ttsService.stop()
            NeuralSpeech.stopAll()
            ttsStreaming = false
            commandTurnActive = false
            GemmaLocalService.shared.interrupt()
            agentState = .liveVideo
            return
        }
        if lower.contains("narrat") || lower.contains("describe as i") {
            let turningOff = lower.contains("stop") || lower.contains("off") || lower.contains("quiet")
            watchNarrationEnabled = !turningOff
            watchLastSpoken = nil
            watchLastSpokenThumb = nil
            speakResponse(turningOff ? "Okay, I'll watch quietly." : "Okay, I'll describe what I see as you go.")
            return
        }
        // Generic "what do you see"-type questions get an INSTANT answer from the watch loop's
        // fresh context — no new inference, no frame grab. This is the payoff of continuous
        // perception: the answer was computed before the question. Specific questions (colors,
        // text, counting, "is there a…") still run a real vision turn on the current frame.
        // Deterministic phrase check, per the standing small-model-routing lesson.
        let genericLook = ["what do you see", "what's in front", "what is in front",
                           "describe what you see", "what am i looking at", "describe the view",
                           "describe the scene"]
        let lowered = command.lowercased()
        if let latest = watchLatestDescription,
           Date().timeIntervalSince(latest.at) < 15,
           genericLook.contains(where: { lowered.contains($0) }),
           // The gate that matters: the CURRENT frame must still show the scene the cached
           // description was made from. Age alone lied — after a head-turn the cache stays
           // temporally fresh while describing the previous scene, which produced instant,
           // confident answers about a desk while the wearer looked at a wall.
           Date().timeIntervalSince(glassesManager.lastFrameTime) < 0.5,
           let currentFrame = glassesManager.lastFrame,
           !FrameChange.isNewScene(Self.grayThumbnail(currentFrame), latest.thumb) {
            NSLog("[OV] live: instant answer from watch cache (%.1fs old, scene matched)", Date().timeIntervalSince(latest.at))
            speakResponse(latest.text)
            if isLiveVideoMode { agentState = .liveVideo }
            return
        }

        agentState = .thinking
        // Let head motion settle and grab the freshest frame, so we describe the CURRENT view
        // rather than a stale/motion-blurred one the Bluetooth stream delivered a beat ago.
        //
        // Timed for telemetry: this wait sits between commit and first token, so a vision turn's
        // ttft INCLUDES it (up to ~1.3s). Recording frame_grab_s separately stops that time
        // being misread as the model thinking.
        let frameGrabStart = Date()
        let grabbed = await freshestGlassesFrame(settle: 0.3, maxWait: 1.0)
        MetricsCollector.shared.markFrameGrab(seconds: Date().timeIntervalSince(frameGrabStart))
        guard let frame = grabbed,
              let jpeg = frame.jpegData(compressionQuality: 0.6) else {
            // Counted so a flaky glasses stream is visible in the events panel; the spoken
            // apology still counts as a delivered reply (success = delivered, not correct).
            MetricsCollector.shared.count("live_frame_unavailable")
            speakResponse("I couldn't get a clear view just now — hold still a second and ask again.")
            agentState = .liveVideo
            return
        }
        do {
            // Strip "take a photo"-style wording; the frame is already attached.
            var prompt = visionPromptFromCommand(command)
            // Grounding rules, learned the hard way: a 0.5B model weights TEXT hints over
            // PIXELS. A stale "your view a moment ago: desk with two monitors" made it describe
            // the desk while the wearer looked at a wall. So:
            //  - the current-view hint attaches ONLY if the frame we're sending still matches
            //    the scene that hint describes (thumbnail comparison, not age);
            //  - past views attach ONLY to past-referent questions ("what was", "did you see",
            //    "earlier"), where the past is the point — never to present-tense questions.
            let frameThumb = Self.grayThumbnail(frame)
            if let latest = watchLatestDescription,
               Date().timeIntervalSince(latest.at) < 20,
               !FrameChange.isNewScene(frameThumb, latest.thumb) {
                prompt += "\n(Your own read of this same view a moment ago: \(latest.text))"
            }
            let asksAboutPast = ["what was", "did you see", "earlier", "before", "just saw",
                                 "a moment ago"].contains(where: { lowered.contains($0) })
            if asksAboutPast {
                let past = watchRecentDescriptions.suffix(3)
                    .filter { Date().timeIntervalSince($0.at) < 90 }
                if !past.isEmpty {
                    let lines = past.map { "- \($0.text)" }.joined(separator: "\n")
                    prompt += "\n(Scenes you saw in the last minute or so:\n\(lines))"
                }
            }
            // Fresh scene => fresh eyes: withhold history when the view has changed since the
            // last vision exchange, keep it when it's the same scene so follow-ups still work.
            let sameSceneAsLastExchange = lastVisionExchangeThumb.map {
                !FrameChange.isNewScene(frameThumb, $0)
            } ?? false
            if !sameSceneAsLastExchange {
                NSLog("[OV] live: scene changed since last exchange — answering without history")
            }
            lastVisionExchangeThumb = frameThumb
            try await GemmaLocalService.shared.sendMessage(prompt, imageData: jpeg,
                                                           includeHistory: sameSceneAsLastExchange)
        } catch {
            print("[VoiceAgent] Local live video inference failed: \(error)")
            speakResponse("Sorry, that didn't work. \(error.localizedDescription)")
        }
        if isLiveVideoMode { agentState = .liveVideo }
    }

    // MARK: - Continuous watch loop (local live video)

    private var watchTask: Task<Void, Never>?
    /// Grayscale thumbnail of the last frame we RAN INFERENCE on — the scene-change gate.
    private var watchLastThumb: [UInt8]?
    /// The last description actually SPOKEN — the chatter gate.
    private var watchLastSpoken: String?
    /// Thumbnail of the frame sent with the last VISION QUESTION. When the next question's frame
    /// shows a different scene, conversation history is withheld from the model — fresh scene,
    /// fresh eyes — because history containing the same question about a previous scene made the
    /// model copy its old answer instead of reading the new image.
    private var lastVisionExchangeThumb: [UInt8]?
    /// Thumbnail of the scene the last SPOKEN line described. A stronger repeat-gate than text
    /// similarity alone: short sentences share few words, so rephrasings of the same scene
    /// scored as "new" and were re-announced. Same scene = one announcement, full stop.
    private var watchLastSpokenThumb: [UInt8]?
    /// Previous polled thumbnail — the DWELL gate compares against this, not the last described
    /// scene: describe only once the view has stopped moving.
    private var watchPrevPollThumb: [UInt8]?
    /// When the last inference finished — enforces a hard duty-cycle floor.
    private var watchLastDescribeEnd = Date.distantPast
    /// Freshest description of the current view + when it was made. This is the loop's real
    /// product: silent visual context, kept warm so questions can be grounded instantly.
    private(set) var watchLatestDescription: (text: String, at: Date, thumb: [UInt8])?
    /// Rolling memory of recent scene descriptions (newest last, capped). The streaming-video-LLM
    /// literature converges on "treat video as a stream with memory, not independent photos" —
    /// this is the same idea in text space, at ~zero cost: questions get the last minute of what
    /// the assistant saw, so "what was that thing on the shelf?" can work after a head-turn.
    private var watchRecentDescriptions: [(text: String, at: Date)] = []
    private static let watchMemoryLimit = 5
    /// Whether the loop SPEAKS what it sees. OFF by default — this is how Gemini Live and
    /// ChatGPT video behave: continuous perception, but the assistant only talks when asked.
    /// The first cut narrated every scene change and it was noise ("even if I don't ask it's
    /// speaking by itself"). Toggled by voice: "start narrating" / "stop narrating".
    private var watchNarrationEnabled = false
    /// Minimum time between inferences. On-device test: walking made every frame a "new scene",
    /// chaining back-to-back full-GPU inferences — times ramped 3.3s -> 9.6s and the device hit
    /// thermal SERIOUS in ninety seconds. The loop must idle even when the world keeps changing.
    private static let watchMinDescribeInterval: TimeInterval = 4.0
    /// True from command capture until the reply has FINISHED PLAYING. The watch loop's
    /// point-in-time "is anything speaking?" checks straddled 1-3s of async inference+synthesis,
    /// so a reply could begin inside that window and get preempted by the finished watch line —
    /// cutting the user's answer off mid-sentence. This flag covers the whole turn lifecycle.
    private var commandTurnActive = false

    /// Describe the current view continuously, spending inference only on scene changes and
    /// speech only on genuinely new content. Economics per frame (measured): inference ~1-2s of
    /// GPU; speaking costs contention on top (decode drops ~40% while Kokoro synthesises). Both
    /// gates are pure logic in FrameChange, with tests.
    private func startWatchLoop() {
        stopWatchLoop()
        // Only vision-trusted local models; the loop silently does nothing on a text model.
        guard GemmaLocalModel.from(modelId: settingsManager.settings.localGemmaModelId).supportsOnDeviceVision else {
            print("[VoiceAgent] Watch loop not started — loaded model has no on-device vision")
            return
        }
        watchLastThumb = nil
        watchLastSpoken = nil
        watchTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isLiveVideoMode {
                // Yield entirely while a question is being answered or a reply is being spoken —
                // the loop must never steal GPU from a real turn, and describing while speaking
                // would talk over the answer.
                if self.commandTurnActive || self.agentState == .thinking
                    || self.ttsService.isSpeaking || NeuralSpeech.isAnySpeaking {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                // Freshness over completeness: only a frame from the last 500ms, no settle wait.
                guard Date().timeIntervalSince(self.glassesManager.lastFrameTime) < 0.5,
                      let frame = self.glassesManager.lastFrame else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                // Duty-cycle floor FIRST: on-device, a walk made every frame a new scene and
                // the chained inferences thermal-throttled the phone to "serious" (3.3s -> 9.6s
                // per frame). The loop idles between describes no matter what the world does.
                guard Date().timeIntervalSince(self.watchLastDescribeEnd) >= Self.watchMinDescribeInterval else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let thumb = Self.grayThumbnail(frame)
                let prevPoll = self.watchPrevPollThumb
                self.watchPrevPollThumb = thumb
                // DWELL gate: describe only once the view has SETTLED — this poll must match the
                // previous poll. Mid-pan frames are motion-blurred (the model literally said
                // "a blurry image"), waste full-GPU inferences on views the wearer is already
                // leaving, and narrate the journey instead of the destination.
                if let prevPoll, FrameChange.isNewScene(thumb, prevPoll) {
                    MetricsCollector.shared.count("watch_skipped")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                // Scene gate: the settled view must differ from the last DESCRIBED scene.
                if let last = self.watchLastThumb {
                    let diff = FrameChange.difference(thumb, last)
                    if diff <= FrameChange.sceneChangeThreshold {
                        MetricsCollector.shared.count("watch_skipped")
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }
                    NSLog("[OV] watch: NEW SETTLED SCENE diff=%.3f", diff)
                }
                guard let jpeg = frame.jpegData(compressionQuality: 0.6) else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                self.watchLastThumb = thumb
                let inferStart = Date()
                do {
                    let raw = try await GemmaLocalService.shared.describeFrame(
                        jpeg, prompt: "What is in view right now?")
                    self.watchLastDescribeEnd = Date()
                    // The token cap truncates mid-sentence ("...and a mouse" / "The plant is") —
                    // trim to the last COMPLETE sentence; a fragment-only output is dropped.
                    let description: String
                    if let boundary = TextChunking.lastSentenceBoundary(in: raw) {
                        description = String(raw[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        description = ""
                    }
                    let inferSeconds = Date().timeIntervalSince(inferStart)
                    MetricsCollector.shared.count("watch_described")
                    NSLog("[OV] watch: %.2fs \"%@\"", inferSeconds, description.isEmpty ? raw + " [fragment, dropped]" : description)
                    // Speak gates, all must pass:
                    //  1. the SCENE moved on since the last spoken line — text similarity alone
                    //     re-announced rephrasings ("this is a plant" / "a potted plant" share
                    //     too few words), so same scene = one announcement, full stop;
                    //  2. the description says something new;
                    //  3. no command turn began while we were inferring (the async window the
                    //     old point-checks missed — this is what cut replies mid-sentence).
                    // speakWatchLine itself is ambient: appends into silence, never preempts.
                    if !description.isEmpty {
                        self.watchLatestDescription = (description, Date(), thumb)
                        self.watchRecentDescriptions.append((description, Date()))
                        if self.watchRecentDescriptions.count > Self.watchMemoryLimit {
                            self.watchRecentDescriptions.removeFirst()
                        }
                        self.aiTranscript = description   // silent context still shows on screen
                    }
                    let sceneMovedOn = self.watchLastSpokenThumb.map {
                        FrameChange.isNewScene(thumb, $0)
                    } ?? true
                    if self.watchNarrationEnabled,
                       !description.isEmpty, sceneMovedOn,
                       FrameChange.isWorthSpeaking(description, lastSpoken: self.watchLastSpoken),
                       !self.commandTurnActive,
                       !self.ttsService.isSpeaking, !NeuralSpeech.isAnySpeaking,
                       self.agentState != .thinking, self.isLiveVideoMode {
                        self.watchLastSpoken = description
                        self.watchLastSpokenThumb = thumb
                        MetricsCollector.shared.count("watch_spoke")
                        self.speakWatchLine(description)
                    }
                } catch {
                    // Model switching/backgrounded mid-loop is normal; back off rather than spin.
                    self.watchLastDescribeEnd = Date()
                    NSLog("[OV] watch: describe failed: %@", "\(error)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func stopWatchLoop() {
        watchTask?.cancel()
        watchTask = nil
        watchLastThumb = nil
        watchLastSpoken = nil
        watchLastSpokenThumb = nil
        watchPrevPollThumb = nil
        watchLastDescribeEnd = .distantPast
        watchLatestDescription = nil
        watchRecentDescriptions.removeAll()
        watchNarrationEnabled = false
        lastVisionExchangeThumb = nil
    }

    /// Speak a watch-loop line OUTSIDE the turn pipeline: no history, no turn metrics — and via
    /// the AMBIENT engine paths, which append into silence and never preempt. The reply paths
    /// (speak/beginStreaming) restart the player; a watch line using them cut user replies off
    /// mid-sentence whenever one landed during the line's synthesis window.
    private func speakWatchLine(_ text: String) {
        if let neuralTTS {
            Task { await neuralTTS.speakAmbient(text) }
        } else {
            ttsService.speakAmbient(text)
        }
    }

    /// Downscale to a 16×16 grayscale thumbnail for the scene-change gate. Cheap enough to run
    /// on every polled frame; the comparison math lives (tested) in FrameChange.
    private static func grayThumbnail(_ image: UIImage) -> [UInt8] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let cg = image.cgImage else { return pixels }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    /// Wait a brief `settle` for head motion to stop, then return the freshest camera frame that's
    /// genuinely recent (stream not stalled). Falls back to whatever frame we have after `maxWait`.
    /// This is the "current view, not a stale glimpse" grab for live video.
    private func freshestGlassesFrame(settle: TimeInterval, maxWait: TimeInterval) async -> UIImage? {
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            // Accept only a frame received within the last 500ms — under heavy motion the BT stream
            // throttles and lastFrame goes stale; wait for a fresh one instead of describing it.
            if Date().timeIntervalSince(glassesManager.lastFrameTime) < 0.5,
               let f = glassesManager.lastFrame {
                return f
            }
            try? await Task.sleep(nanoseconds: 80_000_000)   // 80ms poll
        }
        return glassesManager.lastFrame   // fallback: better an old frame than nothing
    }

    /// Stop live video mode
    private func stopLiveVideoMode() async {
        guard isLiveVideoMode else {
            print("[VoiceAgent] Not in live video mode")
            return
        }
        stopWatchLoop()

        print("[VoiceAgent] Stopping live video mode...")

        // Stop audio capture
        audioCapture.stopCapture()
        audioCapture.onAudioCaptured = nil

        // Stop audio playback
        audioPlayback.teardown()

        // Disconnect the active live backend (Gemini or OpenAI Realtime)
        await activeLiveService?.disconnect()
        activeLiveService = nil

        // Stop glasses streaming
        if glassesManager.isStreaming {
            await glassesManager.stopStreaming()
        }

        // Restore video frame callback to Gemini Vision
        glassesManager.onVideoFrame = { [weak self] image in
            self?.geminiVision.sendVideoFrame(image)
        }

        isLiveVideoMode = false
        agentState = isSessionActive ? .listening : .idle

        // Local live mode forced the phone mic (HFP dies during camera streaming) and its STT
        // may still be running — stop it so the restart below picks up the preferred route.
        if voiceCommandService.isListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()

        // Always restart VoiceCommandService for wake word detection
        do {
            try voiceCommandService.startListening()
            if isSessionActive {
                // Continue conversation mode if session was active
                voiceCommandService.enterConversationMode()
                print("[VoiceAgent] Restarted voice commands in conversation mode")
            } else {
                // Just listen for wake word
                print("[VoiceAgent] Restarted voice commands for wake word detection")
            }
        } catch {
            print("[VoiceAgent] Failed to restart voice commands: \(error)")
        }

        print("[VoiceAgent] Live video mode stopped")
        ttsService.speak("Live video mode ended")
    }

    /// Setup live backend callbacks for audio/transcription (Gemini Live or OpenAI Realtime)
    private func setupLiveVideoCallbacks(_ service: any LiveVideoService) {
        // Audio from the model → playback
        service.onAudioReceived = { [weak self] data in
            self?.audioPlayback.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        service.onInputTranscription = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.userTranscript = text

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                let stopKeywords = ["stop video", "stop streaming", "stop live", "end video",
                                   "exit video", "disable video", "stop the video", "end live",
                                   // Hindi fallbacks (models sometimes transcribe English as Hindi)
                                   "स्टॉप", "वीडियो बंद", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    print("[VoiceAgent] Stop command detected in transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        service.onOutputTranscription = { [weak self] text in
            Task { @MainActor in
                self?.aiTranscript = text
            }
        }

        // Turn complete
        let liveTurnEvent = service === geminiLive ? "live_turn_gemini" : "live_turn_openai"
        service.onTurnComplete = { [weak self] in
            Task { @MainActor in
                // Cloud live turns are COUNTED, not timed: the server does the VAD, so the
                // client never sees when the user stopped speaking — any perceived-latency
                // number here would be fabricated. The count keeps live usage visible.
                MetricsCollector.shared.count(liveTurnEvent)
                // History: persist this live-video exchange (transcript only, no frames).
                self?.recordLiveTurn()
            }
        }

        // Disconnection - handle reconnection or mode exit
        service.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isLiveVideoMode {
                    print("[VoiceAgent] Live backend disconnected unexpectedly")
                    await self.stopLiveVideoMode()
                }
            }
        }
    }

    /// Turn a spoken photo command into a clean vision question for a model that already has
    /// the image attached. Removes "take a picture / photo" trigger wording so the model
    /// describes the image instead of protesting that it can't take photos.
    private func visionPromptFromCommand(_ command: String) -> String {
        var s = command.lowercased()
        // Only strip explicit photo-capture wording — that's what makes a VLM refuse ("I can't
        // take photos"). Do NOT strip politeness/filler ("would you", "right now", "of this"):
        // removing those mid-sentence mangled real questions ("what am I looking at right now"
        // → "what am I looking at"; "would you tell me which plant" → "tell me which plant").
        let triggers = [
            "take a picture of this", "take a photo of this", "take a picture", "take a photo",
            "take photo", "take picture", "capture a photo", "capture photo", "snap a photo",
            "snap a picture", "go ahead and take"
        ]
        for t in triggers { s = s.replacingOccurrences(of: t, with: " ") }
        s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leftover connective prefixes left after removing the trigger ("...and tell me…").
        for prefix in ["and ", "of this ", "of ", "please "] {
            while s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        if s.count < 3 {
            return "What is the main object in this image? Name it specifically and describe its key visible details in 2–3 sentences."
        }
        return "Look closely at the image and answer specifically and concretely: \(s)"
    }

    // MARK: - POV Recording

    /// Toggle a demo recording of the glasses point-of-view (video) plus the phone mic (audio,
    /// which captures the scene sound and the assistant's spoken reply played out the speaker).
    /// The result is saved to Photos for sharing.
    func toggleRecording() {
        if isRecording {
            sessionRecorder.stop()   // finishes async; `onFinished` resets state + reports the save
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard glassesManager.isRegistered else {
            errorMessage = "Connect your glasses first to record."
            return
        }
        // Recording needs a live frame stream; start it if the user isn't already in live video.
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            errorMessage = "Couldn't start the glasses camera to record."
            return
        }

        // Route the raw glasses frames into the recorder. This is separate from `onVideoFrame`
        // (which feeds the AI in live mode), so recording and live vision can run together.
        glassesManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.sessionRecorder.appendVideoSampleBuffer(sampleBuffer)
        }

        sessionRecorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.isRecording = false
            self.glassesManager.onVideoSampleBuffer = nil
            self.showRecordingStatus(url != nil ? "Saved to Photos" : "Couldn't save recording")
        }

        do {
            try sessionRecorder.start()
            isRecording = true
        } catch {
            glassesManager.onVideoSampleBuffer = nil
            errorMessage = "Recording failed to start: \(error.localizedDescription)"
        }
    }

    /// Show a brief status message after a recording finishes, then clear it.
    private func showRecordingStatus(_ text: String) {
        recordingStatus = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.recordingStatus == text { self?.recordingStatus = nil }
        }
    }

    // MARK: - Face recognition

    /// Route face-recognition commands using the on-device model as an intent classifier
    /// (agentic — no keyword matching, like OpenGlasses' face_recognition tool). Returns true
    /// if the command was a face command and was handled.
    private func handleFaceCommandIfNeeded(_ command: String) async -> Bool {
        guard let intent = await GemmaLocalService.shared.classifyFaceIntent(command) else {
            return false   // model not loaded, or not a face command
        }
        await handleFaceIntent(intent)
        return true
    }

    /// Shared handling for the on-device text models (Gemma / Apple Foundation): one agentic
    /// generation that routes a face action, a web search, or a direct spoken answer.
    private func handleLocalCommand(_ command: String, llm: LocalTextLLM, isPhotoCommand: Bool) async {
        if isPhotoCommand {
            // SmolVLM2 handles photos fully on-device; other local models are text-only
            // (Gemma E2B's vision hit the jetsam limit — see GemmaLocalModel.supportsOnDeviceVision).
            if settingsManager.settings.aiBackend == .localGemma && GemmaLocalService.shared.visionReady {
                print("[VoiceAgent] Photo command on local SmolVLM2 — capturing...")
                await captureAndSendPhoto(withPrompt: command)
                return
            }
            agentState = isSessionActive ? .listening : .idle
            speakResponse("This on-device model is text only. For camera questions, select SmolVLM2 as your local model, or switch to Gemini or OpenClaw in Settings.")
            return
        }
        // Route the command. With Apple TTS, stream the answer: speak sentences as they generate.
        // Backends that can't stream (Apple FM) fall back to a plain route via the protocol's
        // default implementation — onPartial simply never fires. Face/tool routes emit JSON
        // starting with "{", so we only begin speaking once the streamed output's first non-space
        // char proves it's a plain answer — never for a structured route.
        let result: LocalAgent.RouteResult
        if canStreamSpeech {
            ttsStreaming = false
            ttsStreamSpokenChars = 0
            result = await llm.routeCommandStreaming(command) { [weak self] cumulative in
                guard let self else { return }
                // Telemetry: the model has started producing. Marked before the JSON-route guard
                // below so a structured route still records its think time.
                MetricsCollector.shared.markFirstToken()
                let lead = cumulative.trimmingCharacters(in: .whitespacesAndNewlines).first
                guard let lead, lead != "{" else { return }   // JSON route → don't speak
                self.feedStreamingSpeech(cumulative, isFinal: false)
            }
        } else {
            // Non-streaming: no visibility into decode, so first-token is backfilled by
            // markGenerationDone and `ttft` legitimately covers the whole generation.
            result = await llm.routeCommand(command)
        }
        // The local route is not delivered through AIBackend.onAgentMessage (it returns a
        // RouteResult instead), so generation-done has to be marked here or the whole stage
        // breakdown after commit goes missing.
        MetricsCollector.shared.markGenerationDone()

        switch result {
        case .face(let intent):
            // Safety: if we mis-started streaming (answer contained a stray "{"), cancel it.
            if ttsStreaming { ttsService.stop(); ttsStreaming = false }
            await handleFaceIntent(intent)
        case .webSearch(let query):
            if ttsStreaming { ttsService.stop(); ttsStreaming = false }
            NSLog("[OV] web search: \"%@\"", query)
            var result = await WebSearchService.search(query)
            // Agentic retry: if the first query found nothing, let the model reformulate once.
            if result.isEmpty, let better = await llm.reformulateSearchQuery(question: command, triedQuery: query) {
                NSLog("[OV] web search retry: \"%@\"", better)
                result = await WebSearchService.search(better)
            }
            let answer = await llm.answerWithSearchResult(question: command, result: result)
            speakResponse(answer)   // separate generation — not streamed here
            ConversationContext.shared.record(user: command, assistant: answer)
        case .answer(let text):
            if ttsStreaming {
                feedStreamingSpeech(text, isFinal: true)   // flush the tail, close the session
            } else {
                speakResponse(text)   // Kokoro, or non-streaming backend
            }
            ConversationContext.shared.record(user: command, assistant: text)
        }
        // Generation finishes well before the voice does (several sentences stay queued in TTS).
        // Don't stomp the state back to .listening while the reply is still being spoken — the
        // TTS-finished observers handle that transition at the right moment.
        if !ttsService.isSpeaking && !NeuralSpeech.isAnySpeaking {
            agentState = isSessionActive ? .listening : .idle
        }
    }

    /// Carry out a face action (camera capture + Apple Vision), shared by the cloud-backend
    /// classifier path and the Local-backend single-pass router.
    private func handleFaceIntent(_ intent: GemmaLocalService.FaceIntent) async {
        let face = FaceRecognitionService.shared
        switch intent.action {
        case "identify":
            agentState = .thinking
            guard let image = await currentGlassesImage() else {
                speakResponse("I couldn't get a picture from the glasses. Make sure they're connected.")
                return
            }
            speakResponse(await face.identify(in: image))
        case "remember":
            agentState = .thinking
            guard !intent.name.isEmpty else {
                speakResponse("Sure — what's their name?")
                return
            }
            guard let image = await currentGlassesImage() else {
                speakResponse("I couldn't get a picture from the glasses. Make sure they're connected.")
                return
            }
            speakResponse(await face.rememberFace(name: intent.name, from: image))
        case "forget":
            speakResponse(face.forgetFace(name: intent.name))
        case "list":
            speakResponse(face.listKnownFaces())
        default:
            break
        }
    }

    // MARK: - Photo capture

    /// Get a fresh UIImage frame from the glasses camera, then turn the camera off
    /// ("click and go") — unless we're in live video mode.
    private func currentGlassesImage() async -> UIImage? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming { await glassesManager.startStreaming() }
        var frame: UIImage?
        for _ in 0..<40 {   // up to ~4s for a fresh frame
            if let f = glassesManager.lastFrame { frame = f; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if frame == nil { frame = glassesManager.lastFrame }
        if glassesManager.isStreaming && !isLiveVideoMode {
            await glassesManager.stopStreaming()
        }
        // Do NOT touch the audio stack here. Tearing down / rebuilding the recognizer around the
        // camera is what broke the HFP mic: every rebuild forces a fresh Bluetooth SCO negotiation,
        // which the glasses can't service right after streaming (mic stays deaf for tens of seconds,
        // with an audible reconnect chirp per attempt). OpenGlasses keeps its wake-word engine + mic
        // tap alive straight through photo capture — audio just gaps during the stream and resumes
        // into the same running engine. We now do the same; see restartRecognition()'s engine check.
        return frame
    }

    /// Send a prompt (optionally with a photo) to whichever backend is currently selected.
    private func sendPromptToActiveBackend(_ prompt: String, imageData: Data?) async throws {
        let backend = AIBackendRegistry.backend(for: settingsManager.settings.aiBackend)
        // Backends that can't take an image (Apple FM text-only, Gemini streams video live)
        // receive just the prompt.
        try await backend.sendMessage(prompt, imageData: backend.supportsImageInput ? imageData : nil)
    }

    private func captureAndSendPhoto(withPrompt prompt: String) async {
        // Try to get an image from various sources
        var imageData: Data?
        var startedStreamingForPhoto = false

        // Start streaming if glasses are registered but not streaming. `startStreaming()` only
        // returns after `session.start()` completes (isStreaming is already true here), so the
        // old "poll up to 3s for isStreaming" loop + fixed 500ms sleep were dead weight that just
        // kept the LED on longer. freshLiveFrame() below already waits for the first real frame,
        // so drop the artificial delay entirely.
        if glassesManager.isRegistered && !glassesManager.isStreaming {
            print("[VoiceAgent] Starting glasses camera stream for photo...")
            await glassesManager.startStreaming()
            startedStreamingForPhoto = true
        }

        // Capture straight from the live video stream. The glasses' one-shot photo API
        // (session.capturePhoto) doesn't reliably deliver on this model/SDK — it times out
        // after 5s — whereas a live frame is available immediately. freshLiveFrame() ensures
        // the stream is running, waits for a fresh frame, and restarts a stalled stream.
        imageData = await freshLiveFrame()

        NSLog("[OV] captureAndSendPhoto result: %@ (streaming=%@, registered=%@)",
              imageData == nil ? "NO IMAGE" : "\(imageData!.count) bytes",
              glassesManager.isStreaming ? "yes" : "no",
              glassesManager.isRegistered ? "yes" : "no")

        // "Click and go": now that we have the photo, turn the glasses camera off immediately —
        // before the (multi-second) model inference — so the LED doesn't stay on. Repeat photo
        // commands restart the camera reliably via freshLiveFrame(). Skip in live video mode.
        if imageData != nil && glassesManager.isStreaming && !isLiveVideoMode {
            NSLog("[OV] photo captured — stopping camera (click and go)")
            await glassesManager.stopStreaming()
        }

        // Send with or without image
        do {
            if let imageData = imageData {
                // The image is attached, so strip the "take a picture" wording — otherwise the
                // VLM replies "I can't take photos / please provide an image" before describing.
                let visionPrompt = visionPromptFromCommand(prompt)
                NSLog("[OV] Sending message with photo (%d bytes), prompt: \"%@\"", imageData.count, visionPrompt)
                try await sendPromptToActiveBackend(visionPrompt, imageData: imageData)
            } else {
                NSLog("[OV] No image available — capture returned nil; NOT sending to model")
                // Don't send a degraded text-only prompt to the model — that's what makes it
                // reply "please provide an image". Tell the user directly and stop.
                errorMessage = "Couldn't capture a photo (streaming: \(glassesManager.isStreaming ? "on" : "off"), registered: \(glassesManager.isRegistered ? "yes" : "no")). Try again."
                speakResponse("I couldn't get a photo from the glasses. Please try again.")
            }
        } catch {
            print("[VoiceAgent] Failed to send: \(error)")
            errorMessage = "Failed to send: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle

            // Stop streaming on error if we started it for this photo
            if startedStreamingForPhoto && glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
        }
    }

    /// Capture photo from glasses and return the data
    private func capturePhotoFromGlasses() async -> Data? {
        // Clear any stale photo before requesting a fresh capture.
        glassesManager.lastPhotoData = nil
        NSLog("[OV] capturePhotoFromGlasses: requesting capture (streaming=%@)", glassesManager.isStreaming ? "yes" : "no")
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 5 seconds)
        for _ in 0..<50 {
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                NSLog("[OV] Photo captured: %d bytes", photoData.count)
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        NSLog("[OV] Photo capture TIMED OUT after 5s")
        return nil
    }

    /// Force a fresh live video frame, restarting the stream if it has stalled.
    /// More reliable than the one-shot photo capture for repeated requests in a session.
    private func freshLiveFrame() async -> Data? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        // Wait for a NEW frame (clear first so we don't reuse a stale one).
        glassesManager.lastFrame = nil
        for _ in 0..<25 { // up to ~2.5s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Stream appears stalled — restart it once and retry.
        NSLog("[OV] live frame stalled — restarting stream")
        await glassesManager.stopStreaming()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await glassesManager.startStreaming()
        glassesManager.lastFrame = nil
        for _ in 0..<30 { // up to ~3s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired after restart")
                return f.jpegData(compressionQuality: 0.8)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[OV] freshLiveFrame: STILL no frame after restart")
        return nil
    }

    // MARK: - Glasses Video Integration

    /// Setup glasses callbacks to stream video to Gemini Vision
    private func setupGlassesCallbacks() {
        print("[VoiceAgent] Setting up glasses video callbacks...")

        // Connect video frames from glasses to Gemini Vision (for live feed)
        // Note: GeminiVisionService.sendVideoFrame already throttles to 1fps
        glassesManager.onVideoFrame = { [weak self] image in
            guard let self else { return }
            // Send frame to Gemini Vision for live analysis
            self.geminiVision.sendVideoFrame(image)

            // Log periodically (every 30 frames = ~1 second at 30fps)
            Task { @MainActor in
                self.videoFrameCount += 1
                if self.videoFrameCount % 30 == 0 {
                    print("[VoiceAgent] Video frames processed: \(self.videoFrameCount)")
                }
            }
        }

        // Photo captured callback (for OpenClaw photo analysis)
        glassesManager.onPhotoCaptured = { data in
            print("[VoiceAgent] Photo captured: \(data.count) bytes")
            // Photos are handled via OpenClaw's attachment system
        }

        print("[VoiceAgent] Glasses callbacks configured")
    }

    // MARK: - TTS Integration

    /// The selected neural voice (Kokoro, Grok, OpenAI) when it can speak, else nil → Apple system voice.
    private var neuralTTS: NeuralSpeechEngine? { NeuralSpeech.active(settingsManager.settings) }

    /// True when the active speech engine is Apple's system voice (not a neural engine).
    ///
    /// This used to also gate whether the reply was STREAMED, because Kokoro runs on the Metal GPU
    /// alongside the on-device model and interleaving them risked contention. But waiting for the
    /// whole reply before speaking measured at ~1.2s of extra perceived latency per turn — Kokoro
    /// turns showed `tts_lead_in` of +0.01s (perfectly serialised) against Apple TTS's -1.4s
    /// (speech overlapping generation). Both engines now stream; if contention is real it shows up
    /// as `tokens_per_second` dropping, which is instrumented.
    private var usingAppleTTS: Bool {
        neuralTTS == nil
    }

    /// True when a streamed reply should be spoken sentence-by-sentence — now every engine.
    private var canStreamSpeech: Bool {
        usingAppleTTS || neuralTTS != nil
    }

    /// Feed the streamed reply to Apple TTS sentence-by-sentence. `cumulative` is the full text so
    /// far (the local model emits a growing snapshot each token). On non-final calls we speak only
    /// the sentences that have fully completed; on the final call we flush whatever remains.
    private func feedStreamingSpeech(_ cumulative: String, isFinal: Bool) {
        // Open a streamed utterance session on first content.
        if !ttsStreaming {
            guard !cumulative.isEmpty else { return }
            ttsStreaming = true
            ttsStreamSpokenChars = 0
            // Streamed replies never reach speakResponse, so this is where perceived latency ends
            // on the Apple-TTS path — and it lands EARLIER than on the Kokoro path, which is
            // exactly the difference `tts_lead_in_s` is meant to expose.
            // No metric marks here: opening the stream session hands NOTHING to an engine —
            // the first sentence may only complete a boundary seconds later. markTTSRequested
            // fires in speakStreamedChunk at the actual hand-off; markFirstAudio fires inside
            // the engines when sound actually starts.
            streamingNeuralTTS = neuralTTS
            if let neuralTTS = streamingNeuralTTS {
                neuralTTS.beginStreaming()
            } else {
                ttsService.beginStreaming()
            }
        }

        // The portion not yet handed to the speech queue.
        let spokenClamped = min(ttsStreamSpokenChars, cumulative.count)
        let start = cumulative.index(cumulative.startIndex, offsetBy: spokenClamped)
        let pending = cumulative[start...]

        if isFinal {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { speakStreamedChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            if let neuralTTS = streamingNeuralTTS {
                neuralTTS.endStreaming()
            } else {
                ttsService.endStreaming()
            }
            ttsStreaming = false
            recordAssistantReply(cumulative)   // history: streamed reply is complete
            return
        }

        // Speak everything up to the last completed sentence boundary in the pending text.
        guard let boundary = TextChunking.lastSentenceBoundary(in: String(pending)) else { return }
        let pendingStr = String(pending)
        let sentence = String(pendingStr[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 2 else { return }   // don't voice a stray "." or "?"
        speakStreamedChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
    }

    /// Speak one completed sentence on whichever engine is active.
    ///
    /// Both calls are synchronous enqueues now. The previous version wrapped Kokoro in a fresh
    /// `Task` per sentence — independent tasks are UNORDERED, so sentence 2 could synthesise and
    /// play before sentence 1 (the comment claiming order was preserved was wrong). Kokoro now
    /// owns a FIFO drained by a single task, making ordering structural.
    private func speakStreamedChunk(_ sentence: String) {
        // First-wins: the first sentence handed over starts the TTS TTFB clock.
        MetricsCollector.shared.markTTSRequested()
        if let neuralTTS = streamingNeuralTTS {
            neuralTTS.speakChunk(sentence)
        } else {
            ttsService.speakChunk(sentence)
        }
    }

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        recordAssistantReply(text)
        // Perceived latency ends here: the gap between this and speechEnd is the wearer's wait.
        // (An approximation — synthesis still has to start — but it is the moment we hand off,
        // and the difference between Kokoro and Apple TTS shows up in `ttsLeadIn`.)
        // Text is handed to an engine on the next line — TTFB clock starts now. The firstAudio
        // mark comes from the engine itself when sound actually starts; marking it here excluded
        // synthesis time, making TTS TTFB structurally zero and perceived latency optimistic.
        MetricsCollector.shared.markTTSRequested()
        // A neural voice (Kokoro on-device; Grok, OpenAI cloud) when selected + ready; otherwise Apple's.
        if let neuralTTS {
            Task { await neuralTTS.speak(text) }
        } else {
            ttsService.speak(text)
        }
    }

    // MARK: - History

    /// History: persist the assistant's reply, but only when it answers a recorded user command —
    /// system utterances ("Live video mode active", connection errors) stay out of History.
    private func recordAssistantReply(_ text: String) {
        guard historyAwaitingReply else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        ConversationManager.shared.addAssistantMessage(clean)
        historyAwaitingReply = false
    }

    /// History (live video / realtime modes): commands don't pass through onCommandCaptured there,
    /// so record the user+assistant pair at each turn boundary. Transcript only — video frames are
    /// never stored (same policy as Meta's live AI history).
    private func recordLiveTurn() {
        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = aiTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply != historyLastLiveReply else { return }
        if !user.isEmpty { ConversationManager.shared.addUserMessage(user) }
        ConversationManager.shared.addAssistantMessage(reply)
        historyLastLiveReply = reply
        historyAwaitingReply = false
    }

    // MARK: - Tool Handlers (OpenClaw device-side tools)

    /// Handle take_photo tool call
    private func handleTakePhotoTool(completion: @escaping (String) -> Void) async {
        print("[VoiceAgent] Handling take_photo tool")

        if glassesManager.isStreaming {
            // Capture from glasses
            await glassesManager.capturePhoto()

            // Wait for photo to be captured (via callback)
            // Set up one-time handler for the photo
            let originalHandler = glassesManager.onPhotoCaptured
            glassesManager.onPhotoCaptured = { [weak self] data in
                // Restore original handler
                self?.glassesManager.onPhotoCaptured = originalHandler

                // Send photo to OpenClaw as attachment in next message
                Task {
                    do {
                        try await OpenClawService.shared.sendMessage("Here's the photo I just captured.", imageData: data)
                        completion("Photo captured and sent for analysis.")
                    } catch {
                        completion("Photo captured but failed to send: \(error.localizedDescription)")
                    }
                }
            }

            // Timeout after 5 seconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.glassesManager.onPhotoCaptured != nil {
                    self.glassesManager.onPhotoCaptured = originalHandler
                    completion("Photo capture timed out.")
                }
            }
        } else if let lastFrame = glassesManager.lastFrame,
                  let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            // Use last frame if available
            do {
                try await OpenClawService.shared.sendMessage("Here's what I can see.", imageData: jpegData)
                completion("Captured current view and sent for analysis.")
            } catch {
                completion("Failed to send image: \(error.localizedDescription)")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first.")
        }
    }

    /// Handle describe_scene tool call (uses Gemini Vision)
    private func handleDescribeSceneTool(args: [String: Any], completion: @escaping (String) -> Void) async {
        print("[VoiceAgent] Handling describe_scene tool")

        let prompt = args["prompt"] as? String ?? "Please describe what you see in this image."

        // Capture photo and send to OpenClaw for analysis
        if let lastFrame = glassesManager.lastFrame,
           let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            do {
                try await OpenClawService.shared.sendMessage(prompt, imageData: jpegData)
                completion("Image captured and sent for analysis.")
            } catch {
                completion("Failed to analyze scene: \(error.localizedDescription)")
            }
        } else if glassesManager.isStreaming {
            // Try to capture a photo
            await glassesManager.capturePhoto()
            // Wait briefly for photo
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                do {
                    try await OpenClawService.shared.sendMessage(prompt, imageData: photoData)
                    completion("Photo captured and sent for analysis.")
                } catch {
                    completion("Failed to send photo: \(error.localizedDescription)")
                }
            } else {
                completion("Failed to capture photo.")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first, or say 'start video stream' for live mode.")
        }
    }
}

// MARK: - Text chunking (pure, unit-testable)

/// Pure text helpers for sentence-streamed TTS.
enum TextChunking {
    /// Index just past the last sentence terminator (. ! ? or newline) in `s`, or nil if none.
    /// A `.`/`!`/`?` only counts when followed by whitespace or end-of-text, so decimals like
    /// "2.5" and abbreviations don't get split mid-number.
    static func lastSentenceBoundary(in s: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var boundary: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" {
                boundary = next
            } else if terminators.contains(c) {
                let followedByBreak = next == s.endIndex || s[next] == " " || s[next] == "\n"
                if followedByBreak { boundary = next }
            }
            i = next
        }
        return boundary
    }

    /// Split `s` into speakable sentence chunks using the same boundary rules as
    /// `lastSentenceBoundary` (terminator followed by a break, or newline). Chunks are trimmed;
    /// empties dropped; text after the last terminator is included as a final chunk.
    /// Used by Kokoro TTS to synthesize per-sentence — one long reply in a single MLX pass
    /// spikes memory proportional to its length (jetsam risk next to SmolVLM2).
    static func sentences(_ s: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?"]
        var result: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            current.append(c)
            let next = s.index(after: i)
            let isBoundary = c == "\n"
                || (terminators.contains(c) && (next == s.endIndex || s[next] == " " || s[next] == "\n"))
            if isBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            i = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
