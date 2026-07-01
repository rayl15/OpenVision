// OpenVision - GemmaLocalService.swift
// On-device Gemma 4 backend (text tier) running via Apple MLX.
//
// Conforms to the same backend shape as OpenClawService / GeminiLiveService:
// `.shared` singleton, @MainActor, AIConnectionState, callbacks (not Combine for events),
// connect()/disconnect()/sendMessage(). "Connect" loads the model into memory; "disconnect"
// unloads it. Selection is a manual knob (Settings → AI Backend → Local (Gemma 4)).
//
// Uses the native Gemma 4 VLM in mlx-swift-lm 3.31.3 (registered in VLMModelFactory as
// "gemma4"), which handles BOTH text and vision — so "what's this?" with a glasses photo
// runs fully on-device. No custom model port or pixel preprocessing needed: images go in
// via UserInput / Chat.Message and the model's processor handles the rest.
//
// NOTE: Requires iOS 18+ and a physical device (MLX is unavailable on the Simulator).

import Foundation
import UIKit            // UIApplication.applicationState — GPU inference is forbidden in background
import MLX
import MLXVLM            // Gemma 4 model (loaded via VLMModelFactory; used text-only here)
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader() / #huggingFaceTokenizerLoader() macros
import HuggingFace      // the macros expand to HuggingFace.HubClient …
import Tokenizers       // … and Tokenizers.AutoTokenizer

// MARK: - Selectable on-device models

/// The Gemma 4 edge models we expose in the model manager.
/// Repo ids match the validated `mlx-community` snapshots (note E2B's capitalised id).
enum GemmaLocalModel: String, CaseIterable, Identifiable, Codable {
    case e2b
    case e4b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e2b: return "Gemma 4 E2B"
        case .e4b: return "Gemma 4 E4B"
        }
    }

    /// HuggingFace repo id of the 4-bit MLX snapshot.
    var modelId: String {
        switch self {
        case .e2b: return "mlx-community/gemma-4-E2B-it-4bit"
        case .e4b: return "mlx-community/gemma-4-e4b-it-4bit"
        }
    }

    var detail: String {
        switch self {
        case .e2b: return "2B params • ~3.6 GB • fastest"
        case .e4b: return "4B params • ~5.2 GB • smarter"
        }
    }

    static func from(modelId: String) -> GemmaLocalModel {
        allCases.first { $0.modelId == modelId } ?? .e2b
    }
}

@MainActor
final class GemmaLocalService: ObservableObject {

    static let shared = GemmaLocalService()
    private init() {}

    // MARK: - Published state

    @Published var connectionState: AIConnectionState = .disconnected {
        didSet { onConnectionStateChanged?(connectionState) }
    }
    @Published var isProcessing: Bool = false
    @Published var isModelLoaded: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var lastError: String?

    // MARK: - Callbacks (mirror OpenClawService)

    /// Full assistant reply, delivered once generation completes.
    var onAgentMessage: ((String) -> Void)?
    /// Optional incremental tokens for live transcript display.
    var onPartialResponse: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - MLX state

    private var modelContainer: ModelContainer?
    private var loadedModelId: String?
    private var cancelRequested = false
    private var generationID = 0   // bumped per request; stale generations stay silent
    private var enteredBackgroundDuringGeneration = false

    // mlx-swift-lm 3.31.3 ships a native Gemma 4 VLM (text + vision) registered in
    // VLMModelFactory, so no custom model registration is needed.

    // MARK: - Download (model manager)

