// OpenVision - GemmaLocalService.swift
// On-device Gemma 4 backend (text tier) running via Apple MLX.
//
// Conforms to the same backend shape as OpenClawService / GeminiLiveService:
// `.shared` singleton, @MainActor, AIConnectionState, callbacks (not Combine for events),
// connect()/disconnect()/sendMessage(). "Connect" loads the model into memory; "disconnect"
// unloads it. Selection is a manual knob (Settings → AI Backend → Local (Gemma 4)).
//
// Vision: SmolVLM2 handles photos fully on-device ("what's this?" with a glasses frame) —
// images go in via UserInput / Chat.Message, resized to bound encoder memory. Gemma 4 E2B,
// though a VLM, stays TEXT-ONLY: its full-res image encoding hit the ~6GB jetsam limit and
// crashed. See GemmaLocalModel.supportsOnDeviceVision.
//
// NOTE: Requires iOS 18+ and a physical device (MLX is unavailable on the Simulator).

import Foundation
import UIKit            // UIApplication.applicationState — GPU inference is forbidden in background
import MLX
import MLXLLM            // text LLMs (Qwen 2.5, Gemma 2) via LLMModelFactory
import MLXVLM            // vision models (Gemma 4, SmolVLM2) via VLMModelFactory
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader() / #huggingFaceTokenizerLoader() macros
import HuggingFace      // the macros expand to HuggingFace.HubClient …
import Tokenizers       // … and Tokenizers.AutoTokenizer

// MARK: - Selectable on-device models

