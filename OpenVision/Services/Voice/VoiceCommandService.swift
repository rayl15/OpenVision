// OpenVision - VoiceCommandService.swift
// Wake word detection and voice command capture using Apple Speech Recognition

import Foundation
import Speech
import AVFoundation

/// Voice command service with wake word detection
///
/// Features:
/// - Wake word detection ("Hey Vision")
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

    /// Called when a command is captured
    var onCommandCaptured: ((String) -> Void)?

    /// Called when user interrupts (barge-in)
    var onInterruption: (() -> Void)?

    /// Called when conversation mode times out (no speech detected)
    var onConversationTimeout: (() -> Void)?

    // MARK: - Barge-in Control

    /// When true, barge-in detection is paused (e.g., during TTS playback)
    var isBargeInPaused: Bool = false

    // MARK: - Speech Recognition

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?

    // MARK: - Timers

    private var silenceTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var conversationTimeoutTimer: Timer?
    private var wakeWordCooldownActive: Bool = false

    /// Tracks if user has started speaking in this turn
    private var hasSpokenThisTurn: Bool = false

    // MARK: - Audio Feedback

    private var activationSound: AVAudioPlayer?

    // MARK: - Initialization

    private init() {
        setupActivationSound()
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

    /// Start listening for wake word or commands
    func startListening() throws {
        guard authorizationStatus == .authorized else {
            throw VoiceCommandError.notAuthorized
        }

        guard !isListening else { return }

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

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation

        // Get input node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        state = isWakeWordEnabled ? .idle : .listening
        print("[VoiceCommand] Started listening")
    }

    /// Stop listening
    func stopListening() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

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

        // Stop current recognition
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Remove tap and stop engine briefly
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Create new recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation

        // Reinstall tap
        guard let audioEngine = audioEngine else { return }
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        // Start new recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }

        print("[VoiceCommand] Restarted recognition (cleared buffer)")
    }

    /// Exit conversation mode
    func exitConversationMode() {
        state = isWakeWordEnabled ? .idle : .listening
        silenceTimer?.invalidate()
        silenceTimer = nil
        conversationTimeoutTimer?.invalidate()
        conversationTimeoutTimer = nil
        hasSpokenThisTurn = false
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
        guard let result = result else {
            if let error = error {
                print("[VoiceCommand] Recognition error: \(error)")
            }
            return
        }

        let transcription = result.bestTranscription.formattedString
        currentTranscription = transcription

        switch state {
        case .idle:
            // Check for wake word
            if detectWakeWord(in: transcription) {
                handleWakeWordDetected()
            }

        case .listening, .conversationMode:
            // Mark that user has started speaking
            if transcription.count > 3 {
                hasSpokenThisTurn = true
                // Cancel conversation timeout since user is speaking
                conversationTimeoutTimer?.invalidate()
            }

            // Reset silence timer on new speech
            resetSilenceTimer()

            // Check for command completion
            if result.isFinal {
                handleCommandComplete(transcription)
            }

        case .processing:
            // Check for barge-in (only if not paused - e.g., during TTS playback)
            if !isBargeInPaused && detectSpeechStart(in: transcription) {
                handleBargeIn()
            }
        }
    }

    /// Detect wake word in transcription
    private func detectWakeWord(in text: String) -> Bool {
        guard !wakeWordCooldownActive else { return false }

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
            // Hey Vision variants
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

    /// Handle wake word detection
    private func handleWakeWordDetected() {
        print("[VoiceCommand] Wake word detected!")

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

        state = .processing
        silenceTimer?.invalidate()
        commandTimeoutTimer?.invalidate()

        // Clear transcription to prevent re-sending the same command
        currentTranscription = ""

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

    /// Reset silence timer
    private func resetSilenceTimer() {
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