    /// Download a model snapshot to disk (idempotent — skipped if already cached).
    func download(_ model: GemmaLocalModel, onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        let configuration = ModelConfiguration(id: model.modelId)
        // loadContainer fetches the snapshot if missing; reuse it as the download path.
        _ = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress.fractionCompleted
                    onProgress(progress.fractionCompleted)
                }
            }
        )
        downloadProgress = 1
    }

    // MARK: - Connect / disconnect (load / unload)

    /// Load the selected model into memory. Throws if it hasn't been downloaded yet
    /// (we don't want a multi-GB download to kick off silently on a "connect").
    func connect(modelId: String) async throws {
        print("[GemmaLocal] connect(\(modelId)) — already loaded: \(loadedModelId == modelId && modelContainer != nil)")
        if loadedModelId == modelId, modelContainer != nil {
            setState(.connected); return
        }
        // Loading materializes model weights on the GPU (Metal), which iOS forbids in the
        // background — doing so raises an uncatchable exception that kills the app.
        guard UIApplication.shared.applicationState != .background else {
            throw GemmaLocalError.backgrounded
        }
        setState(.connecting)
        isProcessing = false

        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            print("[GemmaLocal] loading container…")
            let configuration = ModelConfiguration(id: modelId)
            let container = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress.fractionCompleted }
                }
            )
            modelContainer = container
            loadedModelId = modelId
            isModelLoaded = true
            setState(.connected)
            print("[GemmaLocal] ✓ model loaded, connected")
        } catch {
            print("[GemmaLocal] ✗ load failed: \(error)")
            lastError = error.localizedDescription
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    func disconnect() async {
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        isProcessing = false
        setState(.disconnected)
        onDisconnected?()
    }

    // MARK: - Generation

    /// Send a prompt and return the full reply via `onAgentMessage`. When `imageData` is provided
    /// (a glasses photo), it's passed to the Gemma 4 VLM so it can answer "what's this?" on-device.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        NSLog("[OV] GemmaLocal sendMessage: \"%@\" — loaded: %@, image: %d bytes", text, modelContainer != nil ? "yes" : "no", imageData?.count ?? 0)
        guard let container = modelContainer else {
            print("[GemmaLocal] ✗ model NOT loaded — throwing")
            throw GemmaLocalError.modelNotLoaded
        }
        // Per-token GPU work crashes (uncatchably) if the app is in the background. Refuse early.
        guard UIApplication.shared.applicationState != .background else {
            throw GemmaLocalError.backgrounded
        }
        setProcessing(true)
        cancelRequested = false
        defer { setProcessing(false) }

        // Local Gemma is TEXT-ONLY for stability. On-device vision (encoding an image) pushed
        // memory to the ~6GB jetsam limit and crashed; photo commands route to the cloud
        // backend instead. `imageData` is intentionally ignored here.

        // Keep replies short — this is spoken aloud on glasses, so long answers get tiresome
        // (and the TTS cuts off after ~a minute). Aim for a couple of natural sentences.
        let brevity = "You are a hands-free voice assistant for smart glasses. Reply in 2–4 natural sentences — enough detail to be genuinely useful and give a real sense of things, but brief enough to hear comfortably (around 20–30 seconds). Be specific and concrete, not vague. No lists, no markdown, no preamble; just answer."
        let userSys = SettingsManager.shared.settings.userPrompt
        let systemContent = userSys.isEmpty ? brevity : "\(userSys)\n\n\(brevity)"

        var chat: [Chat.Message] = []
        chat.append(.init(role: .system, content: systemContent))
        chat.append(.init(role: .user, content: text))
        let userInput = UserInput(chat: chat)

        // Tag this generation. If a newer request starts, older ones stop and stay silent —
        // prevents a stale reply (e.g. a previous photo's description) bleeding into a new answer.
        generationID &+= 1
        let myID = generationID

        // Watch for the app backgrounding mid-generation — the next per-token Metal eval would
        // crash uncatchably, so we stop before it (OpenGlasses' pattern).
        enteredBackgroundDuringGeneration = false
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackgroundDuringGeneration = true }
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        NSLog("[OV] GemmaLocal: starting generation…")
        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            // Cap output length — spoken aloud, so keep it to a few sentences (~30s of speech).
            let parameters = GenerateParameters(maxTokens: 170, temperature: 0.4)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var full = ""
        var tokenCount = 0
        // Drive the iterator manually so we can bail BEFORE requesting the next token (i.e.
        // before MLX submits the next Metal command buffer) when the app is backgrounded.
        var iterator = stream.makeAsyncIterator()
        while true {
            if cancelRequested || myID != generationID { break }
            if enteredBackgroundDuringGeneration || UIApplication.shared.applicationState == .background {
                NSLog("[OV] GemmaLocal: backgrounded mid-generation — stopping")
                break
            }
            guard let item = await iterator.next() else { break }
            if case .chunk(let piece) = item {
                full += piece
                tokenCount += 1
                if tokenCount == 1 { NSLog("[OV] GemmaLocal: first token received") }
                let snapshot = full
                await MainActor.run { self.onPartialResponse?(snapshot) }
            }
        }
        NSLog("[OV] GemmaLocal: generation done — %d chunks, %d chars", tokenCount, full.count)

        // Release the MLX buffer cache so vision memory doesn't pile up toward the jetsam limit.
        Memory.clearCache()

        let reply = full
        if !cancelRequested && myID == generationID {
            await MainActor.run { self.onAgentMessage?(reply) }
        }
    }

    /// Barge-in: stop streaming the current reply as soon as possible.
    func interrupt() {
        cancelRequested = true
        setProcessing(false)
    }

    // MARK: - Agentic intent routing

    struct FaceIntent {
        let action: String   // "remember" | "identify" | "forget" | "list"
        let name: String     // person's name (may be empty for identify/list)
    }

    /// Use the on-device model to decide whether a spoken command is a face-recognition request,
    /// and extract the action + name — no keyword matching. Returns nil if the model isn't loaded
    /// or the command isn't about people/faces.
    func classifyFaceIntent(_ command: String) async -> FaceIntent? {
        guard modelContainer != nil else { return nil }
        let system = "You are an intent router for smart glasses that can recognize faces. Output ONLY compact JSON, nothing else."
        let user = """
        The user said: "\(command)"

        Decide which action they want (looking at a person through the glasses):
        - "remember": save the face of the person in view under a name they provided
        - "identify": tell them who the person in view is
        - "forget": remove a previously saved person by name
        - "list": list the people already known
        - "none": the command is NOT about recognizing, remembering, or naming a person

        Reply ONLY as JSON: {"action":"remember|identify|forget|list|none","name":"<the person's name if they said one, otherwise empty>"}
        """
        let messages: [Chat.Message] = [
            .init(role: .system, content: system),
            .init(role: .user, content: user)
        ]
        guard let output = try? await rawGenerate(messages: messages, maxTokens: 60, temperature: 0.0) else {
            return nil
        }
        NSLog("[OV] classifyFaceIntent(\"%@\") -> %@", command, output)
        // Extract the first {...} JSON object from the output.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (obj["action"] as? String)?.lowercased(),
              ["remember", "identify", "forget", "list"].contains(action) else {
            return nil
        }
        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FaceIntent(action: action, name: name)
    }

    enum RouteResult {
        case face(FaceIntent)
        case webSearch(String)   // search query
        case answer(String)
    }

    /// ONE generation that either routes a face command OR answers normally. This replaces the
    /// classify-then-answer pair (two generations), which doubled peak memory and tipped the app
    /// over the 6GB jetsam limit. Still fully agentic — the model decides.
    func routeCommand(_ command: String) async -> RouteResult {
        let system = """
        You are a voice assistant for smart glasses that can recognize faces the user has taught you. The glasses camera can see whoever is in front of the user — you do NOT need them to show you anyone.

        If the user wants a face action, reply with ONLY one JSON object and nothing else (the app will take the photo):
        - Identify / name the person in view: {"face":"identify","name":""}
        - Save/remember the person under a name: {"face":"remember","name":"THE_NAME"}
        - Forget a saved person: {"face":"forget","name":"THE_NAME"}
        - List the people you know: {"face":"list","name":""}

        Examples:
        User: who is this → {"face":"identify","name":""}
        User: who is he → {"face":"identify","name":""}
        User: who is she → {"face":"identify","name":""}
        User: who am I looking at → {"face":"identify","name":""}
        User: do you know this person → {"face":"identify","name":""}
        User: remember this is Sara → {"face":"remember","name":"Sara"}
        User: her name is Priya → {"face":"remember","name":"Priya"}
        User: save his face as Alex → {"face":"remember","name":"Alex"}
        User: forget Sara → {"face":"forget","name":"Sara"}
        User: who do you know → {"face":"list","name":""}

        If the user asks about current or real-time information you can't be sure of — news, weather, sports scores, prices, who currently holds a role, recent events, or anything after your training — reply with ONLY: {"tool":"web_search","query":"A_CONCISE_SEARCH_QUERY"}
        User: what's the weather in Tokyo → {"tool":"web_search","query":"weather in Tokyo"}
        User: who won the game last night → {"tool":"web_search","query":"latest game result"}
        User: what's the price of bitcoin → {"tool":"web_search","query":"bitcoin price"}

        For anything else you already know (general questions, chat, facts, math), just answer helpfully in 1-3 short sentences. Do NOT mention faces, tools, or JSON.
        """
        let messages: [Chat.Message] = [
            .init(role: .system, content: system),
            .init(role: .user, content: command)
        ]
        guard let output = try? await rawGenerate(messages: messages, maxTokens: 200, temperature: 0.3) else {
            return .answer("Sorry, I couldn't process that — please try again.")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[OV] routeCommand(\"%@\") -> %@", command, String(trimmed.prefix(120)))
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
           let data = String(trimmed[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let action = (obj["face"] as? String)?.lowercased(),
               ["remember", "identify", "forget", "list"].contains(action) {
                let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .face(FaceIntent(action: action, name: name))
            }
            if (obj["tool"] as? String)?.lowercased() == "web_search",
               let query = (obj["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                return .webSearch(query)
            }
        }
        return .answer(trimmed)
    }

    /// Phrase a concise spoken answer to `question` using a web-search `result`. Falls back to the
    /// model's own knowledge (flagged as uncertain) when the result is empty.
    func answerWithSearchResult(question: String, result: String) async -> String {
        let system = """
        You are a voice assistant for smart glasses. Use the web search result to answer the user's question in 1-3 short spoken sentences. If the result is empty or unrelated, answer from your own knowledge and briefly say you're not certain of the very latest details. Do not mention "search result" or JSON.
        """
        let context = result.isEmpty ? "(no web result found)" : result
        let user = "Question: \(question)\n\nWeb search result: \(context)"
        let messages: [Chat.Message] = [
            .init(role: .system, content: system),
            .init(role: .user, content: user)
        ]
        if let out = try? await rawGenerate(messages: messages, maxTokens: 200, temperature: 0.4),
           !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Generation failed — speak the raw result if we have one.
        return result.isEmpty ? "I couldn't find that right now." : result
    }

    /// One-shot text generation (no streaming/callbacks) — used by the intent router.
    private func rawGenerate(messages: [Chat.Message], maxTokens: Int, temperature: Float) async throws -> String {
        guard let container = modelContainer else { throw GemmaLocalError.modelNotLoaded }
        guard UIApplication.shared.applicationState != .background else { throw GemmaLocalError.backgrounded }
        let userInput = UserInput(chat: messages)
        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            return try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)
        }
        var full = ""
        for await item in stream {
            if case .chunk(let piece) = item { full += piece }
        }
        Memory.clearCache()
        return full
    }

    // MARK: - Helpers

    private func setState(_ state: AIConnectionState) {
        connectionState = state
    }

    private func setProcessing(_ value: Bool) {
        isProcessing = value
        onProcessingChanged?(value)
    }

    enum GemmaLocalError: LocalizedError {
        case modelNotLoaded
        case backgrounded
        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The local Gemma model isn't loaded. Download it in Settings → AI Backend → Local (Gemma 4)."
            case .backgrounded:
                return "On-device AI can't run while the app is in the background. Bring OpenVision to the foreground."
            }
        }
    }
}
