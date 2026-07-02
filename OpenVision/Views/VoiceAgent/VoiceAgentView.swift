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
    @StateObject private var ttsService = TTSService.shared
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

    /// Live Video Mode - uses Gemini Live for real-time audio + video
    @State private var isLiveVideoMode = false

    /// True when voice recognition is ready (audio engine running)
    @State private var isVoiceReady = false

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
                    voiceCommandService.enterConversationMode()
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
                // Conversation ended, return to idle — BUT ignore the transient .idle that fires
                // while a session is starting up: configureAudioForGlasses() briefly stops the
                // recognizer (→ .idle) mid-startup, which otherwise tore the session right back
                // down and left commands "ignored" (stuck on thinking). agentState == .connecting
                // means we're still starting, so don't treat it as a real conversation end.
                if isSessionActive && agentState != .connecting {
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
                if isSessionActive {
                    agentState = .listening
                }
            case .conversationMode:
                if isSessionActive {
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
    /// This is OpenVision's equivalent of OpenGlasses' "restore audio for wake word" after capture.
    private func resumeWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled,
              voiceCommandService.authorizationStatus == .authorized else { return }
        voiceCommandService.stopListening()
        // Glasses → Bluetooth HFP; phone-only → built-in mic + LOUD speaker (else TTS is inaudible).
        if glassesAudioAvailable {
            try? AudioSessionManager.shared.configureForGlasses()
        } else {
            try? AudioSessionManager.shared.configureForPhone()
        }
        do {
            try voiceCommandService.startListening()
            print("[VoiceAgentView] ✓ Restored wake-word listening after camera use")
        } catch {
            print("[VoiceAgentView] Failed to restore listening after camera: \(error)")
        }
    }

    /// Configure audio routing to use glasses mic/speaker if available
    /// True only when the glasses are actually reachable as a Bluetooth audio device. Registration
    /// alone isn't enough — the glasses can be registered but powered off / not worn, which would
    /// route TTS to the silent earpiece. When false, use the phone's loud speaker.
    private var glassesAudioAvailable: Bool {
        glassesManager.isRegistered && AudioSessionManager.shared.isBluetoothAvailable
    }

    private func configureAudioForGlasses() {
        guard glassesAudioAvailable else {
            // No glasses audio (not registered, or registered but off/disconnected): use the
            // phone's LOUD speaker so spoken responses are audible — not the quiet earpiece.
            print("[VoiceAgentView] No glasses audio route — using iPhone speaker")
            try? AudioSessionManager.shared.configureForPhone()
            return
        }

        // Stop listening temporarily if already active
        let wasListening = voiceCommandService.isListening
        if wasListening {
            voiceCommandService.stopListening()
        }

        do {
            try AudioSessionManager.shared.configureForGlasses()
            let route = AudioSessionManager.shared.currentRouteDescription
            print("[VoiceAgentView] Audio configured: \(route)")

            if AudioSessionManager.shared.isBluetoothHFPActive {
                print("[VoiceAgentView] ✓ Using glasses audio (Bluetooth HFP)")
            } else {
                print("[VoiceAgentView] ⚠ Bluetooth HFP not active, check glasses connection")
            }
        } catch {
            print("[VoiceAgentView] Failed to configure audio for glasses: \(error)")
            // Continue anyway - will fall back to iPhone audio
        }

        // Restart listening with new audio configuration
        if wasListening {
            do {
                try voiceCommandService.startListening()
                print("[VoiceAgentView] Restarted listening with new audio config")
            } catch {
                print("[VoiceAgentView] Failed to restart listening: \(error)")
            }
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
                self.audioPlayback.stop()
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
            guard self.isSessionActive else { return }
            // Show tokens as they stream so it doesn't look stuck on "thinking".
            self.aiTranscript = partial
        }
        GemmaLocalService.shared.onAgentMessage = { (message: String) in
            guard self.isSessionActive else { return }
            self.aiTranscript = message
            self.speakResponse(message)
        }
        GemmaLocalService.shared.onProcessingChanged = { (isProcessing: Bool) in
            if isProcessing {
                self.agentState = .thinking
            } else if self.agentState == .thinking && !self.ttsService.isSpeaking {
                self.agentState = self.isSessionActive ? .listening : .idle
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
            print("[VoiceAgentView] Stop command detected - stopping TTS")
            // Stop TTS
            ttsService.stop()
            // Stop audio playback (for Gemini Live)
            audioPlayback.stop()
            // Interrupt AI if processing
            Task {
                switch settingsManager.settings.aiBackend {
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
            // Stay in listening mode
            agentState = .listening
            aiTranscript = ""
            return
        }

        // Check for live video mode commands
        let startLiveKeywords = ["start video stream", "start live video", "start video", "start streaming",
                                 "enable video", "live mode", "go live", "video mode"]
        let stopLiveKeywords = ["stop video stream", "stop live video", "stop video", "stop streaming",
                               "disable video", "end live mode", "exit video mode", "stop live"]

        let isStartLiveCommand = startLiveKeywords.contains { lowerCommand.contains($0) }
        let isStopLiveCommand = stopLiveKeywords.contains { lowerCommand.contains($0) }

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

        // If in live video mode, Gemini handles everything - don't process here
        if isLiveVideoMode {
            // Gemini Live is handling audio directly, so this shouldn't be reached
            // But just in case, we can send text
            do {
                try await geminiLive.sendText(command)
            } catch {
                print("[VoiceAgentView] Failed to send to Gemini Live: \(error)")
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

        guard !settingsManager.settings.geminiAPIKey.isEmpty else {
            ttsService.speak("Please configure your Gemini API key in settings")
            return
        }

        print("[VoiceAgentView] Starting live video mode...")

        // Stop VoiceCommandService - Gemini will handle audio directly
        voiceCommandService.stopListening()

        // Stop TTS if speaking
        ttsService.stop()

        // Start glasses streaming
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }

        // Connect to Gemini Live
        do {
            try await geminiLive.connect()
        } catch {
            errorMessage = "Failed to connect to Gemini Live: \(error.localizedDescription)"
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

        // Setup Gemini Live callbacks
        setupGeminiLiveCallbacks()

        // Setup audio capture → Gemini Live
        audioCapture.onAudioCaptured = { [weak geminiLive] data in
            geminiLive?.sendAudio(data: data)
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
            await geminiLive.disconnect()
            voiceCommandService.enterConversationMode()
            return
        }

        // Setup video frame routing to Gemini Live
        glassesManager.onVideoFrame = { [weak geminiLive] image in
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                geminiLive?.sendVideoFrame(imageData: jpegData)
            }
        }

        isLiveVideoMode = true
        agentState = .liveVideo

        print("[VoiceAgentView] ✓ Live video mode active - Gemini handling audio + video")

        // Announce to user
        ttsService.speak("Live video mode active")
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

        // Disconnect Gemini Live
        await geminiLive.disconnect()

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

    /// Setup Gemini Live callbacks for audio/transcription
    private func setupGeminiLiveCallbacks() {
        // Audio from Gemini → playback
        geminiLive.onAudioReceived = { [weak audioPlayback] data in
            audioPlayback?.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        geminiLive.onInputTranscription = { text in
            Task { @MainActor in
                self.userTranscript = text

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                let stopKeywords = ["stop video", "stop streaming", "stop live", "end video",
                                   "exit video", "disable video", "stop the video", "end live",
                                   // Hindi fallbacks (Gemini sometimes transcribes English as Hindi)
                                   "स्टॉप", "वीडियो बंद", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    print("[VoiceAgentView] Stop command detected in Gemini transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        geminiLive.onOutputTranscription = { text in
            Task { @MainActor in
                self.aiTranscript = text
            }
        }

        // Turn complete
        geminiLive.onTurnComplete = {
            // Still in live mode, keep listening
        }

        // Disconnection - handle reconnection or mode exit
        geminiLive.onDisconnected = {
            Task { @MainActor in
                if self.isLiveVideoMode {
                    print("[VoiceAgentView] Gemini Live disconnected unexpectedly")
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
        let triggers = [
            "take a picture of this", "take a photo of this", "take a picture", "take a photo",
            "take photo", "take picture", "capture a photo", "capture photo", "snap a photo",
            "snap a picture", "can you", "could you", "would you", "please", "for me", "of this",
            "right now", "go ahead and"
        ]
        for t in triggers { s = s.replacingOccurrences(of: t, with: " ") }
        s = s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("and ") { s = String(s.dropFirst(4)) }
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
            // On-device models are text-only for scene description — vision needs a cloud backend.
            agentState = isSessionActive ? .listening : .idle
            speakResponse("On-device mode is text only. To use the camera to describe things, switch to Gemini or OpenClaw in Settings.")
            return
        }
        switch await llm.routeCommand(command) {
        case .face(let intent):
            await handleFaceIntent(intent)
        case .webSearch(let query):
            NSLog("[OV] web search: \"%@\"", query)
            let result = await WebSearchService.search(query)
            speakResponse(await llm.answerWithSearchResult(question: command, result: result))
        case .answer(let text):
            speakResponse(text)
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
        // The glasses camera (0.4.0, Bluetooth) disrupts the mic route — restore listening.
        resumeWakeWordListening()
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

        // Start streaming if glasses are registered but not streaming
        if glassesManager.isRegistered && !glassesManager.isStreaming {
            print("[VoiceAgentView] Starting glasses camera stream for photo...")
            await glassesManager.startStreaming()
            startedStreamingForPhoto = true

            // Wait for stream to actually be ready (up to 3 seconds)
            for _ in 0..<30 {
                if glassesManager.isStreaming {
                    print("[VoiceAgentView] Stream is ready!")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            // Give extra time for first frames to arrive
            if glassesManager.isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
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

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        ttsService.speak(text)
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
