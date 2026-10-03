// OpenVision - CloudTTSService.swift
// Cloud neural voices: xAI Grok (SuperGrok or xAI API key) and OpenAI (API key).
//
// Both APIs return a whole clip per request (~1s for a 4s sentence), so — like Kokoro — replies
// are spoken sentence by sentence. Unlike Kokoro there's no GPU to share, so sentences are
// synthesized in PARALLEL as they arrive and played strictly in order. Clips are requested as WAV
// and played through AVAudioEngine (not AVAudioPlayer) so consecutive sentences queue gaplessly
// and the voice is mixed into session recordings the same way Kokoro's is.
//
// The engine is provider-agnostic; a CloudVoiceProvider only says whether it can speak, which
// voice is selected, and how to turn one sentence into WAV bytes.
//
// A sentence whose request fails (a 429, a timeout, no network) is spoken in the Apple voice in
// its place in the queue, so the reply has no silent hole. After two failures in a row the rest
// of the reply goes to the Apple voice outright rather than alternating per sentence.

import AVFoundation
import Foundation

/// Where and how one cloud TTS provider synthesizes a sentence.
struct CloudVoiceProvider {
    /// Log tag.
    let name: String
    let isReady: @MainActor () -> Bool
    let selectedVoice: @MainActor () -> String
    /// One sentence in `voice` → WAV bytes (plus the HTTP response, for the status code).
    let synthesize: @MainActor (_ text: String, _ voice: String) async throws -> (Data, URLResponse)
}

@MainActor
final class CloudTTSService: ObservableObject {

    static let grok = CloudTTSService(provider: .grok)
    static let openAI = CloudTTSService(provider: .openAI)

    @Published var isSpeaking = false
    /// Why the last sentence couldn't be synthesized (bad key, no credits, offline) — shown in the
    /// voice list so a failed sample isn't just silence. Cleared when a new utterance starts.
    @Published private(set) var lastFailure: String?

    let provider: CloudVoiceProvider

    /// Whether the provider's credential is configured; no download needed.
    var isReady: Bool { provider.isReady() }

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioReady = false
    /// The format the player node is connected with (the first clip's, normally 24 kHz mono).
    private var playerFormat: AVAudioFormat?

    /// Speaks failed sentences. Its own synthesizer, not TTSService: the voice agent reads
    /// TTSService finishing as the end of the reply.
    private let fallback = AppleFallbackSpeaker()
    /// Whether the current utterance falls back to the Apple voice (replies yes, voice previews
    /// no: a failed preview shows `lastFailure` instead).
    private var fallbackEnabled = true
    /// Failed sentences in a row; at two, the rest of the reply uses the Apple voice.
    private var consecutiveFailures = 0
    private var appleForRest = false
    /// Test hook: each sentence as it starts playing, and whether it's in the Apple voice.
    var onSentenceStarted: ((_ sentence: String, _ appleVoice: Bool) -> Void)?
    /// Test hook: how many sentences the Apple voice has actually been asked to speak.
    var fallbackUtterances: Int { fallback.utterances }

    init(provider: CloudVoiceProvider) {
        self.provider = provider
    }

    // MARK: - Speak

    /// Speak a whole reply, replacing anything playing.
    func speak(_ text: String) async {
        await speak(text, voice: provider.selectedVoice(), appleFallback: true)
    }

