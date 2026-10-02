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

    private init(provider: CloudVoiceProvider) {
        self.provider = provider
    }

    // MARK: - Speak

    /// Speak a whole reply, replacing anything playing.
    func speak(_ text: String) async {
        await speak(text, voice: provider.selectedVoice())
    }

    /// Speak in a specific voice — used to preview voices in Settings before choosing one.
    func speak(_ text: String, voice: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isReady else { return }
        stop()
        beginStreaming()
        for sentence in TextChunking.sentences(clean) { enqueue(sentence, voice: voice) }
        endStreaming()
    }

    func stop() {
        isSpeaking = false
        streaming = false
        streamStarted = false
        utteranceCancelled = true   // in-flight synthesis discards its output
        pendingSentences.removeAll()
        clipQueue.forEach { $0.cancel() }
        clipQueue.removeAll()
        pendingBuffers = 0
        playerEpoch += 1
        if audioReady { playerNode.stop() }
    }

    // MARK: - Streaming (speak sentences as the model produces them)

    private var streaming = false
    /// The first clip of an utterance restarts the player (clearing a previous reply); later ones
    /// append for gapless playback.
    private var streamStarted = false
    /// Synthesis tasks in sentence order, at most `maxInFlight` at a time (enough to stay ahead of
    /// playback without a 15-sentence reply firing 15 requests and tripping rate limits). ONE
    /// drainer awaits them in order, so playback order is structural.
    private var clipQueue: [Task<AVAudioPCMBuffer?, Never>] = []
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
            clipQueue.append(Task { await self.synthesize(next.text, voice: next.voice) })
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
            while let self, let task = self.clipQueue.first {
                let clip = await task.value
                // stop() (and maybe a new reply) may have replaced the queue while we waited —
                // only play the clip if it's still the head of the CURRENT utterance.
                guard self.clipQueue.first == task, !self.utteranceCancelled else { continue }
                self.clipQueue.removeFirst()
                self.startSynthesis()
                if let clip {
                    self.schedule(clip, restartPlayer: !self.streamStarted)
                    self.streamStarted = true
                }
            }
            guard let self else { return }
            self.drainTask = nil
            if !self.generationActive && self.outputDrained { self.isSpeaking = false }
        }
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
