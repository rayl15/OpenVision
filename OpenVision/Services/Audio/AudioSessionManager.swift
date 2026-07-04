// OpenVision - AudioSessionManager.swift
// Manages AVAudioSession configuration for different modes

import AVFoundation

/// Manages audio session configuration
@MainActor
final class AudioSessionManager {
    // MARK: - Singleton

    static let shared = AudioSessionManager()

    // MARK: - Properties

    private let audioSession = AVAudioSession.sharedInstance()

    /// Current audio mode
    private(set) var currentMode: AudioMode = .inactive

    // MARK: - Audio Modes

    enum AudioMode {
        /// No audio session active
        case inactive

        /// Voice chat mode (aggressive echo cancellation for iPhone mic)
        case voiceChat

        /// Video chat mode (mild echo cancellation for glasses mic)
        case videoChat

        /// Measurement mode (for wake word detection)
        case measurement
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure audio session for specified mode
    func configure(for mode: AudioMode) throws {
        guard mode != currentMode else { return }

        switch mode {
        case .inactive:
            try deactivate()

        case .voiceChat:
            try configureVoiceChat()

        case .videoChat:
            try configureVideoChat()

        case .measurement:
            try configureMeasurement()
        }

        currentMode = mode
        print("[AudioSession] Configured for \(mode)")
    }

    /// Deactivate audio session
    func deactivate() throws {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        currentMode = .inactive
    }

    // MARK: - Mode Configurations

    /// Configure for voice chat (iPhone mic, aggressive AEC)
    private func configureVoiceChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for video chat (glasses mic, mild AEC)
    private func configureVideoChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for measurement (wake word detection)
    private func configureMeasurement() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    // MARK: - Bluetooth HFP Routing

    /// Configure the audio session for the glasses' Bluetooth HFP mic + speaker.
    /// Returns `true` only if an HFP input was actually found and selected (i.e. the glasses are
    /// connected as an audio device); `false` means no glasses audio is present and the caller
    /// should fall back to the phone. NOTE: we must set the category with `.allowBluetoothHFP` and
    /// activate the session *first* — only then does iOS expose the HFP input in `availableInputs`
    /// (this is what previously made the glasses mic undetectable: the phone route disallows HFP).
    @discardableResult
    func configureForGlasses() throws -> Bool {
        // Match OpenGlasses: `.default` mode + `.mixWithOthers` so the recognizer's session COEXISTS
        // with the glasses camera's Bluetooth stream instead of taking exclusive HFP control. With
        // `.voiceChat` + `.duckOthers` the camera stream killed the HFP mic (and iOS wouldn't revive
        // it); `.mixWithOthers` keeps the glasses mic alive through photo capture.
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Now that HFP is allowed + the session is active, the glasses mic should be listed.
        guard let hfpInput = findBluetoothHFPInput() else {
            print("[AudioSession] No Bluetooth HFP input — glasses not connected as an audio device. Inputs: \(availableInputsDescription)")
            return false
        }
        try audioSession.setPreferredInput(hfpInput)
        currentMode = .voiceChat
        print("[AudioSession] ✓ Configured for glasses (Bluetooth HFP): \(hfpInput.portName) — route: \(currentRouteDescription)")
        return true
    }

    /// Names + types of every input iOS currently reports — for diagnosing mic routing.
    var availableInputsDescription: String {
        (audioSession.availableInputs ?? []).map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    /// Configure audio for phone-only use (no glasses): record from the built-in mic and play
    /// spoken responses out of the LOUD speaker. Without `.defaultToSpeaker`, `.playAndRecord`
    /// routes output to the quiet earpiece — which is why phone-only audio was inaudible.
    /// `.allowBluetoothA2DP` still lets AirPods / other Bluetooth audio work when present.
    func configureForPhone() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
        // If still routed to the quiet earpiece (carried over from a glasses/voiceChat config),
        // force the loud speaker — but leave AirPods / headphones alone if they're connected.
        if audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try? audioSession.overrideOutputAudioPort(.speaker)
        }
        currentMode = .voiceChat
        print("[AudioSession] Configured for phone (built-in mic + loud speaker)")
    }

    /// Find Bluetooth HFP input port
    private func findBluetoothHFPInput() -> AVAudioSessionPortDescription? {
        for input in audioSession.availableInputs ?? [] {
            if input.portType == .bluetoothHFP {
                return input
            }
        }
        return nil
    }

    /// Check if Bluetooth HFP is currently active
    var isBluetoothHFPActive: Bool {
        let inputs = audioSession.currentRoute.inputs
        let outputs = audioSession.currentRoute.outputs

        let hasHFPInput = inputs.contains { $0.portType == .bluetoothHFP }
        let hasHFPOutput = outputs.contains { $0.portType == .bluetoothHFP }

        return hasHFPInput || hasHFPOutput
    }

    /// Get current audio route description
    var currentRouteDescription: String {
        let inputs = audioSession.currentRoute.inputs.map { $0.portName }.joined(separator: ", ")
        let outputs = audioSession.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        return "Input: \(inputs.isEmpty ? "none" : inputs), Output: \(outputs.isEmpty ? "none" : outputs)"
    }

    // MARK: - Utilities

    /// Get current input sample rate
    var inputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Get current output sample rate
    var outputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Check if Bluetooth audio is available
    var isBluetoothAvailable: Bool {
        audioSession.availableInputs?.contains { port in
            port.portType == .bluetoothHFP || port.portType == .bluetoothA2DP
        } ?? false
    }

    /// Check if using built-in mic
    var isUsingBuiltInMic: Bool {
        audioSession.currentRoute.inputs.contains { port in
            port.portType == .builtInMic
        }
    }
}