    /// Speak in a specific voice — used to preview voices in Settings before choosing one.
    func speak(_ text: String, voice: String, appleFallback: Bool = false) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isReady else { return }
        stop()
        beginStreaming()
        fallbackEnabled = appleFallback
        for sentence in TextChunking.sentences(clean) { enqueue(sentence, voice: voice) }
        endStreaming()
    }

    func stop() {
        isSpeaking = false
        streaming = false
        streamStarted = false
        utteranceCancelled = true   // in-flight synthesis discards its output
        pendingSentences.removeAll()
        clipQueue.forEach { $0.clip.cancel() }
        clipQueue.removeAll()
        pendingBuffers = 0
        playerEpoch += 1
        if audioReady { playerNode.stop() }
        fallback.stop()
    }

    // MARK: - Streaming (speak sentences as the model produces them)

    private var streaming = false
    /// The first clip of an utterance restarts the player (clearing a previous reply); later ones
    /// append for gapless playback.
    private var streamStarted = false
    /// Synthesis tasks in sentence order, at most `maxInFlight` at a time (enough to stay ahead of
    /// playback without a 15-sentence reply firing 15 requests and tripping rate limits). ONE
    /// drainer awaits them in order, so playback order is structural.
    private var clipQueue: [(text: String, clip: Task<AVAudioPCMBuffer?, Never>)] = []
    /// Sentences waiting for a synthesis slot.
    private var pendingSentences: [(text: String, voice: String)] = []
    private let maxInFlight = 3
    /// Per-clip ceiling. The drainer waits on the head clip, so a stalled request holds the whole
    /// reply (recognizer paused); one sentence never needs more than this.
    nonisolated static let clipTimeout: TimeInterval = 10
    private var drainTask: Task<Void, Never>?
    /// Set by stop() so in-flight synthesis discards its output.
    private var utteranceCancelled = false
    private var pendingBuffers = 0
    private var generationActive = false
    /// Bumped by every new utterance, so ambient narration can tell whether it still owns the
    /// generation state when its synthesis finishes.
    private var utteranceGeneration = 0
    /// Bumped whenever the player is stopped. AVAudioPlayerNode also fires a buffer's completion
    /// handler when stop() discards it, and those handlers run later on the main actor; without
    /// this they'd decrement `pendingBuffers` for the NEXT utterance and clear `isSpeaking` while
    /// it's still playing (letting the assistant's own audio trigger barge-in).
    private var playerEpoch = 0

    /// Nothing left to synthesize or play for the current utterance.
    private var outputDrained: Bool {
        clipQueue.isEmpty && pendingSentences.isEmpty && drainTask == nil && pendingBuffers <= 0
    }

    func beginStreaming() {
        lastFailure = nil
        streaming = true
        streamStarted = false
        clipQueue.removeAll()
        pendingSentences.removeAll()
        utteranceCancelled = false
        generationActive = true
        utteranceGeneration += 1
        fallbackEnabled = true
        consecutiveFailures = 0
        appleForRest = false
        isSpeaking = true          // pauses the recognizer for the whole utterance
    }

    func speakChunk(_ sentence: String) {
        enqueue(sentence, voice: provider.selectedVoice())
    }

    private func enqueue(_ sentence: String, voice: String) {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isReady, streaming else { return }
        pendingSentences.append((clean, voice))
        startSynthesis()
        drainIfNeeded()
    }

    /// Move waiting sentences into synthesis while there's a free slot.
    private func startSynthesis() {
        while clipQueue.count < maxInFlight, !pendingSentences.isEmpty {
            let next = pendingSentences.removeFirst()
            // Once the reply has moved to the Apple voice, don't request it from the cloud.
            let skip = appleForRest
            clipQueue.append((next.text, Task { skip ? nil : await self.synthesize(next.text, voice: next.voice) }))
        }
    }

    func endStreaming() {
        streaming = false
        generationActive = false
        if outputDrained { isSpeaking = false }
    }

    private func drainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while let self, let head = self.clipQueue.first {
                let clip = await head.clip.value
                // stop() (and maybe a new reply) may have replaced the queue while we waited —
                // only play the clip if it's still the head of the CURRENT utterance.
                guard self.clipQueue.first?.clip == head.clip, !self.utteranceCancelled else { continue }
                self.clipQueue.removeFirst()
                let useCloud = clip != nil && !self.appleForRest
                // Count the failure before refilling the queue, so a second failure in a row
                // keeps the next sentence from being sent to the cloud.
                if useCloud { self.consecutiveFailures = 0 } else if self.fallbackEnabled { self.noteFailure() }
                self.startSynthesis()
                if let clip, useCloud {
                    self.onSentenceStarted?(head.text, false)
                    guard !self.utteranceCancelled else { continue }
                    self.schedule(clip, restartPlayer: !self.streamStarted)
                    self.streamStarted = true
                } else if self.fallbackEnabled {
                    await self.speakWithAppleVoice(head.text)
                }
            }
            guard let self else { return }
            self.drainTask = nil
            if !self.generationActive && self.outputDrained { self.isSpeaking = false }
        }
    }

    /// Speak a sentence the cloud couldn't synthesize, in its place: after the clips queued before
    /// it have played out, and before the next one. The drainer waits here, so the two audio
    /// paths never overlap and `isSpeaking` stays true throughout.
    private func speakWithAppleVoice(_ sentence: String) async {
        // A stop, then a new reply, can happen during the wait: only speak for this one.
        let generation = utteranceGeneration
        var current: Bool { !utteranceCancelled && utteranceGeneration == generation }
        while pendingBuffers > 0 && current {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard current else { return }
        onSentenceStarted?(sentence, true)
        guard current else { return }
        MetricsCollector.shared.markFirstAudio()
        await fallback.speak(sentence)
    }

    private func noteFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= 2, !appleForRest else { return }
        // Probably offline: stop asking the cloud for the rest of this reply.
        NSLog("[%@] two sentences failed in a row, using the Apple voice for the rest", provider.name)
        appleForRest = true
        clipQueue.forEach { $0.clip.cancel() }   // requests already out come back as failures
    }

    /// Ambient narration (watch loop): speaks only into silence and drops itself if a reply
    /// started while it was being synthesized.
    func speakAmbient(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isReady, !isSpeaking, !streaming else { return }
        isSpeaking = true
        generationActive = true
        utteranceCancelled = false
        utteranceGeneration += 1
        let ownGeneration = utteranceGeneration
        defer {
            // A reply that started during synthesis owns generationActive now; resetting it here
            // would let isSpeaking clear mid-reply.
            if utteranceGeneration == ownGeneration {
                generationActive = false
                if outputDrained { isSpeaking = false }
            }
        }
        guard let clip = await synthesize(clean, voice: provider.selectedVoice()),
              isSpeaking, !streaming, !utteranceCancelled else { return }
        schedule(clip, restartPlayer: false)   // append into silence; never stop the player
    }

    // MARK: - Synthesis

    /// One sentence → decoded PCM, or nil on failure (logged; the rest of the reply still plays).
    private func synthesize(_ text: String, voice: String) async -> AVAudioPCMBuffer? {
        do {
            let (data, response) = try await provider.synthesize(text, voice)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = CloudChat.errorMessage(from: data)
                    ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                NSLog("[%@] request failed: %@", provider.name, message)
                lastFailure = message
                return nil
            }
            return try Self.decodeWAV(data)
        } catch {
            // stop() cancels in-flight requests; URLSession reports that as URLError(.cancelled),
            // not CancellationError. That's a barge-in, not a failure, and recording it would
            // pin an error on the next reply.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return nil
            }
            NSLog("[%@] synthesis failed: %@", provider.name, "\(error)")
            lastFailure = error.localizedDescription
            return nil
        }
    }

    /// WAV bytes → a float PCM buffer in the file's own format (24 kHz mono from both providers).
    nonisolated static func decodeWAV(_ data: Data) throws -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-tts-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        return buffer.frameLength > 0 ? buffer : nil
    }

    // MARK: - Playback

    private func schedule(_ buffer: AVAudioPCMBuffer, restartPlayer: Bool) {
        do {
            if !audioReady {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: buffer.format)
                // Forward what we play to the session recorder (cheap no-op when not recording),
                // matching Kokoro: the assistant's voice is mixed into demo recordings digitally.
                let tapFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
                audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, when in
                    SessionRecorder.shared.appendPlaybackAudio(buffer, at: when)
                }
                audioReady = true
                playerFormat = buffer.format
            } else if let playerFormat, buffer.format != playerFormat {
                // A provider changed sample rate or channels: reconnect for the new format rather
                // than play this clip at the wrong speed. Anything still queued is dropped.
                playerNode.stop()
                playerEpoch += 1
                pendingBuffers = 0
                audioEngine.disconnectNodeOutput(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: buffer.format)
                self.playerFormat = buffer.format
            }
            if !audioEngine.isRunning { try audioEngine.start() }
            if restartPlayer {
                playerNode.stop()
                playerEpoch += 1
                pendingBuffers = 0
            }
            pendingBuffers += 1
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self, epoch = playerEpoch] _ in
                Task { @MainActor in
                    guard let self, self.playerEpoch == epoch else { return }
                    self.pendingBuffers -= 1
                    if self.outputDrained && !self.generationActive { self.isSpeaking = false }
                }
            }
            playerNode.play()
            // Audio genuinely starts here — network synthesis time stays inside perceived latency.
            MetricsCollector.shared.markFirstAudio()
        } catch {
            NSLog("[%@] playback failed: %@", provider.name, "\(error)")
            isSpeaking = false
        }
    }
}

