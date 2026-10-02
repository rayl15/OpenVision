// OpenVision - KokoroTTSService.swift
// On-device neural TTS via the vendored Kokoro-82M (MLX). Natural, offline, private.
//
// Model + voices download from HuggingFace (prince-canuma/Kokoro-82M) on demand — the model is
// ~600 MB, each voice ~0.5 MB. Synthesis runs on-device via KokoroSwift; the 24 kHz float output
// is played through AVAudioEngine. Apple's AVSpeechSynthesizer TTS remains the untouched default.

import Foundation
import AVFoundation
import MLX
import KokoroSwift

@MainActor
final class KokoroTTSService: ObservableObject {

    static let shared = KokoroTTSService()

    // Kokoro outputs mono 24 kHz float samples.
    private let sampleRate: Double = 24000

    // MARK: - Storage

    private static let modelFile = "kokoro-v1_0.safetensors"
    private static let hfBase = "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main"

    /// Curated voices (a* = American, b* = British; first letter drives the Language).
    static let voices: [String] = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
        "am_michael", "am_adam", "am_onyx",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis"
    ]

    private var storageDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KokoroTTS", isDirectory: true)
    }
    private var modelURL: URL { storageDir.appendingPathComponent(Self.modelFile) }
    private func voiceURL(_ name: String) -> URL {
        storageDir.appendingPathComponent("voices", isDirectory: true).appendingPathComponent("\(name).safetensors")
    }

    /// Whether the main model is on disk.
    var isModelReady: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    /// True from the moment synthesis starts until playback finishes — mirrors TTSService.isSpeaking
    /// so VoiceAgentView can gate the recognizer/conversation state on it.
    @Published var isSpeaking = false

    // MARK: - Engine + playback

    private var engine: KokoroTTS?
    private var voiceCache: [String: MLXArray] = [:]

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioReady = false

    private init() {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    // MARK: - Download

    /// Download the ~600 MB Kokoro model (idempotent — skipped if present).
    func downloadModel(onProgress: @escaping (Double) -> Void) async throws {
        if isModelReady { onProgress(1); return }
        isDownloading = true
        defer { isDownloading = false }
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try await download(from: "\(Self.hfBase)/\(Self.modelFile)", to: modelURL) { [weak self] p in
            self?.downloadProgress = p
            onProgress(p)
        }
    }

    private func ensureVoice(_ name: String) async throws -> MLXArray {
        if let cached = voiceCache[name] { return cached }
        let url = voiceURL(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await download(from: "\(Self.hfBase)/voices/\(name).safetensors", to: url, onProgress: { _ in })
        }
        let arrays = try MLX.loadArrays(url: url)
        guard let voice = arrays["voice"] ?? arrays.values.first else {
            throw KokoroError.badVoice(name)
        }
        voiceCache[name] = voice
        return voice
    }

    private func ensureEngine() throws -> KokoroTTS {
        if let engine { return engine }
        guard isModelReady else { throw KokoroError.modelMissing }
        let e = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        engine = e
        return e
    }

    // MARK: - Speak

    /// Synthesize + play `text` in the given voice. Runs generation off the main actor.
    ///
    /// Synthesis is per-SENTENCE, not whole-reply: a single `generateAudio` pass allocates MLX
    /// memory proportional to text length, and a ~400-char reply spiked >1 GB — enough to jetsam
    /// the app when SmolVLM2 is resident (~6 GB ceiling; confirmed twice from the device's memory
    /// telemetry). Per-sentence generation bounds each spike, and the first sentence starts
    /// playing while the rest still synthesize, so long replies also START sooner.
    func speak(_ text: String, voice: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isModelReady else { return }
        isSpeaking = true   // set immediately so the UI pauses the recognizer during synthesis too
        generationActive = true
        utteranceGeneration += 1
        defer {
            generationActive = false
            if pendingBuffers <= 0 { isSpeaking = false }   // everything already played (or nothing to play)
        }
        do {
            let voiceArray = try await ensureVoice(voice)
            let tts = try ensureEngine()
            let language: Language = voice.first == "b" ? .enGB : .enUS
            var first = true
            for sentence in TextChunking.sentences(clean) {
                guard isSpeaking else { break }   // stop() was called mid-reply
                let samples: [Float] = try await Task.detached(priority: .userInitiated) {
                    let (audio, _) = try tts.generateAudio(voice: voiceArray, language: language, text: sentence)
                    return audio
                }.value
                guard isSpeaking else { break }
                if !samples.isEmpty {
                    enqueue(samples, restartPlayer: first)
                    first = false
                }
            }
        } catch {
            NSLog("[OV] Kokoro speak failed: %@", "\(error)")
            isSpeaking = false
        }
    }

    func stop() {
        isSpeaking = false          // breaks the per-sentence synthesis loop
        streaming = false
        streamStarted = false
        utteranceCancelled = true   // in-flight synthesis discards its output
        chunkQueue.removeAll()
        pendingBuffers = 0
        playerEpoch += 1
        if audioReady { playerNode.stop() }
    }

    // MARK: - Streaming (speak sentences as the model produces them)

    /// True between `beginStreaming()` and `endStreaming()`.
    private var streaming = false
    /// Whether any chunk has been enqueued in this streamed utterance — the first one restarts
    /// the player to clear a previous reply, later ones append for gapless playback.
    private var streamStarted = false
    /// Sentences waiting to be synthesised, in arrival order. Drained by exactly ONE task:
    /// callers previously spawned an independent Task per sentence, and those are unordered —
    /// sentence 2 could synthesise and play before sentence 1, and concurrent calls raced the
    /// `streamStarted` flag. A single drainer over a FIFO makes ordering structural.
    private var chunkQueue: [(text: String, voice: String)] = []
    private var drainTask: Task<Void, Never>?
    /// Set by stop() so in-flight synthesis discards its output. This must NOT be inferred from
    /// `streaming`/queue state: endStreaming() legitimately arrives while the FIRST sentence is
    /// still synthesising (generation often finishes before synthesis under GPU contention), and
    /// a state-based guard dropped that entire reply.
    private var utteranceCancelled = false

    /// True when nothing remains to synthesise OR play for the current utterance. `pendingBuffers`
    /// alone is not enough: a sentence can still be in synthesis (queue drained of BUFFERS but not
    /// of WORK), and clearing `isSpeaking` then would unpause the recognizer straight into the
    /// reply's own upcoming audio.
    private var outputDrained: Bool { chunkQueue.isEmpty && drainTask == nil && pendingBuffers <= 0 }

    /// Open a streamed utterance.
    ///
    /// Kokoro is non-autoregressive (StyleTTS2 + ISTFTNet), so there is no partial audio for a
    /// sentence still being synthesised — "streaming" here means the same thing every Kokoro
    /// wrapper means: synthesise sentence-by-sentence and play each as it lands. `speak(_:voice:)`
    /// already did that WITHIN a reply; what was missing is starting before the model has finished
    /// writing the reply. Measured cost of waiting: ~1.2s per turn.
    func beginStreaming() {
        streaming = true
        streamStarted = false
        chunkQueue.removeAll()
        utteranceCancelled = false
        generationActive = true
        utteranceGeneration += 1
        isSpeaking = true          // pauses the recognizer for the whole utterance
    }

    /// Queue ONE completed sentence for synthesis. Safe to call repeatedly while the language
    /// model is still generating; sentences play strictly in the order they were queued.
    func speakChunk(_ sentence: String, voice: String) {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isModelReady, streaming else { return }
        chunkQueue.append((clean, voice))
        drainIfNeeded()
    }

    /// Start the single drainer if it isn't running. The class is @MainActor, so queue mutations
    /// are serialised; the only suspension is the detached synthesis, during which new sentences
    /// append behind the one in flight.
    private func drainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while let self, !self.chunkQueue.isEmpty {
                let next = self.chunkQueue.removeFirst()
                await self.synthesizeAndEnqueue(text: next.text, voice: next.voice)
            }
            guard let self else { return }
            self.drainTask = nil
            // endStreaming may have fired while we were synthesising the tail.
            if !self.generationActive && self.outputDrained { self.isSpeaking = false }
        }
    }

    private func synthesizeAndEnqueue(text: String, voice: String) async {
        do {
            let voiceArray = try await ensureVoice(voice)
            let tts = try ensureEngine()
            let language: Language = voice.first == "b" ? .enGB : .enUS
            let samples: [Float] = try await Task.detached(priority: .userInitiated) {
                let (audio, _) = try tts.generateAudio(voice: voiceArray, language: language, text: text)
                return audio
            }.value
            guard !utteranceCancelled, !samples.isEmpty else { return }
            enqueue(samples, restartPlayer: !streamStarted)
            streamStarted = true
        } catch {
            NSLog("[OV] Kokoro speakChunk failed: %@", "\(error)")
        }
    }

    /// Close the streamed utterance: no more sentences are coming, but anything already queued
    /// still synthesises and plays. `isSpeaking` clears when output is fully drained — from the
    /// buffer-completion callback, or from the drainer if it finishes last.
    func endStreaming() {
        streaming = false
        generationActive = false
        if outputDrained { isSpeaking = false }
    }

    /// Ambient narration (watch loop): speaks ONLY into silence and never preempts.
    ///
    /// `speak(_:voice:)` is for replies — it restarts the player, cutting whatever is playing.
    /// A watch line doing that cut user replies off mid-sentence: the loop's guards passed while
    /// nothing was speaking, then a reply began during the line's 1–3s of synthesis, and the
    /// finished line stomped it. This path re-checks AFTER synthesis and drops itself if any real
    /// speech (streamed or not) started meanwhile — a dropped narration line costs nothing; the
    /// next scene change will describe again.
    func speakAmbient(_ text: String, voice: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isModelReady, !isSpeaking, !streaming else { return }
        isSpeaking = true          // pause the recognizer while narration synthesises + plays
        generationActive = true
        // This is a NEW utterance we now own: a leftover cancel flag from a previous stop()
        // would otherwise drop every ambient line until the next streamed reply reset it.
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
        do {
            let voiceArray = try await ensureVoice(voice)
            let tts = try ensureEngine()
            let language: Language = voice.first == "b" ? .enGB : .enUS
            let samples: [Float] = try await Task.detached(priority: .utility) {
                let (audio, _) = try tts.generateAudio(voice: voiceArray, language: language, text: clean)
                return audio
            }.value
            // A reply may have begun while we synthesised: beginStreaming sets `streaming`,
            // speak() restarts the player (utteranceCancelled/stop covers that route). Drop.
            guard isSpeaking, !streaming, !utteranceCancelled, !samples.isEmpty else { return }
            enqueue(samples, restartPlayer: false)   // append into silence; NEVER stop the player
        } catch {
            NSLog("[OV] Kokoro speakAmbient failed: %@", "\(error)")
        }
    }

    // MARK: - Playback (24 kHz mono float, sentence-queued)

    /// Buffers scheduled on the player that haven't finished playing yet. Combined with
    /// `generationActive` this decides when the whole reply is done: `isSpeaking` only clears
    /// once generation has finished AND the last queued sentence has played out.
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

    /// Queue one sentence's audio. `restartPlayer` is true for a reply's first sentence — it
    /// clears anything left from a previous (interrupted) reply; later sentences append to the
    /// player's queue so playback is gapless while synthesis runs ahead.
    private func enqueue(_ samples: [Float], restartPlayer: Bool) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        }
        do {
            if !audioReady {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
                // Forward what we play to the session recorder (cheap no-op when not recording):
                // the assistant's voice is mixed into demo recordings digitally, since the mic
                // path buries it under ambient noise.
                let tapFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
                audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, when in
                    SessionRecorder.shared.appendPlaybackAudio(buffer, at: when)
                }
                audioReady = true
            }
            if !audioEngine.isRunning { try audioEngine.start() }
            if restartPlayer {
                playerNode.stop()
                playerEpoch += 1
                pendingBuffers = 0
            }
            pendingBuffers += 1
            // .dataPlayedBack fires when the audio has actually finished playing (not just scheduled).
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self, epoch = playerEpoch] _ in
                Task { @MainActor in
                    guard let self, self.playerEpoch == epoch else { return }
                    self.pendingBuffers -= 1
                    if self.outputDrained && !self.generationActive {
                        self.isSpeaking = false
                    }
                }
            }
            playerNode.play()
            // Audio genuinely starts here (buffer scheduled + player running) — the counterpart
            // of AVSpeechSynthesizer's didStart. Kokoro synthesis time is the whole reason this
            // must NOT be marked at text hand-off: synthesis runs on the GPU alongside the model,
            // and marking early hid exactly that cost from perceived latency and TTS TTFB.
            // First-wins per turn; gated in the collector on the turn having requested TTS.
            MetricsCollector.shared.markFirstAudio()
        } catch {
            NSLog("[OV] Kokoro playback failed: %@", "\(error)")
            isSpeaking = false
        }
    }

    // MARK: - Storage management

    static func downloadedSizeBytes() -> Int64 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KokoroTTS", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func deleteModel() {
        engine = nil
        voiceCache.removeAll()
        MLX.GPU.clearCache()
        try? FileManager.default.removeItem(at: storageDir)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        downloadProgress = 0
    }

    // MARK: - Downloader

    private func download(from urlString: String, to dest: URL, onProgress: @escaping (Double) -> Void) async throws {
        guard let url = URL(string: urlString) else { throw KokoroError.badURL }
        let (tempURL, response) = try await URLSession.shared.download(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw KokoroError.download((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        onProgress(1)
    }

    enum KokoroError: LocalizedError {
        case modelMissing, badURL, badVoice(String), download(Int)
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "Kokoro model isn't downloaded yet."
            case .badURL: return "Invalid download URL."
            case .badVoice(let v): return "Couldn't load voice \(v)."
            case .download(let c): return "Download failed (HTTP \(c))."
            }
        }
    }
}
