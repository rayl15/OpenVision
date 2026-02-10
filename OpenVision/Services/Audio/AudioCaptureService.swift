// OpenVision - AudioCaptureService.swift
// Captures audio from microphone using AVAudioEngine

import AVFoundation

/// Captures audio from microphone
@MainActor
final class AudioCaptureService: ObservableObject {
    // MARK: - Published State

    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0

    // MARK: - Callbacks

    /// Called when audio data is captured (PCM Int16, mono)
    var onAudioCaptured: ((Data) -> Void)?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // MARK: - Audio Format

    /// Target sample rate for output
    var targetSampleRate: Double = Double(Constants.GeminiLive.inputSampleRate)

    /// Chunk duration in milliseconds
    var chunkDurationMs: Int = Constants.GeminiLive.audioChunkMs

    // MARK: - Buffering

    private var audioBuffer = Data()
    private var bufferLock = NSLock()

    /// Target buffer size in bytes (for chunking)
    private var targetBufferSize: Int {
        // PCM Int16, mono: 2 bytes per sample
        let samplesPerChunk = Int(targetSampleRate) * chunkDurationMs / 1000
        return samplesPerChunk * 2
    }

    // MARK: - Start/Stop

    /// Start capturing audio
    func startCapture() throws {
        guard !isCapturing else { return }

        audioEngine = AVAudioEngine()

        guard let engine = audioEngine else {
            throw AudioCaptureError.engineCreationFailed
        }

        inputNode = engine.inputNode

        guard let inputNode = inputNode else {
            throw AudioCaptureError.inputNodeUnavailable
        }

        // Get native format
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioCapture] Native format: \(nativeFormat)")

        // Install tap in native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, nativeFormat: nativeFormat)
        }

        try engine.start()
        isCapturing = true
        print("[AudioCapture] Started capturing")
    }

    /// Stop capturing audio
    func stopCapture() {
        guard isCapturing else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil

        // Flush remaining buffer
        flushBuffer()

        isCapturing = false
        print("[AudioCapture] Stopped capturing")
    }

    // MARK: - Audio Processing

    /// Process audio buffer from tap
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, nativeFormat: AVAudioFormat) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(nativeFormat.channelCount)

        // Convert to mono Float32
        var monoSamples = [Float](repeating: 0, count: frameCount)

        if channelCount == 1 {
            // Already mono
            monoSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        } else {
            // Mix to mono
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatData[ch][i]
                }
                monoSamples[i] = sum / Float(channelCount)
            }
        }

        // Calculate audio level
        let rms = sqrt(monoSamples.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        Task { @MainActor in
            self.audioLevel = rms
        }

        // Resample if needed
        let resampledSamples: [Float]
        if nativeFormat.sampleRate != targetSampleRate {
            resampledSamples = resample(monoSamples, from: nativeFormat.sampleRate, to: targetSampleRate)
        } else {
            resampledSamples = monoSamples
        }

        // Convert Float32 to Int16 PCM
        let pcmData = convertToInt16PCM(resampledSamples)

        // Add to buffer
        bufferLock.lock()
        audioBuffer.append(pcmData)

        // Send chunks when buffer is full
        while audioBuffer.count >= targetBufferSize {
            let chunk = audioBuffer.prefix(targetBufferSize)
            audioBuffer.removeFirst(targetBufferSize)
            bufferLock.unlock()

            Task { @MainActor in
                self.onAudioCaptured?(Data(chunk))
            }

            bufferLock.lock()
        }
        bufferLock.unlock()
    }

    /// Flush remaining audio buffer
    private func flushBuffer() {
        bufferLock.lock()
        if !audioBuffer.isEmpty {
            let remaining = audioBuffer
            audioBuffer.removeAll()
            bufferLock.unlock()

            Task { @MainActor in
                self.onAudioCaptured?(remaining)
            }
        } else {
            bufferLock.unlock()
        }
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

    /// Convert Float32 samples to Int16 PCM data
    private func convertToInt16PCM(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)

        for sample in samples {
            // Clamp to [-1, 1] and scale to Int16 range
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: scaled.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case engineCreationFailed
    case inputNodeUnavailable

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input node unavailable"
        }
    }
}