extension CloudTTSService: NeuralSpeechEngine {}

// MARK: - Apple voice fallback

/// Speaks one sentence in the user's Apple voice and returns when it has finished or been stopped.
@MainActor
final class AppleFallbackSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being spoken and its waiter. A stopped utterance reports didCancel later,
    /// so callbacks only finish the utterance they're about.
    private var current: (id: ObjectIdentifier, finished: CheckedContinuation<Void, Never>)?
    private(set) var utterances = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: sentence)
        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterances += 1
        await withCheckedContinuation { continuation in
            current = (ObjectIdentifier(utterance), continuation)
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        if let current { finish(current.id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        guard let current, current.id == id else { return }
        self.current = nil
        current.finished.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }
}

// MARK: - Voices

struct CloudVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let gender: String
}

// MARK: - Grok (xAI)

extension CloudVoiceProvider {
    static let grok = CloudVoiceProvider(
        name: "GrokTTS",
        isReady: { SettingsManager.shared.settings.isGrokConfigured },
        selectedVoice: {
            let voice = SettingsManager.shared.settings.grokVoice
            return voice.isEmpty ? CloudTTSService.grokDefaultVoice : voice
        },
        synthesize: { text, voice in
            let body = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "voice_id": voice,
                // Follows the reply's language, so multilingual answers sound native.
                "language": "auto",
                "output_format": ["codec": "wav"],
            ])
            return try await GrokService.send(retryTransient: false) { bearer in
                var request = URLRequest(url: URL(string: "\(GrokService.baseURL)/tts")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = CloudTTSService.clipTimeout
                return request
            }
        }
    )
}

