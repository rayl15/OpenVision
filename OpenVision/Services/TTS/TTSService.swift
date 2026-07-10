// OpenVision - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer

import AVFoundation
import Foundation

/// Text-to-speech service for OpenClaw mode
@MainActor
final class TTSService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = TTSService()

    // MARK: - Published State

    @Published var isSpeaking: Bool = false

    // MARK: - Callbacks

    /// Called when speech starts
    var onSpeechStarted: (() -> Void)?

    /// Called when speech ends
    var onSpeechEnded: (() -> Void)?

    // MARK: - Speech Synthesizer

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Streaming state

    /// Utterances enqueued but not yet finished. `isSpeaking` only drops to false when this
    /// hits 0 AND no more chunks are coming — so it doesn't flap between queued sentences.
    private var pendingUtterances = 0

    /// True while a streamed reply is still being fed sentence-by-sentence. Keeps `isSpeaking`
    /// latched even if the audio queue momentarily drains faster than the LLM produces text.
    private var streamingActive = false

    // MARK: - Voice Selection

    private var selectedVoice: AVSpeechSynthesisVoice? {
        // Check if user has selected a specific voice
        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }

        // Fall back to default English voice
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Get all available voices for a language
    static func availableVoices(for languageCode: String = "en") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
            .sorted { v1, v2 in
                // Sort by quality (premium first), then by name
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    /// Get display name for a voice quality
    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// Speak text (single-shot: replaces anything currently playing).
    func speak(_ text: String) {
        stop()
        enqueue(text)
    }

    // MARK: - Streaming (sentence-by-sentence)

    /// Begin a streamed reply. Clears the queue and latches `isSpeaking` true so the recognizer
    /// stays paused across the gaps between sentences while the LLM is still generating.
    func beginStreaming() {
        stop()
        streamingActive = true
        isSpeaking = true
        onSpeechStarted?()
    }

    /// Enqueue one sentence without interrupting what's already queued. AVSpeechSynthesizer plays
    /// queued utterances back-to-back, so this pipelines speech behind the LLM as it streams.
    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    /// Signal that no more sentences are coming. Releases the latch once the queue drains.
    func endStreaming() {
        streamingActive = false
        if pendingUtterances == 0 {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    /// Build an utterance with the selected voice and hand it to the synthesizer's queue.
    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        pendingUtterances += 1
        synthesizer.speak(utterance)
    }

    /// Stop speaking and clear the queue.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        streamingActive = false
        pendingUtterances = 0
        isSpeaking = false
    }

    /// Pause speaking
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Continue speaking
    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStarted?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            // Only truly "done" when the queue is empty AND no more sentences are coming.
            if self.pendingUtterances == 0 && !self.streamingActive {
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 {
                self.streamingActive = false
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }
}