/// The on-device MLX models we expose in the model manager. A mix of lighter text LLMs and the
/// heavier vision-capable Gemma 4 — so you can trade memory/speed for capability.
/// Repo ids match validated `mlx-community` snapshots.
enum GemmaLocalModel: String, CaseIterable, Identifiable, Codable {
    case qwen05B         // Qwen 2.5 0.5B — tiny/fastest
    case gemma2_2B       // Gemma 2 2B — balanced text
    case qwen3B          // Qwen 2.5 3B — strong text, still light
    case e2b             // Gemma 4 E2B — vision-capable, heaviest
    case smolVLM2_2B     // SmolVLM2 2.2B — lighter vision model
    case fastVLM05B      // Apple FastVLM 0.5B — fastest vision, real-time
    // NOTE: FastVLM 1.5B is intentionally absent — no public MLX checkpoint loads in mlx-swift-lm
    // (the community conversions ship non-reparameterized FastViTHD weights that fail key lookup).
    // The config-injection + retry infra below is kept for when a correct 1.5B conversion exists.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen05B: return "Qwen 2.5 0.5B"
        case .gemma2_2B: return "Gemma 2 2B"
        case .qwen3B: return "Qwen 2.5 3B"
        case .e2b: return "Gemma 4 E2B"
        case .smolVLM2_2B: return "SmolVLM2 2.2B"
        case .fastVLM05B: return "FastVLM 0.5B"
        }
    }

    /// HuggingFace repo id of the MLX snapshot.
    var modelId: String {
        switch self {
        case .qwen05B: return "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        case .gemma2_2B: return "mlx-community/gemma-2-2b-it-4bit"
        case .qwen3B: return "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case .e2b: return "mlx-community/gemma-4-E2B-it-4bit"
        case .smolVLM2_2B: return "mlx-community/SmolVLM2-2.2B-Instruct-mlx"
        // FastVLM: Apple's real-time VLM (FastViTHD encoder). 0.5B is the factory's reference
        // build (config matches out of the box); the 1.5B community 8-bit needs its
        // preprocessor_config's processor_class patched to FastVLMProcessor (see patch on load).
        case .fastVLM05B: return "mlx-community/FastVLM-0.5B-bf16"
        }
    }

    var detail: String {
        switch self {
        case .qwen05B: return "0.5B • ~0.4 GB • tiny, lowest memory, fastest"
        case .gemma2_2B: return "2B • ~1.5 GB • balanced text"
        case .qwen3B: return "3B • ~1.9 GB • strongest text, still light"
        case .e2b: return "2B • ~3.6 GB • vision-capable, heaviest"
        case .smolVLM2_2B: return "2.2B • ~2.6 GB • on-device vision: photos + live video"
        case .fastVLM05B: return "0.5B • ~1.0 GB • Apple FastVLM — fastest real-time vision"
        }
    }

    /// Vision models load via VLMModelFactory; text models via LLMModelFactory.
    var isVLM: Bool {
        switch self {
        case .e2b, .smolVLM2_2B, .fastVLM05B: return true
        case .qwen05B, .gemma2_2B, .qwen3B: return false
        }
    }

    /// Whether we let this model *use* its vision on-device. Distinct from `isVLM`: Gemma 4 E2B
    /// is a VLM but its image encoding pushed memory to the ~6GB jetsam limit and crashed, so it
    /// stays text-only. SmolVLM2 and Apple's FastVLM are trusted for on-device photos/live video —
    /// FastVLM's FastViTHD encoder is designed to be fast and memory-light at high resolution.
    var supportsOnDeviceVision: Bool {
        switch self {
        case .smolVLM2_2B, .fastVLM05B: return true
        default: return false
        }
    }

    /// True for the FastVLM family (used to keep FastVLM at native resolution rather than the
    /// SmolVLM downscale, and to trigger the 1.5B processor-config patch).
    var isFastVLM: Bool {
        self == .fastVLM05B
    }

    static func from(modelId: String) -> GemmaLocalModel {
        allCases.first { $0.modelId == modelId } ?? .e2b
    }

    /// True if the given model id (which may not be in our list) is a vision model.
    static func isVLM(modelId: String) -> Bool {
        allCases.first { $0.modelId == modelId }?.isVLM ?? false
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

    /// True when the loaded model can take photos on-device (currently SmolVLM2 only).
    /// Unknown model ids resolve to .e2b in from(modelId:), which is vision-disabled — safe.
    var visionReady: Bool {
        guard let id = loadedModelId, modelContainer != nil else { return false }
        return GemmaLocalModel.from(modelId: id).supportsOnDeviceVision
    }
    private var cancelRequested = false
    private var generationID = 0   // bumped per request; stale generations stay silent
    private var enteredBackgroundDuringGeneration = false

    // mlx-swift-lm 3.31.3 ships a native Gemma 4 VLM (text + vision) registered in
    // VLMModelFactory, so no custom model registration is needed.

    // MARK: - SmolVLM preprocessor patch (vision memory cap)

    /// Cap for SmolVLM2's `size.longest_edge`. As shipped (2048), the processor UPSCALES every
    /// input to 2048px — regardless of how small we hand it in — and tiles it into ~25 384px
    /// crops, all encoded in one batched vision pass: an instant jetsam kill on iPhone
    /// (observed: SIGKILL right at "starting generation"). 384 → 1 tile + the global image =
    /// 2 encoder inputs. This is the documented SmolVLM memory knob (lower longest_edge to
    /// trade detail for memory); raise to 768 (5 tiles) if quality needs it and memory allows.
    private static let smolVLMMaxLongestEdge = 384

    /// Rewrite `preprocessor_config.json` in the downloaded SmolVLM snapshot(s) to cap
    /// `size.longest_edge`. Safe against re-downloads: the HuggingFace cache is existence-checked
    /// (content-addressed blobs are not re-hashed), so a patched file is used as-is. Idempotent.
    nonisolated private static func patchSmolVLMPreprocessorConfig() {
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en
            where url.lastPathComponent == "preprocessor_config.json"
                && url.path.localizedCaseInsensitiveContains("smolvlm") {
                patchLongestEdge(at: url)
            }
        }
    }

    nonisolated private static func patchLongestEdge(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var size = json["size"] as? [String: Any] else { return }
        let current = size["longest_edge"] as? Int
        guard current != smolVLMMaxLongestEdge else { return }
        size["longest_edge"] = smolVLMMaxLongestEdge
        json["size"] = size
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        do {
            // Plain (non-atomic) write follows the snapshot symlink and updates the blob in place.
            try out.write(to: url)
            NSLog("[OV] SmolVLM preprocessor patched at %@: longest_edge %d -> %d",
                  url.lastPathComponent, current ?? -1, smolVLMMaxLongestEdge)
        } catch {
            NSLog("[OV] SmolVLM preprocessor patch FAILED: %@", "\(error)")
        }
    }

    // MARK: - FastVLM processor patch (community 1.5B config fix)

    /// The community FastVLM-1.5B MLX export declares processor_class "LlavaProcessor" /
    /// image_processor_type "CLIPImageProcessor", so mlx-swift-lm's factory (which keys the vision
    /// processor by "FastVLMProcessor") can't resolve it and the load fails. The image fields the
    /// FastVLM processor actually decodes (image_mean/std, crop_size) are already identical to the
    /// reference FastVLM config, so we only rewrite the two type strings. Idempotent; safe against
    /// re-download (the HF cache is existence-checked, so a patched blob is reused).
    nonisolated private static func patchFastVLMProcessorConfig() {
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en
            where url.lastPathComponent == "preprocessor_config.json"
                && url.path.localizedCaseInsensitiveContains("fastvlm") {
                patchProcessorClass(at: url)
            }
        }
    }

    nonisolated private static func patchProcessorClass(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard (json["processor_class"] as? String) != "FastVLMProcessor" else { return }
        let previous = (json["processor_class"] as? String) ?? "nil"
        json["processor_class"] = "FastVLMProcessor"
        json["image_processor_type"] = "FastVLMImageProcessor"
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        do {
            try out.write(to: url)
            NSLog("[OV] FastVLM preprocessor patched at %@: processor_class %@ -> FastVLMProcessor",
                  url.lastPathComponent, previous)
        } catch {
            NSLog("[OV] FastVLM preprocessor patch FAILED: %@", "\(error)")
        }
    }

    /// The FastViTHD vision encoder is identical across all FastVLM sizes (0.5B/1.5B/7B) — only the
    /// language model scales. Some community MLX exports (e.g. FastVLM-1.5B-MLX-8bit) serialize an
    /// EMPTY `vision_config: {}`, which makes mlx-swift-lm's decoder throw on the first missing field
    /// (`vision_config.cls_ratio`). This is the reference FastViTHD config (from the working 0.5B
    /// build) we inject when the export dropped it. `mm_vision_tower` is `mobileclip_l_1024` on both
    /// sizes, confirming the encoder matches, so the injected config is correct.
    nonisolated private static var fastViTHDVisionConfig: [String: Any] {
        [
            "cls_ratio": 2.0,
            "down_patch_size": 7,
            "down_stride": 2,
            "downsamples": [true, true, true, true, true],
            "embed_dims": [96, 192, 384, 768, 1536],
            "hidden_size": 1024,
            "image_size": 1024,
            "intermediate_size": 3072,
            "layer_scale_init_value": 1e-05,
            "layers": [2, 12, 24, 4, 2],
            "mlp_ratios": [4, 4, 4, 4, 4],
            "num_classes": 1000,
            "patch_size": 64,
            "pos_embs_shapes": [NSNull(), NSNull(), NSNull(), [7, 7], [7, 7]],
            "projection_dim": 768,
            "repmixer_kernel_size": 3,
            "token_mixers": ["repmixer", "repmixer", "repmixer", "attention", "attention"],
        ]
    }

    /// Inject the FastViTHD `vision_config` into any FastVLM `config.json` whose export left it empty.
    nonisolated private static func patchFastVLMConfigJSON() {
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en
            where url.lastPathComponent == "config.json"
                && url.path.localizedCaseInsensitiveContains("fastvlm") {
                injectFastVLMVisionConfig(at: url)
            }
        }
    }

    nonisolated private static func injectFastVLMVisionConfig(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Only inject when it's actually missing — never clobber a config that already has it (0.5B).
        let existing = json["vision_config"] as? [String: Any]
        guard existing?["cls_ratio"] == nil else { return }
        json["vision_config"] = fastViTHDVisionConfig
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        do {
            try out.write(to: url)
            NSLog("[OV] FastVLM config patched at %@: injected FastViTHD vision_config", url.path)
        } catch {
            NSLog("[OV] FastVLM config patch FAILED: %@", "\(error)")
        }
    }

    /// Apply every downloaded-config fixup (SmolVLM memory cap + FastVLM processor class + FastVLM
    /// empty vision_config).
    nonisolated private static func patchDownloadedVisionConfigs() {
        patchSmolVLMPreprocessorConfig()
        patchFastVLMProcessorConfig()
        patchFastVLMConfigJSON()
    }

    // MARK: - Download (model manager)

    /// Download a model snapshot to disk (idempotent — skipped if already cached).
    func download(_ model: GemmaLocalModel, onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        // loadContainer fetches the snapshot if missing; reuse it as the download path.
        // Patch first in case a snapshot already exists — the config is read during load.
        Self.patchDownloadedVisionConfigs()
        do {
            _ = try await loadModelContainer(modelId: model.modelId) { [weak self] p in
                self?.downloadProgress = p
                onProgress(p)
            }
        } catch {
            // A fresh snapshot's RAW config may be rejected before we can touch it (FastVLM 1.5B
            // ships an empty vision_config). The files are on disk now, so patch and retry once —
            // the existence-checked cache reuses them, so this is a re-parse, not a re-download.
            NSLog("[OV] load failed (%@) — patching downloaded configs and retrying", "\(error)")
            Self.patchDownloadedVisionConfigs()
            _ = try await loadModelContainer(modelId: model.modelId) { [weak self] p in
                self?.downloadProgress = p
                onProgress(p)
            }
        }
        Self.patchDownloadedVisionConfigs()
        downloadProgress = 1
    }

    /// Load (downloading if needed) a model container, using the vision or text factory based on
    /// the model type. Both produce an MLXLMCommon `ModelContainer` that generates identically.
    private func loadModelContainer(modelId: String, progress: @escaping (Double) -> Void) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: modelId)
        let handler: (Progress) -> Void = { p in Task { @MainActor in progress(p.fractionCompleted) } }
        if GemmaLocalModel.isVLM(modelId: modelId) {
            return try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: handler)
        } else {
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: handler)
        }
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

        // Cap SmolVLM's image-splitting resolution BEFORE the load reads the processor config
        // (as shipped it tiles every photo into ~25 vision-encoder inputs → jetsam).
        Self.patchDownloadedVisionConfigs()

        do {
            print("[GemmaLocal] loading container…")
            let container: ModelContainer
            do {
                container = try await loadModelContainer(modelId: modelId) { [weak self] p in
                    self?.downloadProgress = p
                }
            } catch {
                // Retry once after re-patching (covers a snapshot whose config wasn't patched yet).
                NSLog("[OV] connect load failed (%@) — re-patching and retrying", "\(error)")
                Self.patchDownloadedVisionConfigs()
                container = try await loadModelContainer(modelId: modelId) { [weak self] p in
                    self?.downloadProgress = p
                }
            }
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

    // MARK: - On-disk model management

    /// Every base directory where the Hugging Face hub cache could live in an iOS sandbox. The
    /// downloaded model snapshots live under `<base>/huggingface/...`, so nuking these frees them
    /// regardless of the exact cache-location resolution.
    nonisolated private static func dirSizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Every on-disk location that holds downloaded model data or its leftovers, so deleting them
    /// actually frees the storage. Covers the LiteRT model dirs, the HuggingFace/MLX cache, the
    /// XNNPACK compile caches, and orphaned CFNetwork download temp files.
    nonisolated private static func modelDataURLs() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []

        // LiteRT/MediaPipe model + cache in Documents.
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(docs.appendingPathComponent("GemmaModels", isDirectory: true))
            urls.append(docs.appendingPathComponent("GemmaCache", isDirectory: true))
        }
        // HuggingFace / MLX snapshot cache (if that path is ever used).
        for dir in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            if let base = fm.urls(for: dir, in: .userDomainMask).first {
                urls.append(base.appendingPathComponent("huggingface", isDirectory: true))
            }
        }
        // tmp leftovers: XNNPACK compile caches + half-finished CFNetwork downloads.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items {
                let n = item.lastPathComponent
                if n.hasSuffix(".xnnpack_cache") || n.hasSuffix(".litertlm") || n.hasPrefix("CFNetworkDownload_") {
                    urls.append(item)
                }
            }
        }
        return urls
    }

    /// Total on-disk size of all downloaded model data, in bytes (0 if none).
    nonisolated static func downloadedSizeBytes(for modelId: String = "") -> Int64 {
        modelDataURLs().reduce(0) { $0 + dirSizeBytes($1) }
    }

    /// Delete all downloaded model data from disk to free storage. Unloads from memory first.
    func deleteDownloadedModel(_ modelId: String) async -> Bool {
        // Drop the in-memory model so we're not holding files we're about to remove.
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        Memory.clearCache()
        setState(.disconnected)

        return await Task.detached {
            let fm = FileManager.default
            var removedAny = false
            for url in Self.modelDataURLs() where fm.fileExists(atPath: url.path) {
                let mb = Self.dirSizeBytes(url) / 1_048_576
                do {
                    try fm.removeItem(at: url)
                    NSLog("[OV] deleted %@ (%lld MB)", url.lastPathComponent, mb)
                    removedAny = true
                } catch {
                    NSLog("[OV] delete failed at %@: %@", url.path, "\(error)")
                }
            }
            if !removedAny { NSLog("[OV] deleteModel: nothing found to remove") }
            return true
        }.value
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

        // Vision policy: images are used ONLY when the loaded model is trusted with on-device
        // vision (SmolVLM2). Gemma 4 E2B's image encoding pushed memory to the ~6GB jetsam limit
        // and crashed, so for every other model `imageData` is ignored and photo commands route
        // to a cloud backend (VoiceAgentView gates that path on `visionReady`).
        var visionImage: CIImage?
        if let imageData, visionReady {
            visionImage = CIImage(data: imageData)
            if visionImage == nil {
                NSLog("[OV] GemmaLocal: image data didn't decode — falling back to text-only")
            }
        }

        // Keep replies short — this is spoken aloud on glasses, so long answers get tiresome
        // (and the TTS cuts off after ~a minute). Aim for a couple of natural sentences.
        var brevity = "You are a hands-free voice assistant for smart glasses. Reply in 2–4 natural sentences — enough detail to be genuinely useful and give a real sense of things, but brief enough to hear comfortably (around 20–30 seconds). Be specific and concrete, not vague. No lists, no markdown, no preamble; just answer."
        // Hallucination defense: SmolVLM confidently invents details it can't see (research puts
        // its "describe a thing that isn't there" rate near 94%, dropping to ~22% with a grounding
        // prompt). Anchor it to THIS frame and let it admit uncertainty rather than guess — this is
        // what stops the live feed from narrating stale/blurry glimpses when the head is moving.
        if visionImage != nil {
            brevity += " You are looking through the glasses camera right now. Describe ONLY what is clearly and currently visible in this exact image. If it's blurry, dark, partly out of frame, or you're not certain what something is, say so briefly instead of guessing — never mention objects you aren't confident are actually present."
        }
        let userSys = SettingsManager.shared.settings.userPrompt
        let systemContent = userSys.isEmpty ? brevity : "\(userSys)\n\n\(brevity)"

        var chat: [Chat.Message] = []
        chat.append(.init(role: .system, content: systemContent))
        if let visionImage {
            chat.append(.init(role: .user, content: text, images: [.ciImage(visionImage)]))
        } else {
            chat.append(.init(role: .user, content: text))
        }
        // Resize policy is model-specific:
        //  • SmolVLM: pre-shrink to 512 so its (patched) tiler stays cheap — the jetsam killer was
        //    full-resolution encoding.
        //  • FastVLM: DON'T pre-shrink. Its FastViTHD encoder is built to ingest high-res frames
        //    cheaply (few visual tokens), so downscaling would throw away its main advantage; let
        //    its own processor handle sizing.
        let loadedIsFastVLM = loadedModelId.map { GemmaLocalModel.from(modelId: $0).isFastVLM } ?? false
        let resize: CGSize? = (visionImage != nil && !loadedIsFastVLM) ? CGSize(width: 512, height: 512) : nil
        let userInput = UserInput(chat: chat, processing: .init(resize: resize))

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

    // MARK: - Agentic intent routing (shared logic lives in LocalAgent)

    typealias FaceIntent = LocalAgent.FaceIntent

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

    typealias RouteResult = LocalAgent.RouteResult

    /// ONE generation that either routes a face command, requests a web search, or answers. Delegates
    /// the prompt/parsing to LocalAgent (shared with the Apple Foundation backend).
    func routeCommand(_ command: String) async -> RouteResult {
        let history = ConversationContext.shared.turns
        return await LocalAgent.route(command, history: history) { [weak self] system, hist, user in
            guard let self else { return nil }
            var messages: [Chat.Message] = [.init(role: .system, content: system)]
            for turn in hist {
                messages.append(.init(role: turn.role == "assistant" ? .assistant : .user, content: turn.content))
            }
            messages.append(.init(role: .user, content: user))
            return try? await self.rawGenerate(messages: messages, maxTokens: 200, temperature: 0.3)
        }
    }

    /// Like `routeCommand`, but streams the cumulative model output via `onPartial` so the caller
    /// can start speaking a plain answer before generation finishes. Face/tool routes emit a JSON
    /// object beginning with "{"; the caller withholds speech until it sees the output isn't JSON.
    func routeCommandStreaming(_ command: String, onPartial: @escaping (String) -> Void) async -> RouteResult {
        let history = ConversationContext.shared.turns
        return await LocalAgent.route(command, history: history) { [weak self] system, hist, user in
            guard let self else { return nil }
            var messages: [Chat.Message] = [.init(role: .system, content: system)]
            for turn in hist {
                messages.append(.init(role: turn.role == "assistant" ? .assistant : .user, content: turn.content))
            }
            messages.append(.init(role: .user, content: user))
            return try? await self.rawGenerate(messages: messages, maxTokens: 200, temperature: 0.3, onPartial: onPartial)
        }
    }

    func reformulateSearchQuery(question: String, triedQuery: String) async -> String? {
        let out = try? await rawGenerate(messages: [
            .init(role: .system, content: LocalAgent.reformulateSystemPrompt),
            .init(role: .user, content: "User's question: \(question)\nQuery that found nothing: \(triedQuery)")
        ], maxTokens: 40, temperature: 0.5)
        return LocalAgent.cleanReformulatedQuery(out, triedQuery: triedQuery)
    }

    /// Phrase a concise spoken answer to `question` using a web-search `result`.
    func answerWithSearchResult(question: String, result: String) async -> String {
        await LocalAgent.answerWithSearchResult(question: question, result: result) { [weak self] system, _, user in
            guard let self else { return nil }
            return try? await self.rawGenerate(messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: user)
            ], maxTokens: 200, temperature: 0.4)
        }
    }

    /// One-shot text generation used by the intent router. Optionally emits the cumulative text
    /// via `onPartial` per token so the caller can pipeline speech (Apple TTS) behind generation.
    private func rawGenerate(messages: [Chat.Message], maxTokens: Int, temperature: Float,
                             onPartial: ((String) -> Void)? = nil) async throws -> String {
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
            if case .chunk(let piece) = item {
                full += piece
                if let onPartial {
                    let snapshot = full
                    await MainActor.run { onPartial(snapshot) }
                }
            }
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

extension GemmaLocalService: LocalTextLLM {}
