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
                // Conversation ended, return to idle
                if isSessionActive {
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

    /// Configure audio routing to use glasses mic/speaker if available
    private func configureAudioForGlasses() {
        guard glassesManager.isRegistered else {
            print("[VoiceAgentView] Glasses not registered, using iPhone audio")
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

            case .geminiLive:
                try await GeminiLiveService.shared.sendText(command)
                // Gemini Live handles response streaming via callbacks
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

        if glassesManager.isStreaming {
            // Capture from glasses camera
            print("[VoiceAgentView] Capturing from glasses...")
            imageData = await capturePhotoFromGlasses()
        } else {
            print("[VoiceAgentView] Stream not active, checking for last frame...")
        }

        // Fallback to last frame if we have one
        if imageData == nil, let lastFrame = glassesManager.lastFrame {
            print("[VoiceAgentView] Using last frame...")
            imageData = lastFrame.jpegData(compressionQuality: 0.8)
        }

        // Send with or without image
        do {
            if let imageData = imageData {
                print("[VoiceAgentView] Sending message with photo (\(imageData.count) bytes)")
                try await OpenClawService.shared.sendMessage(prompt, imageData: imageData)

                // Only stop streaming if:
                // 1. We started it just for this photo, AND
                // 2. Not in live video mode
                if startedStreamingForPhoto && !isLiveVideoMode {
                    print("[VoiceAgentView] Stopping camera stream after photo")
                    await glassesManager.stopStreaming()
                } else if isLiveVideoMode {
                    print("[VoiceAgentView] Keeping stream active for live video mode")
                }
            } else {
                print("[VoiceAgentView] No image available, sending text only")
                // Provide more helpful message
                let note = glassesManager.isRegistered
                    ? " (Note: Camera is not available right now. Try starting the camera from Settings > Glasses first.)"
                    : " (Note: Smart glasses not connected. Please register in Settings.)"
                try await OpenClawService.shared.sendMessage(prompt + note)
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
        // Simple approach: just wait for photo via lastPhotoData
        // Request the capture
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 5 seconds)
        for _ in 0..<50 {
            if let photoData = glassesManager.lastPhotoData {
                // Clear it so we don't reuse it
                glassesManager.lastPhotoData = nil
                print("[VoiceAgentView] Photo captured: \(photoData.count) bytes")
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        print("[VoiceAgentView] Photo capture timed out")
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
