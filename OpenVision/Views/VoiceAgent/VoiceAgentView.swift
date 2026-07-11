// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design

import SwiftUI
import Speech

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - Services

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var geminiVision = GeminiVisionService.shared
    @StateObject private var geminiLive = GeminiLiveService.shared
    @StateObject private var openAIRealtime = OpenAIRealtimeService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var kokoroTTS = KokoroTTSService.shared
    @StateObject private var soundService = SoundService.shared
    @StateObject private var audioCapture = AudioCaptureService()
    @StateObject private var audioPlayback = AudioPlaybackService()

    // MARK: - State

    @State private var isSessionActive = false
    @State private var agentState: AgentState = .idle
    @State private var userTranscript = ""
    @State private var aiTranscript = ""
    @State private var currentToolName: String?
    @State private var errorMessage: String?
    // De-dup: the last command we processed and when (drops duplicate recognizer emissions).
    @State private var lastProcessedCommand = ""
    @State private var lastProcessedAt = Date.distantPast
    @State private var audioLevel: CGFloat = 0
    @State private var hasRequestedSpeechAuth = false

    /// Live Video Mode - uses Gemini Live or OpenAI Realtime for real-time audio + video
    @State private var isLiveVideoMode = false

    /// The live-video backend currently driving audio/video (Gemini or OpenAI Realtime).
    /// Set when live video mode starts; used by stop/callbacks so both backends route correctly.
    @State private var activeLiveService: (any LiveVideoService)?

    /// True when voice recognition is ready (audio engine running)
    @State private var isVoiceReady = false

    /// Sentence-streaming TTS (Apple only): how many characters of the streamed reply have
    /// already been handed to the speech queue, and whether a streamed utterance is open.
    @State private var ttsStreamSpokenChars = 0
    @State private var ttsStreaming = false


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

    // MARK: - Body

    var body: some View {
        ZStack {
            // Beautiful animated background
            AnimatedBackground()

            // Particle effects
            ParticleEffect(particleCount: 30)
                .opacity(0.5)

            // Main content
            VStack(spacing: 0) {
                // Top bar
                topBar
                    .padding(.top, 8)

                Spacer()

                // Center: Visualizer and status
                centerContent

                Spacer()

                // Transcript area
                if settingsManager.settings.showTranscripts && (!userTranscript.isEmpty || !aiTranscript.isEmpty || agentState == .thinking) {
                    transcriptArea
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Bottom controls
                bottomControls
                    .padding(.bottom, 32)
            }

            // Error overlay
            if let error = errorMessage {
                errorOverlay(error)
            }
        }
        .animation(.spring(response: 0.4), value: agentState)
        .animation(.spring(response: 0.4), value: userTranscript)
        .animation(.spring(response: 0.4), value: aiTranscript)
        .onAppear {
            setupVoiceCommandService()
            setupGlassesCallbacks()
            preloadLocalModelIfNeeded()
            // Resume wake-word listening when returning to this screen. .onDisappear stops it
            // (e.g. when navigating to Settings), and the one-time .task doesn't re-run on return —
            // so without this, the wake word stayed dead until you tapped the mic button.
            if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
                startWakeWordListening()
            }
        }
        .onDisappear {
            voiceCommandService.stopListening()
        }
        .task {
            await requestSpeechAuthorization()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { isSpeaking in
            if isSpeaking {
                agentState = .speaking
                // Pause barge-in detection while TTS is playing
                // (prevents microphone picking up TTS and triggering interruption)
                voiceCommandService.isBargeInPaused = true
            } else {
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
        // Kokoro drives the same speaking-state flow as Apple TTS: keep the recognizer running
        // (in .processing) with barge-in paused so it stays in the conversation loop, then enter
        // conversation mode when playback finishes. (Don't stopListening — that trips the .idle
        // session-teardown observer and ends the conversation after every reply.)
        .onChange(of: kokoroTTS.isSpeaking) { speaking in
            if speaking {
                agentState = .speaking
                voiceCommandService.isBargeInPaused = true
            } else {
                voiceCommandService.isBargeInPaused = false
                if isSessionActive {
                    agentState = .listening
                    resumeListeningAfterSpeaking()
                } else {
                    agentState = .idle
                }
            }
        }
        // Control thinking sound based on agent state
        .onChange(of: agentState) { newState in
            if newState == .thinking || newState == .toolRunning {
                soundService.startThinkingSound()
            } else {
                soundService.stopThinkingSound()
            }
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { newState in
            print("[VoiceAgentView] VoiceCommandService state changed to: \(newState)")
            switch newState {
            case .idle:
                // In live video mode, a silence timeout must NOT end the mode — the user expects
                // to keep asking questions (camera stays on) until they say "stop video". Re-arm
                // conversation mode so the next question is heard without a fresh wake word.
                if isLiveVideoMode {
                    print("[VoiceAgentView] Idle during live video — re-arming conversation mode")
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
                    print("[VoiceAgentView] Voice service idle, stopping session")
                    isSessionActive = false
                    agentState = .idle
                    // Disconnect AI backend
                    Task {
                        switch settingsManager.settings.aiBackend {
                        case .openClaw:
                            await OpenClawService.shared.disconnect()
                        case .geminiLive:
                            await GeminiLiveService.shared.disconnect()
                        case .openAI:
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
            case .listening:
                // Keep the live indicator up in live video mode (don't clobber it back to
                // plain .listening, which would let the next idle tear the session down).
                if isLiveVideoMode {
                    agentState = .liveVideo
                } else if isSessionActive {
                    agentState = .listening
                }
            case .conversationMode:
                if isLiveVideoMode {
                    agentState = .liveVideo
                } else if isSessionActive {
                    agentState = .listening
                }
            case .processing:
                agentState = .thinking
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // AI Backend status (or Live Video indicator)
            if isLiveVideoMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )

                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.red.opacity(0.8))
                )
            } else {
                StatusPill(
                    status: settingsManager.settings.aiBackend.displayName,
                    color: agentState == .idle ? .gray : .green,
                    isConnected: agentState != .idle && agentState != .connecting
                )
            }

            Spacer()

            // Glasses status
            HStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? .green : .gray)

                if glassesManager.isStreaming {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Center Content

    private var centerContent: some View {
        VStack(spacing: 32) {
            // Status hints
            if agentState == .idle && settingsManager.settings.wakeWordEnabled {
                if isVoiceReady {
                    Text("Say \"\(settingsManager.settings.wakeWord)\" to start")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                        .transition(.opacity)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("Initializing voice...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .transition(.opacity)
                }
            } else if agentState == .liveVideo {
                VStack(spacing: 4) {
                    Text("Gemini Live")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Say \"stop video\" to exit")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .transition(.opacity)
            }

            // Waveform visualizer
            WaveformVisualizer(
                isActive: agentState == .listening || agentState == .speaking,
                intensity: audioLevel
            )
            .frame(height: 80)
            .padding(.horizontal, 40)

            // Main orb button
            GlowingOrbButton(
                isActive: isSessionActive,
                isProcessing: agentState == .thinking || agentState == .toolRunning
            ) {
                toggleSession()
            }

            // Status text
            Text(agentState.displayText)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.white)

            // Tool status
            if let tool = currentToolName, agentState == .toolRunning {
                ToolStatusView(toolName: tool, isRunning: true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        GlassCard(cornerRadius: 24, opacity: 0.1) {
            VStack(spacing: 16) {
                TranscriptView(
                    userText: userTranscript,
                    aiText: aiTranscript,
                    isAIStreaming: agentState == .speaking
                )
            }
            .padding(20)
        }
        .padding(.horizontal)
        .frame(maxHeight: 200)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 24) {
            // Camera button
            FloatingActionButton(
                icon: "camera.fill",
                color: .blue,
                isEnabled: glassesManager.isStreaming || true // Enable for iPhone fallback
            ) {
                capturePhoto()
            }

            // Main button is in center content

            // Settings quick access
            FloatingActionButton(
                icon: "slider.horizontal.3",
                color: .purple,
                isEnabled: true
            ) {
                // Quick settings
            }
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    private func startSession() {
        // Check configuration
        guard settingsManager.settings.isCurrentBackendConfigured else {
            errorMessage = "Please configure \(settingsManager.settings.aiBackend.displayName) in Settings"
            return
        }

        isSessionActive = true
        agentState = .connecting

        // Fresh conversation context for this session (follow-ups within the session keep context).
        ConversationContext.shared.clear()
        AppleFoundationService.shared.resetContext()

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

                case .appleFoundation:
                    try await AppleFoundationService.shared.connect()
                    // On-device Apple model — text only; camera commands guide to a cloud backend.

                case .geminiLive:
                    try await GeminiLiveService.shared.connect()
                    // Start glasses streaming for Gemini Live mode
                    if glassesManager.isRegistered && !glassesManager.isStreaming {
                        print("[VoiceAgentView] Starting glasses stream for Gemini Live...")
                        await glassesManager.startStreaming()
                    }

                    // Gemini Live also needs video streaming
                    if glassesManager.isRegistered && !glassesManager.isStreaming {
                        print("[VoiceAgentView] Starting glasses stream for Gemini Live...")
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

    /// Bring wake-word listening back after using the glasses camera. On DAT 0.4.0 the camera
    /// stream uses the Bluetooth transport, which disrupts the mic audio route and kills the
    /// speech recognizer — so we force a clean restart (reconfigure audio + restart listening).
    /// Resume listening after a spoken response ends — camera and text commands end identically:
    /// the persistent audio engine keeps running through a capture (never torn down — a rebuild
    /// would force a fresh Bluetooth HFP negotiation the glasses can't service right after
    /// streaming, leaving the mic deaf). Conversation mode's silence timeout then returns to idle.
    /// restartRecognition() revives the engine in place if the camera's route change stopped it.
    private func resumeListeningAfterSpeaking() {
        voiceCommandService.enterConversationMode()
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
    /// and they're the connected audio device, otherwise the phone's built-in mic + loud speaker.
    /// Attempting glasses is what makes iOS expose the HFP mic — so we try it directly rather than
    /// pre-checking availability (which can't see HFP until it's allowed). Returns true on glasses.
    @discardableResult
    private func applyPreferredAudioRoute() -> Bool {
        if settingsManager.settings.preferGlassesMic, glassesManager.isRegistered,
           (try? AudioSessionManager.shared.configureForGlasses()) == true {
            return true
        }
        // Glasses mic off, glasses not connected as audio, or no HFP input available → phone.
        // Loud speaker so spoken replies are audible (not the quiet earpiece).
        print("[VoiceAgentView] Using iPhone mic + speaker (glasses mic off or unavailable)")
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

    private func stopSession() {
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
            case .openAI:
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
                print("[VoiceAgentView] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()
        KokoroTTSService.shared.stop()

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
        ttsService.stop()
        KokoroTTSService.shared.stop()
        audioPlayback.stop()
        ttsStreaming = false

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw: await OpenClawService.shared.interrupt()
            case .geminiLive: await GeminiLiveService.shared.interrupt()
            case .openAI: break   // single request/response — nothing to interrupt
            case .appleFoundation: AppleFoundationService.shared.interrupt()
            case .localGemma: GemmaLocalService.shared.interrupt()
            }
        }

        if isLiveVideoMode {
            Task { await stopLiveVideoMode() }
        }

        // Go quiet: end the turn, return to wake-word idle. Say "Ok Vision" to start again.
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isSessionActive = false
        agentState = .idle
    }

    private func capturePhoto() {
        Task {
            if glassesManager.isStreaming {
                await glassesManager.capturePhoto()
            } else {
                // Use iPhone camera fallback
                // TODO: Implement iPhone camera capture
            }
        }
    }

    // MARK: - Voice Command Setup

    /// Request speech recognition authorization
    /// Warm up the on-device model in the background so the FIRST "Ok Vision" is instant
    /// (no multi-second load on wake). Only when Local Gemma is the selected, downloaded backend.
    private func preloadLocalModelIfNeeded() {
        guard settingsManager.settings.aiBackend == .localGemma,
              settingsManager.settings.localGemmaModelReady else { return }
        Task {
            do {
                try await GemmaLocalService.shared.connect(modelId: settingsManager.settings.localGemmaModelId)
                print("[VoiceAgentView] Local model preloaded — wake word will be instant")
            } catch {
                print("[VoiceAgentView] Local model preload failed: \(error.localizedDescription)")
            }
        }
    }

    private func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            print("[VoiceAgentView] Speech recognition authorized")
            startWakeWordListening()
        } else {
            print("[VoiceAgentView] Speech recognition not authorized")
            errorMessage = "Speech recognition not authorized. Please enable in Settings."
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        print("[VoiceAgentView] Setting up voice command callbacks")

        // Allow wake word to interrupt TTS (for "ok vision stop")
        voiceCommandService.shouldAllowInterrupt = { [weak ttsService] in
            return ttsService?.isSpeaking ?? false
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = {
            print("[VoiceAgentView] Wake word detected!")
            HapticFeedback.medium()
            self.soundService.playWakeWordSound()

            // If TTS is speaking, stop it immediately (interrupt)
            if self.ttsService.isSpeaking {
                print("[VoiceAgentView] Stopping TTS due to wake word interrupt")
                self.ttsService.stop()
                self.ttsStreaming = false   // keep view flag in sync with the cleared stream
                KokoroTTSService.shared.stop()
                self.audioPlayback.stop()
                // Cancel any in-flight on-device generation too — otherwise its next streamed
                // token would immediately restart speech we just stopped.
                GemmaLocalService.shared.interrupt()
                self.agentState = .listening
            }

            // Auto-start session if not already active (use Task to avoid blocking)
            Task { @MainActor in
                if !self.isSessionActive && self.settingsManager.settings.isCurrentBackendConfigured {
                    print("[VoiceAgentView] Starting session from wake word...")
                    self.startSession()
                }
            }
        }

        // "Ok Vision stop" during a reply → full stop, go quiet (the recognizer is already reset
        // to wake-word idle by VoiceCommandService; here we just halt output + end the turn).
        voiceCommandService.onStopCommand = {
            print("[VoiceAgentView] Full stop requested")
            self.performFullStop()
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { (command: String) in
            print("[VoiceAgentView] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                print("[VoiceAgentView] Ignoring command - session not active")
                return
            }

            self.userTranscript = command

            // Send command to AI backend
            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = {
            print("[VoiceAgentView] Barge-in detected")

            // Stop TTS immediately
            self.ttsService.stop()
            KokoroTTSService.shared.stop()

            // Stop current AI response
            Task {
                switch self.settingsManager.settings.aiBackend {
                case .openClaw:
                    await OpenClawService.shared.interrupt()
                case .geminiLive:
                    await GeminiLiveService.shared.interrupt()
                case .openAI:
                    break   // single request/response — nothing to interrupt
                case .appleFoundation:
                    AppleFoundationService.shared.interrupt()
                case .localGemma:
                    GemmaLocalService.shared.interrupt()
                }
            }
        }

        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = {
            // In live video mode, silence must not end the session — the .idle state handler
            // re-arms conversation mode so the user can keep asking until they say "stop video".
            if self.isLiveVideoMode {
                print("[VoiceAgentView] Conversation timeout during live video — staying live")
                return
            }
            print("[VoiceAgentView] Conversation timeout - returning to idle")
            self.stopSession()
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        print("[VoiceAgentView] Voice command callbacks setup complete")
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // Local Gemma callbacks
        GemmaLocalService.shared.onPartialResponse = { (partial: String) in
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            // Show tokens as they stream so it doesn't look stuck on "thinking".
            self.aiTranscript = partial
            // Apple TTS: start speaking completed sentences as they arrive (pipeline speech
            // behind generation) instead of waiting for the whole reply. Big perceived speedup,
            // and Apple TTS isn't on the GPU so it doesn't fight the on-device model.
            if self.usingAppleTTS { self.feedStreamingSpeech(partial, isFinal: false) }
        }
        GemmaLocalService.shared.onAgentMessage = { (message: String) in
            // In local live video mode replies must flow even if the session timer lapsed
            // while the user was silently looking around.
            guard self.isSessionActive || self.isLiveVideoMode else { return }
            self.aiTranscript = message
            if self.usingAppleTTS {
                // Flush any unspoken tail and close the streamed utterance session.
                self.feedStreamingSpeech(message, isFinal: true)
            } else {
                // Kokoro (on-device neural, GPU): synthesize the full reply after generation —
                // keeps it off the GPU while the model is still decoding.
                self.speakResponse(message)
            }
        }
        GemmaLocalService.shared.onProcessingChanged = { (isProcessing: Bool) in
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
                    self.ttsService.endStreaming()
                    self.ttsStreaming = false
                }
                if self.agentState == .thinking && !self.ttsService.isSpeaking {
                    // Return to the live video indicator, not plain listening, while in live mode.
                    self.agentState = self.isLiveVideoMode ? .liveVideo
                        : (self.isSessionActive ? .listening : .idle)
                }
            }
        }

        // OpenAI callbacks
        OpenAIService.shared.onAgentMessage = { (message: String) in
            guard self.isSessionActive else { return }
            self.aiTranscript = message
            self.speakResponse(message)
        }
        OpenAIService.shared.onProcessingChanged = { (isProcessing: Bool) in
            if isProcessing {
                self.agentState = .thinking
            } else if self.agentState == .thinking && !self.ttsService.isSpeaking {
                self.agentState = self.isSessionActive ? .listening : .idle
            }
        }

        // Apple Foundation callbacks (used only by the direct-message fallback path)
        AppleFoundationService.shared.onAgentMessage = { (message: String) in
            guard self.isSessionActive else { return }
            self.aiTranscript = message
            self.speakResponse(message)
        }
        AppleFoundationService.shared.onProcessingChanged = { (isProcessing: Bool) in
            if isProcessing {
                self.agentState = .thinking
            } else if self.agentState == .thinking && !self.ttsService.isSpeaking {
                self.agentState = self.isSessionActive ? .listening : .idle
            }
        }

        // OpenClaw callbacks
        OpenClawService.shared.onAgentMessage = { (message: String) in
            print("[VoiceAgentView] Received AI message: \(message.prefix(50))...")

            // IMPORTANT: Only speak responses when session is active
            // This prevents speaking stale responses after session ends
            guard self.isSessionActive else {
                print("[VoiceAgentView] Ignoring AI message - session not active")
                return
            }

            self.aiTranscript = message

            // Speak the response via TTS
            self.speakResponse(message)
            // Note: agentState will be set to .speaking by TTS callback
            // and back to .listening when TTS ends
        }

        OpenClawService.shared.onProcessingChanged = { (isProcessing: Bool) in
            print("[VoiceAgentView] Processing changed: \(isProcessing)")
            if isProcessing {
                self.agentState = .thinking
            } else if self.agentState == .thinking && !self.ttsService.isSpeaking {
                // Only go to listening if not speaking
                self.agentState = self.isSessionActive ? .listening : .idle
            }
        }

        OpenClawService.shared.onToolStatusChanged = { (toolName: String?, isRunning: Bool) in
            print("[VoiceAgentView] Tool status: \(toolName ?? "none"), running: \(isRunning)")
            self.currentToolName = toolName
            if isRunning {
                self.agentState = .toolRunning
            }
        }

        // Handle tool calls (e.g., take_photo)
        OpenClawService.shared.onToolCall = { (toolName: String, args: [String: Any], completion: @escaping (String) -> Void) in
            print("[VoiceAgentView] Tool call: \(toolName) with args: \(args)")

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
                print("[VoiceAgentView] Unknown tool: \(toolName)")
                completion("Tool '\(toolName)' is not available on this device.")
            }
        }

        // Gemini Live callbacks (for Gemini Live mode, not hybrid)
        GeminiLiveService.shared.onOutputTranscription = { (text: String) in
            self.aiTranscript = text
        }

        GeminiLiveService.shared.onTurnComplete = {
            self.agentState = self.isSessionActive ? .listening : .idle
            self.voiceCommandService.enterConversationMode()
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
            print("[VoiceAgentView] Started wake word listening - READY")
        } catch {
            print("[VoiceAgentView] Failed to start listening: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Send command to AI backend
    private func sendCommand(_ command: String) async {
        let lowerCommand = command.lowercased()

        // Check for "stop" command - stops TTS and waits for next command
        let stopKeywords = ["stop", "be quiet", "shut up", "silence", "quiet", "enough", "ok stop", "okay stop"]
        let isStopCommand = stopKeywords.contains { lowerCommand.contains($0) } &&
                           !lowerCommand.contains("video") && !lowerCommand.contains("stream")

        if isStopCommand {
            print("[VoiceAgentView] Stop command detected - full stop")
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
            print("[VoiceAgentView] Starting live video mode...")
            await startLiveVideoMode()
            return
        }

        if isStopLiveCommand {
            print("[VoiceAgentView] Stopping live video mode...")
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
                    print("[VoiceAgentView] Failed to send to Gemini Live: \(error)")
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
            print("[VoiceAgentView] Ignoring duplicate command within 4s: \(command)")
            return
        }
        lastProcessedCommand = command
        lastProcessedAt = now

        // Face recognition on CLOUD backends: classify via the on-device model (if loaded) up front.
        // On the Local backend we DON'T do this — routing is merged into the single generation below
        // (case .localGemma) so we never run two Gemma generations per command (memory/jetsam).
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

        do {
            switch settingsManager.settings.aiBackend {
            case .openClaw:
                if isPhotoCommand {
                    // Capture photo and send with command
                    print("[VoiceAgentView] Photo command detected, capturing...")
                    await captureAndSendPhoto(withPrompt: command)
                } else {
                    // Regular command - send as-is
                    try await OpenClawService.shared.sendMessage(command)
                }
                // State updates handled by callbacks

            case .openAI:
                if isPhotoCommand {
                    print("[VoiceAgentView] Photo command on OpenAI — capturing...")
                    await captureAndSendPhoto(withPrompt: command)
                } else {
                    try await OpenAIService.shared.sendMessage(command)
                }
                agentState = isSessionActive ? .listening : .idle

            case .geminiLive:
                try await GeminiLiveService.shared.sendText(command)
                // Gemini Live handles response streaming via callbacks

            case .localGemma:
                await handleLocalCommand(command, llm: GemmaLocalService.shared, isPhotoCommand: isPhotoCommand)

            case .appleFoundation:
                await handleLocalCommand(command, llm: AppleFoundationService.shared, isPhotoCommand: isPhotoCommand)
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
            print("[VoiceAgentView] Already in live video mode")
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

        print("[VoiceAgentView] Starting live video mode via \(label)...")

        // Stop VoiceCommandService - the live backend will handle audio directly
        voiceCommandService.stopListening()

        // Stop TTS if speaking
        ttsService.stop()
        KokoroTTSService.shared.stop()

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
                print("[VoiceAgentView] Failed to restart voice commands: \(error)")
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
            print("[VoiceAgentView] Failed to setup audio playback: \(error)")
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

        print("[VoiceAgentView] ✓ Live video mode active - \(label) handling audio + video")

        // Announce to user
        ttsService.speak("Live video mode active")
    }

    /// Resolve which live-video backend to use, or nil if none is configured.
    /// - OpenAI selected + configured → OpenAI Realtime
    /// - otherwise Gemini if configured (default video provider), else OpenAI if configured.
    private func resolveLiveService() -> (service: any LiveVideoService, label: String)? {
        let settings = settingsManager.settings
        if settings.aiBackend == .openAI && settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        if settings.isGeminiConfigured {
            return (geminiLive, "Gemini Live")
        }
        if settings.isOpenAIConfigured {
            return (openAIRealtime, "OpenAI Realtime")
        }
        return nil
    }

    /// Fully on-device live video (SmolVLM2). Unlike the cloud modes, audio stays on the normal
    /// Apple STT path — we just keep the glasses camera streaming and mark the mode active, so
    /// each spoken question is answered against the latest frame (see processCommand). Replies
    /// speak through the selected TTS engine as usual.
    private func startLocalLiveVideoMode() async {
        print("[VoiceAgentView] Starting local live video mode (SmolVLM2)...")

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
            print("[VoiceAgentView] Failed to restart STT on phone mic: \(error)")
        }

        // Stay in conversation mode so follow-ups don't need the wake word.
        voiceCommandService.enterConversationMode()

        isLiveVideoMode = true
        agentState = .liveVideo

        print("[VoiceAgentView] ✓ Local live video mode active - SmolVLM2 answering on latest frame")
        ttsService.speak("Live video mode active, on device")
    }

    /// Answer a spoken question in local live video mode using a fresh, settled glasses frame.
    private func handleLocalLiveVideoCommand(_ command: String) async {
        agentState = .thinking
        // Let head motion settle and grab the freshest frame, so we describe the CURRENT view
        // rather than a stale/motion-blurred one the Bluetooth stream delivered a beat ago.
        guard let frame = await freshestGlassesFrame(settle: 0.3, maxWait: 1.0),
              let jpeg = frame.jpegData(compressionQuality: 0.6) else {
            speakResponse("I couldn't get a clear view just now — hold still a second and ask again.")
            agentState = .liveVideo
            return
        }
        do {
            // Strip "take a photo"-style wording; the frame is already attached.
            let prompt = visionPromptFromCommand(command)
            try await GemmaLocalService.shared.sendMessage(prompt, imageData: jpeg)
        } catch {
            print("[VoiceAgentView] Local live video inference failed: \(error)")
            speakResponse("Sorry, that didn't work. \(error.localizedDescription)")
        }
        if isLiveVideoMode { agentState = .liveVideo }
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

    /// Stop live video mode - return to OpenClaw
    private func stopLiveVideoMode() async {
        guard isLiveVideoMode else {
            print("[VoiceAgentView] Not in live video mode")
            return
        }

        print("[VoiceAgentView] Stopping live video mode...")

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
        glassesManager.onVideoFrame = { [weak geminiVision] image in
            geminiVision?.sendVideoFrame(image)
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
                print("[VoiceAgentView] Restarted voice commands in conversation mode")
            } else {
                // Just listen for wake word
                print("[VoiceAgentView] Restarted voice commands for wake word detection")
            }
        } catch {
            print("[VoiceAgentView] Failed to restart voice commands: \(error)")
        }

        print("[VoiceAgentView] Live video mode stopped - back to OpenClaw")
        ttsService.speak("Live video mode ended")
    }

    /// Setup live backend callbacks for audio/transcription (Gemini Live or OpenAI Realtime)
    private func setupLiveVideoCallbacks(_ service: any LiveVideoService) {
        // Audio from the model → playback
        service.onAudioReceived = { [weak audioPlayback] data in
            audioPlayback?.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        service.onInputTranscription = { text in
            Task { @MainActor in
                self.userTranscript = text

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                let stopKeywords = ["stop video", "stop streaming", "stop live", "end video",
                                   "exit video", "disable video", "stop the video", "end live",
                                   // Hindi fallbacks (models sometimes transcribe English as Hindi)
                                   "स्टॉप", "वीडियो बंद", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    print("[VoiceAgentView] Stop command detected in transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        service.onOutputTranscription = { text in
            Task { @MainActor in
                self.aiTranscript = text
            }
        }

        // Turn complete
        service.onTurnComplete = {
            // Still in live mode, keep listening
        }

        // Disconnection - handle reconnection or mode exit
        service.onDisconnected = {
            Task { @MainActor in
                if self.isLiveVideoMode {
                    print("[VoiceAgentView] Live backend disconnected unexpectedly")
                    await self.stopLiveVideoMode()
                }
            }
        }
    }

    /// Capture photo and send to OpenClaw with the user's prompt
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
                print("[VoiceAgentView] Photo command on local SmolVLM2 — capturing...")
                await captureAndSendPhoto(withPrompt: command)
                return
            }
            agentState = isSessionActive ? .listening : .idle
            speakResponse("This on-device model is text only. For camera questions, select SmolVLM2 as your local model, or switch to Gemini or OpenClaw in Settings.")
            return
        }
        // Route the command. On the local backend with Apple TTS, stream the answer: speak
        // sentences as they generate. Face/tool routes emit JSON starting with "{", so we only
        // begin speaking once the streamed output's first non-space char proves it's a plain
        // answer — never for a structured route.
        let result: LocalAgent.RouteResult
        if let gemma = llm as? GemmaLocalService, usingAppleTTS {
            ttsStreaming = false
            ttsStreamSpokenChars = 0
            result = await gemma.routeCommandStreaming(command) { cumulative in
                let lead = cumulative.trimmingCharacters(in: .whitespacesAndNewlines).first
                guard let lead, lead != "{" else { return }   // JSON route → don't speak
                self.feedStreamingSpeech(cumulative, isFinal: false)
            }
        } else {
            result = await llm.routeCommand(command)
        }

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
                speakResponse(text)   // Kokoro, or non-Gemma backend
            }
            ConversationContext.shared.record(user: command, assistant: text)
        }
        agentState = isSessionActive ? .listening : .idle
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
        switch settingsManager.settings.aiBackend {
        case .openClaw:
            try await OpenClawService.shared.sendMessage(prompt, imageData: imageData)
        case .openAI:
            try await OpenAIService.shared.sendMessage(prompt, imageData: imageData)
        case .appleFoundation:
            // Text-only — send the prompt, ignore the image.
            await AppleFoundationService.shared.sendMessage(prompt)
        case .localGemma:
            try await GemmaLocalService.shared.sendMessage(prompt, imageData: imageData)
        case .geminiLive:
            // Gemini Live streams video continuously; just send the text prompt.
            try await GeminiLiveService.shared.sendText(prompt)
        }
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
            print("[VoiceAgentView] Starting glasses camera stream for photo...")
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
            print("[VoiceAgentView] Failed to send: \(error)")
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

    /// Frame counter for logging
    @State private var videoFrameCount: Int = 0

    /// Setup glasses callbacks to stream video to Gemini Vision
    private func setupGlassesCallbacks() {
        print("[VoiceAgentView] Setting up glasses video callbacks...")

        // Connect video frames from glasses to Gemini Vision (for live feed)
        // Note: GeminiVisionService.sendVideoFrame already throttles to 1fps
        glassesManager.onVideoFrame = { [weak geminiVision] image in
            // Send frame to Gemini Vision for live analysis
            geminiVision?.sendVideoFrame(image)

            // Log periodically (every 30 frames = ~1 second at 30fps)
            Task { @MainActor in
                self.videoFrameCount += 1
                if self.videoFrameCount % 30 == 0 {
                    print("[VoiceAgentView] Video frames processed: \(self.videoFrameCount)")
                }
            }
        }

        // Photo captured callback (for OpenClaw photo analysis)
        glassesManager.onPhotoCaptured = { data in
            print("[VoiceAgentView] Photo captured: \(data.count) bytes")
            // Photos are handled via OpenClaw's attachment system
        }

        print("[VoiceAgentView] Glasses callbacks configured")
    }

    // MARK: - TTS Integration

    /// True when the active speech engine is Apple's system voice (not Kokoro). Apple TTS runs on
    /// a system audio service — not the Metal GPU — so it can pipeline speech while the on-device
    /// model is still generating, with no resource contention.
    private var usingAppleTTS: Bool {
        !(settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady)
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
            ttsService.beginStreaming()
        }

        // The portion not yet handed to the speech queue.
        let spokenClamped = min(ttsStreamSpokenChars, cumulative.count)
        let start = cumulative.index(cumulative.startIndex, offsetBy: spokenClamped)
        let pending = cumulative[start...]

        if isFinal {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { ttsService.speakChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            ttsService.endStreaming()
            ttsStreaming = false
            return
        }

        // Speak everything up to the last completed sentence boundary in the pending text.
        guard let boundary = lastSentenceBoundary(in: String(pending)) else { return }
        let pendingStr = String(pending)
        let sentence = String(pendingStr[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 2 else { return }   // don't voice a stray "." or "?"
        ttsService.speakChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
    }

    /// Index just past the last sentence terminator (. ! ? or newline) in `s`, or nil if none.
    /// A `.`/`!`/`?` only counts when followed by whitespace or end-of-text, so decimals like
    /// "2.5" and abbreviations don't get split mid-number.
    private func lastSentenceBoundary(in s: String) -> String.Index? {
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

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        // Kokoro (on-device neural) when selected + ready; otherwise the Apple system voice.
        if settingsManager.settings.ttsEngine == .kokoro && KokoroTTSService.shared.isModelReady {
            Task { await KokoroTTSService.shared.speak(text, voice: settingsManager.settings.kokoroVoice) }
        } else {
            ttsService.speak(text)
        }
    }

    // MARK: - Tool Handlers

    /// Handle take_photo tool call
    private func handleTakePhotoTool(completion: @escaping (String) -> Void) async {
        print("[VoiceAgentView] Handling take_photo tool")

        if glassesManager.isStreaming {
            // Capture from glasses
            await glassesManager.capturePhoto()

            // Wait for photo to be captured (via callback)
            // Set up one-time handler for the photo
            let originalHandler = glassesManager.onPhotoCaptured
            glassesManager.onPhotoCaptured = { data in
                // Restore original handler
                self.glassesManager.onPhotoCaptured = originalHandler

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
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
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
        print("[VoiceAgentView] Handling describe_scene tool")

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

#Preview {
    VoiceAgentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .preferredColorScheme(.dark)
}