extension CloudTTSService {
    nonisolated static let grokDefaultVoice = "ara"

    /// xAI's voice list (28 multilingual voices at the time of writing).
    static func fetchGrokVoices() async throws -> [CloudVoice] {
        let (data, response) = try await GrokService.send { bearer in
            var request = URLRequest(url: URL(string: "\(GrokService.baseURL)/tts/voices")!)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            return request
        }
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
            throw CloudChatError.api("Grok", CloudChat.errorMessage(from: data) ?? "couldn't load voices")
        }
        return parseGrokVoices(data)
    }

    nonisolated static func parseGrokVoices(_ data: Data) -> [CloudVoice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = json["voices"] as? [[String: Any]] else { return [] }
        return voices.compactMap { v in
            guard let id = v["voice_id"] as? String else { return nil }
            return CloudVoice(id: id, name: v["name"] as? String ?? id, gender: v["gender"] as? String ?? "")
        }
    }
}

// MARK: - OpenAI

extension CloudVoiceProvider {
    /// OpenAI's speech endpoint needs API credits — a ChatGPT subscription token is recognised
    /// but refused ("no credits remaining"), so this requires the API-key sign-in.
    static let openAI = CloudVoiceProvider(
        name: "OpenAITTS",
        isReady: { SettingsManager.shared.settings.isOpenAIAPIAvailable },
        selectedVoice: {
            let voice = SettingsManager.shared.settings.openAITTSVoice
            return voice.isEmpty ? CloudTTSService.openAIDefaultVoice : voice
        },
        synthesize: { text, voice in
            let settings = SettingsManager.shared.settings
            guard let url = URL(string: "\(settings.openAIBaseURL)/audio/speech") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": CloudTTSService.openAITTSModel,
                "input": text,
                "voice": voice,
                "response_format": "wav",
            ])
            request.timeoutInterval = CloudTTSService.clipTimeout
            return try await URLSession.shared.data(for: request)
        }
    )
}

extension CloudTTSService {
    nonisolated static let openAITTSModel = "gpt-4o-mini-tts"
    nonisolated static let openAIDefaultVoice = "coral"

    /// OpenAI's built-in speech voices (the API has no list endpoint).
    nonisolated static let openAIVoices: [CloudVoice] = [
        "alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse",
    ].map { CloudVoice(id: $0, name: $0.capitalized, gender: "") }
}
