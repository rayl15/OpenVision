// OpenVision - AudioPlaybackService.swift
// Plays audio data using AVAudioEngine

import AVFoundation

/// Plays audio data received from AI backends
@MainActor
final class AudioPlaybackService: ObservableObject {
    // MARK: - Published State

    @Published var isPlaying: Bool = false

    // MARK: - Callbacks

    /// Called when playback completes
    var onPlaybackComplete: (() -> Void)?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    // MARK: - Format

    /// Expected input sample rate (from Gemini)
    var inputSampleRate: Double = Double(Constants.GeminiLive.outputSampleRate)

    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    /// Setup audio engine for playback
    func setup() throws {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else {
            throw AudioPlaybackError.setupFailed
        }

        engine.attach(player)

        // Create output format (Float32 at device sample rate)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        try engine.start()
        print("[AudioPlayback] Engine started")
    }

    /// Teardown audio engine
    func teardown() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        isPlaying = false
    }

    // MARK: - Playback

    /// Play PCM Int16 audio data
    func playAudio(data: Data) {
        guard let engine = audioEngine, let player = playerNode else {
            print("[AudioPlayback] Engine not setup")
            return
        }

        // Convert Int16 PCM to Float32
        let floatSamples = convertFromInt16PCM(data)

        // Create buffer
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let outputSampleRate = outputFormat.sampleRate

        // Resample if needed
        let resampledSamples: [Float]
        if inputSampleRate != outputSampleRate {
            resampledSamples = resample(floatSamples, from: inputSampleRate, to: outputSampleRate)
        } else {
            resampledSamples = floatSamples
        }

        guard let buffer = createBuffer(from: resampledSamples, format: outputFormat) else {
            print("[AudioPlayback] Failed to create buffer")
            return
        }

        // Schedule and play
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                // Check if more audio is queued
                if self?.playerNode?.isPlaying == false {
                    self?.isPlaying = false
                    self?.onPlaybackComplete?()
                }
            }
        }

        if !player.isPlaying {
            player.play()
        }

        isPlaying = true
    }

    /// Stop playback
    func stop() {
        playerNode?.stop()
        isPlaying = false
    }

    // MARK: - Conversion

    /// Convert Int16 PCM data to Float32 samples
    private func convertFromInt16PCM(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)

        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / Float(Int16.max)
            }
        }

        return samples
    }

    /// Simple linear resampling
    private func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = sourceSampleRate / targetSampleRate
        let outputLength = Int(Double(samples.count) / ratio)

        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let sourceIndex = Double(i) * ratio
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))

            if index + 1 < samples.count {
                output[i] = samples[index] * (1 - fraction) + samples[index + 1] * fraction
            } else if index < samples.count {
                output[i] = samples[index]
            }
        }

        return output
    }

    /// Create AVAudioPCMBuffer from Float32 samples
    private func createBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        // Copy samples to buffer
        for i in 0..<samples.count {
            channelData[0][i] = samples[i]
        }

        // If stereo, copy to second channel
        if format.channelCount == 2 {
            for i in 0..<samples.count {
                channelData[1][i] = samples[i]
            }
        }

        return buffer
    }
}

// MARK: - Errors

enum AudioPlaybackError: LocalizedError {
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "Failed to setup audio playback"
        }
    }
}
