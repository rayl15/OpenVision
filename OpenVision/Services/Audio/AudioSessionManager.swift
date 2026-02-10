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

    /// Configure audio session for Bluetooth HFP (glasses mic + speaker)
    func configureForGlasses() throws {
        // Use HFP mode for bidirectional Bluetooth audio
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .allowBluetoothHFP,  // Required for HFP
                .duckOthers
            ]
        )
        try audioSession.setActive(true)

        // Find and set Bluetooth HFP as preferred input
        if let hfpInput = findBluetoothHFPInput() {
            try audioSession.setPreferredInput(hfpInput)
            print("[AudioSession] Set preferred input to Bluetooth HFP: \(hfpInput.portName)")
        } else {
            print("[AudioSession] Warning: No Bluetooth HFP input found")
        }

        currentMode = .voiceChat
        print("[AudioSession] Configured for glasses (Bluetooth HFP)")
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
