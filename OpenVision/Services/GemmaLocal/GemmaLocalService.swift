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
/// Repo ids match validated `mlx-community` snapshots, except `bonsai8B` (PrismML — see below).
enum GemmaLocalModel: String, CaseIterable, Identifiable, Codable {
    case qwen05B         // Qwen 2.5 0.5B — tiny/fastest
    case gemma2_2B       // Gemma 2 2B — balanced text
    case qwen3B          // Qwen 2.5 3B — strong text, still light
    case bonsai8B        // Bonsai 8B — Qwen3-8B at 1-bit, best text-per-byte
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
        case .bonsai8B: return "Bonsai 8B (1-bit)"
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
        // PrismML's 1-bit (g128, ~1.25 bpw) quantization of Qwen3-8B. config.json declares
        // model_type "qwen3", which LLMModelFactory already registers, so it needs no loader
        // changes — but the 1-bit Metal kernels only exist in the PrismML mlx-swift fork that
        // project.yml pins. On stock mlx-swift this model loads and then miscomputes/fails.
        case .bonsai8B: return "prism-ml/Bonsai-8B-mlx-1bit"
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
        case .qwen05B: return "0.5B • ~0.4 GB • tiny + fastest — weak at conversation memory"
        case .gemma2_2B: return "2B • ~1.5 GB • balanced text, good conversation memory"
        case .qwen3B: return "3B • ~1.9 GB • strongest text + best conversation memory"
        case .bonsai8B: return "8B • ~1.3 GB • 1-bit Qwen3-8B — strongest text, smallest footprint"
        case .e2b: return "2B • ~3.6 GB • vision-capable, heaviest"
        case .smolVLM2_2B: return "2.2B • ~2.6 GB • best all-round: vision + solid memory"
        case .fastVLM05B: return "0.5B • ~1.0 GB • fastest live vision — weak at conversation memory"
        }
    }

    /// Approximate full snapshot size, used to estimate download progress from bytes on disk
    /// (the hub only reports per-FILE progress, useless for a model that is one big safetensors).
    var expectedDownloadBytes: Int64 {
        switch self {
        case .qwen05B: return 400_000_000
        case .gemma2_2B: return 1_500_000_000
        case .qwen3B: return 1_900_000_000
        // 1,280,131,424 B of weights + ~16 MB tokenizer/vocab/merges.
        case .bonsai8B: return 1_300_000_000
        case .e2b: return 3_600_000_000
        case .smolVLM2_2B: return 2_600_000_000
        case .fastVLM05B: return 1_000_000_000
        }
    }

    /// Vision models load via VLMModelFactory; text models via LLMModelFactory. Gemma 4 E2B is a
    /// multimodal checkpoint (weights prefixed `language_model.`, plus vision/audio towers), so it
    /// loads via VLMModelFactory — but only after registerGemma4TextType() swaps a shared-KV-aware
    /// text backbone into the type registry (see loadModelContainer). Same recipe as OpenGlasses.
    var isVLM: Bool {
        switch self {
        case .e2b, .smolVLM2_2B, .fastVLM05B: return true
        case .qwen05B, .gemma2_2B, .qwen3B, .bonsai8B: return false
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

    /// Whether this model gets the short routing prompt.
    ///
    /// The verbose prompt (~6,850 chars, mostly worked examples) is re-prefilled every turn, and
    /// prefill dominates latency: telemetry measured time-to-first-token at ~5s of a ~6.4s wait.
    /// Those examples exist for 2B-class models that mis-route without them; Bonsai is a Qwen3-8B
    /// base and should generalise from the rules alone. Opt models in only after checking routing
    /// still holds on device — a wrong route is far worse than a slow one.
    var prefersConcisePrompt: Bool {
        self == .bonsai8B
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

    /// The model currently loaded in memory, or nil when none is. Distinct from the *selected*
    /// model in settings — telemetry must report what actually served a turn, not what is picked.
    var activeModelId: String? { loadedModelId }

    /// True when the loaded model can take photos on-device (currently SmolVLM2 only).
    /// Unknown model ids resolve to .e2b in from(modelId:), which is vision-disabled — safe.
    var visionReady: Bool {
        guard let id = loadedModelId, modelContainer != nil else { return false }
        return GemmaLocalModel.from(modelId: id).supportsOnDeviceVision
    }
    private var cancelRequested = false
    private var generationID = 0   // bumped per request; stale generations stay silent
    private var enteredBackgroundDuringGeneration = false

    // mlx-swift-lm 3.31.4 registers Gemma 4 only in VLMModelFactory, whose text backbone mishandles
    // E-series shared-KV layers. We load Gemma 4 E2B as text instead — see registerGemma4TextType().

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

    /// Never lower the visible progress (the two estimators below race).
    private func bumpDownloadProgress(_ p: Double) {
        if p > downloadProgress { downloadProgress = p }
    }

    /// Download a model snapshot to disk (idempotent — skipped if already cached).
    func download(_ model: GemmaLocalModel, onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        // The hub's progress callback counts FILES, and a model is mostly one giant safetensors —
        // so it sits at 0% for the whole download, then jumps to done. Poll the bytes actually on
        // disk (partial snapshot + CFNetwork in-flight temp files) against the model's expected
        // size for real, monotonic progress. Capped at 99% until the load truly completes.
        let modelId = model.modelId
        let expected = max(model.expectedDownloadBytes, 1)
        let started = Date()
        let poller = Task.detached { [weak self] in
            while !Task.isCancelled {
                let bytes = Self.inFlightDownloadBytes(for: modelId, since: started)
                let est = min(0.99, Double(bytes) / Double(expected))
                await MainActor.run { self?.bumpDownloadProgress(est) }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer { poller.cancel() }

        // loadContainer fetches the snapshot if missing; reuse it as the download path.
        // Patch first in case a snapshot already exists — the config is read during load.
        // The hub's own progress callback is deliberately NOT fed into downloadProgress: it emits
        // a fresh 0→1 fraction per FILE, which made the bar thrash between 1% and 99%. The byte
        // poller above is the single writer until completion.
        Self.patchDownloadedVisionConfigs()
        do {
            _ = try await loadModelContainer(modelId: model.modelId) { p in onProgress(p) }
        } catch {
            // A fresh snapshot's RAW config may be rejected before we can touch it (FastVLM 1.5B
            // ships an empty vision_config). The files are on disk now, so patch and retry once —
            // the existence-checked cache reuses them, so this is a re-parse, not a re-download.
            NSLog("[OV] load failed (%@) — patching downloaded configs and retrying", "\(error)")
            Self.patchDownloadedVisionConfigs()
            _ = try await loadModelContainer(modelId: model.modelId) { p in onProgress(p) }
        }
        Self.patchDownloadedVisionConfigs()
        downloadProgress = 1
    }

    /// Load (downloading if needed) a model container, using the vision or text factory based on
    /// the model type. Both produce an MLXLMCommon `ModelContainer` that generates identically.
    private func loadModelContainer(modelId: String, progress: @escaping (Double) -> Void) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: modelId)
        let handler: (Progress) -> Void = { p in Task { @MainActor in progress(p.fractionCompleted) } }
        // Register the shared-KV-aware Gemma 4 text backbone before loading. The multimodal VLM
        // Gemma 4 wrapper builds its text tower from this same type registry, so E2B needs it too.
        await Self.registerGemma4TextType()
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

    /// Teach the LLM factory to build Gemma 4 (incl. E2B) as a pure text model. mlx-swift-lm only
    /// registers `gemma4` in the *VLM* factory, whose text backbone mishandles E-series shared-KV
    /// layers; the standalone `Gemma4TextModel` handles them. `Gemma4TextConfiguration` decodes
    /// top-level keys and its defaults already equal E2B's text_config (hidden 1536, 35 layers,
    /// 20 kv-shared, 256 per-layer input), so an E2B checkpoint that nests those under `text_config`
    /// still yields correct params. Same fix OpenGlasses applies. Idempotent (map insert).
    private static func registerGemma4TextType() async {
        // Fully qualified: MLXVLM also exports Gemma4TextConfiguration/Gemma4TextModel, so the bare
        // names are ambiguous — the LLM (text) types are the ones that handle shared-KV layers.
        for type in ["gemma4", "gemma4_text"] {
            await LLMTypeRegistry.shared.registerModelType(type) { data in
                let config = try JSONDecoder().decode(MLXLLM.Gemma4TextConfiguration.self, from: data)
                return MLXLLM.Gemma4TextModel(config)
            }
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

        // Switching models: free the CURRENT container before loading the next one. Holding both
        // (e.g. Gemma 4 E2B + SmolVLM2) exceeds the ~6 GB jetsam ceiling — the app was SIGKILLed
        // mid-"loading container…" on device. Trade-off: if the new load fails we're left with no
        // model (a clean failed state the user can retry) instead of a dead app.
        if modelContainer != nil {
            print("[GemmaLocal] releasing previous model (\(loadedModelId ?? "?")) before load")
            modelContainer = nil
            loadedModelId = nil
            invalidateRoutingCache()   // KV cache belongs to the unloaded model
            isModelLoaded = false
        }

        Memory.cacheLimit = 20 * 1024 * 1024

        // Cap SmolVLM's image-splitting resolution BEFORE the load reads the processor config
        // (as shipped it tiles every photo into ~25 vision-encoder inputs → jetsam).
        Self.patchDownloadedVisionConfigs()

        do {
            print("[GemmaLocal] loading container…")
            let container: ModelContainer
            do {
                // NOTE: don't write downloadProgress here — connect() can run concurrently with a
                // download() (wake word stays live behind Settings), and the hub emits a fresh
                // 0→1 progress per FILE, so a second writer makes the download bar thrash.
                container = try await loadModelContainer(modelId: modelId) { _ in }
            } catch {
                // Retry once after re-patching (covers a snapshot whose config wasn't patched yet).
                NSLog("[OV] connect load failed (%@) — re-patching and retrying", "\(error)")
                Self.patchDownloadedVisionConfigs()
                container = try await loadModelContainer(modelId: modelId) { _ in }
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
        invalidateRoutingCache()   // KV cache belongs to the unloaded model
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

    /// Directories on disk belonging to ONE model's snapshot. The hub cache nests the repo id in
    /// the path (either `models/<org>/<name>` or `models--<org>--<name>` depending on layout), so
    /// we match top-level-ish directories whose path contains the repo's name. Blobs live inside
    /// the repo dir in both layouts, so size/delete on these is complete for that model.
    nonisolated private static func repoDirectories(for modelId: String) -> [URL] {
        guard let repoName = modelId.split(separator: "/").last.map(String.init), !repoName.isEmpty
        else { return [] }
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory, .applicationSupportDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in en
            where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && url.lastPathComponent.localizedCaseInsensitiveContains(repoName) {
                found.append(url)
                en.skipDescendants()   // the whole repo dir matched — don't also match children
            }
        }
        return found
    }

    // MARK: - Model store bootstrap (run once, before any HubClient exists)

    /// The permanent home for downloaded models: Application Support (NOT purged by iOS).
    nonisolated static var modelStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    /// Point the HuggingFace hub cache at Application Support and clean up download debris.
    /// The default hub location is `Library/Caches/huggingface/hub`, which iOS purges under
    /// storage pressure — downloaded weights silently vanished and were re-downloaded on the next
    /// connect. Interrupted downloads also strand multi-GB `CFNetworkDownload_*.tmp` files (6+ GB
    /// observed); at launch none can be in flight, so sweep them all.
    nonisolated static func bootstrapModelStore() {
        let fm = FileManager.default
        let store = modelStoreURL
        try? fm.createDirectory(at: store, withIntermediateDirectories: true)

        // Migrate whatever survives in the old purgeable location (configs/partial snapshots).
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let old = caches.appendingPathComponent("huggingface/hub", isDirectory: true)
            if fm.fileExists(atPath: old.path),
               let entries = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                for entry in entries {
                    let dest = store.appendingPathComponent(entry.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: entry, to: dest)
                    }
                }
                try? fm.removeItem(at: old)
                NSLog("[OV] model store: migrated old cache → Application Support")
            }
        }

        // Multi-GB of weights must not sync to iCloud backups.
        var storeURL = store
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        try? storeURL.setResourceValues(noBackup)

        // Redirect the hub library here (read at HubClient init — hence "before any HubClient").
        setenv("HF_HUB_CACHE", store.path, 1)

        // Sweep orphaned download temps.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        var freed: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                freed += dirSizeBytes(item)
                try? fm.removeItem(at: item)
            }
        }
        if freed > 0 { NSLog("[OV] model store: swept %lld MB of orphaned download temps", freed / 1_048_576) }
    }

    /// DEBUG: log the hub cache layout (dirs to depth 4 with sizes) so size/delete matching can be
    /// verified against reality on-device.
    nonisolated static func debugDumpHubCache() {
        let fm = FileManager.default
        for (name, dir) in [("documents", FileManager.SearchPathDirectory.documentDirectory),
                            ("caches", .cachesDirectory), ("appSupport", .applicationSupportDirectory)] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard fm.fileExists(atPath: hf.path) else { NSLog("[OV] hubdump %@: (none)", name); continue }
            NSLog("[OV] hubdump %@/huggingface = %lld MB", name, dirSizeBytes(hf) / 1_048_576)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in en where en.level <= 4 {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir {
                    NSLog("[OV] hubdump  L%d dir  %@ = %lld MB", en.level,
                          url.path.replacingOccurrences(of: hf.path, with: ""), dirSizeBytes(url) / 1_048_576)
                    if en.level == 4 { en.skipDescendants() }
                }
            }
        }
        // tmp leftovers
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for i in items where i.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                NSLog("[OV] hubdump tmp %@ = %lld MB", i.lastPathComponent, dirSizeBytes(i) / 1_048_576)
            }
        }
    }

    /// On-disk size in bytes. With a `modelId`, measures ONLY that model's snapshot (plus its
    /// in-flight download temp files); previously this summed the whole cache, so every model
    /// showed the same total. Empty id = everything (legacy/all-models).
    nonisolated static func downloadedSizeBytes(for modelId: String = "") -> Int64 {
        guard !modelId.isEmpty else {
            return modelDataURLs().reduce(0) { $0 + dirSizeBytes($1) }
        }
        return repoDirectories(for: modelId).reduce(0) { $0 + dirSizeBytes($1) }
    }

    /// Bytes on disk attributable to an in-progress download of `modelId`: the partial snapshot
    /// plus CFNetwork's in-flight temp files (where the big safetensors grows until it completes).
    /// Only temps CREATED after `start` count — stale orphans from interrupted downloads made the
    /// progress bar jump straight to 99%.
    nonisolated private static func inFlightDownloadBytes(for modelId: String, since start: Date) -> Int64 {
        var total = downloadedSizeBytes(for: modelId)
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.creationDateKey]) {
            for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created >= start { total += dirSizeBytes(item) }
            }
        }
        return total
    }

    /// Delete ONE model's snapshot from disk (previously this wiped every model). Unloads it from
    /// memory first if it's the loaded one. Falls back to the full legacy cleanup if no per-model
    /// directory can be found for the id.
    func deleteDownloadedModel(_ modelId: String) async -> Bool {
        // Drop the in-memory model if it's the one being removed.
        if loadedModelId == modelId || loadedModelId == nil {
            modelContainer = nil
            loadedModelId = nil
            invalidateRoutingCache()   // KV cache belongs to the unloaded model
            isModelLoaded = false
            Memory.clearCache()
            setState(.disconnected)
        }

        return await Task.detached {
            let fm = FileManager.default
            let repoDirs = Self.repoDirectories(for: modelId)
            // No per-model dir found (legacy LiteRT layout / unknown cache shape) → full cleanup.
            let targets = repoDirs.isEmpty ? Self.modelDataURLs() : repoDirs
            if repoDirs.isEmpty { NSLog("[OV] deleteModel: no repo dir for %@ — falling back to full cleanup", modelId) }
            var removedAny = false
            for url in targets where fm.fileExists(atPath: url.path) {
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
    /// AIBackend conformance — exact protocol signature; defaulted params don't satisfy requirements.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        try await sendMessage(text, imageData: imageData, includeHistory: true)
    }

    func sendMessage(_ text: String, imageData: Data?, includeHistory: Bool) async throws {
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
        var systemContent = userSys.isEmpty ? brevity : "\(userSys)\n\n\(brevity)"

        // Document-focus mode: while the user works with a document, its excerpts ride along —
        // including on VISION turns, so "does this match my letter?" can ground against the
        // document while looking at the frame. (Quality caveat: SmolVLM2 is small; heavy text
        // context alongside an image is a known strain — kept because the grounded use case
        // outweighs it, and the excerpts are bounded.)
        if let docContext = await DocumentFocus.shared.contextForQuery(text) {
            systemContent += "\n\n" + docContext
        }

        var chat: [Chat.Message] = []
        chat.append(.init(role: .system, content: systemContent))
        // Session context so follow-ups work ("what about the one on the left?") — text turns
        // only; past frames are never re-sent (each vision turn sees only the current frame).
        //
        // Refusal quarantine for VISION turns: if an earlier turn ever produced "please upload an
        // image" (a vision question that reached the model text-only), a sub-1B model will parrot
        // that refusal from history on every later turn EVEN WITH an image attached — same
        // context-over-pixels failure as the grounding bug. Narrow, deterministic markers only.
        // includeHistory=false is the caller saying "the scene has CHANGED since the last
        // exchange — answer with fresh eyes". History full of 'what do you see -> a desk with
        // two monitors' made the model copy the old answer to the identical question while
        // looking at a WALL (the attached image was verified correct in the console; the words
        // came from history). Fourth incarnation of the same law: a sub-1B model believes its
        // context over its eyes, so context must be provably consistent with the pixels.
        let historyTurns = includeHistory ? ConversationContext.shared.turns : []
        let refusalMarkers = ["upload an image", "provide an image", "can't see the image",
                              "cannot see the image", "unable to see", "no image"]
        for turn in historyTurns {
            if visionImage != nil, turn.role == "assistant",
               refusalMarkers.contains(where: { turn.content.lowercased().contains($0) }) {
                NSLog("[OV] GemmaLocal: dropping refusal turn from vision history")
                continue
            }
            chat.append(.init(role: turn.role == "assistant" ? .assistant : .user, content: turn.content))
        }
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
        // Exact stats from the library's own completion event: `.info` carries the true token-id
        // count and decode time. Chunk counting is NOT a token count (one chunk can detokenize
        // several tokens), so it only ever produced an approximate tok/s.
        var completion: GenerateCompletionInfo?
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
            switch item {
            case .chunk(let piece):
                full += piece
                tokenCount += 1
                if tokenCount == 1 {
                    NSLog("[OV] GemmaLocal: first token received")
                    // Independent of any listener — see the note in cachedGenerate.
                    await MainActor.run { MetricsCollector.shared.markFirstToken() }
                }
                let snapshot = full
                await MainActor.run { self.onPartialResponse?(snapshot) }
            case .info(let info):
                completion = info
            default:
                break
            }
        }
        NSLog("[OV] GemmaLocal: generation done — %d chunks, %d chars", tokenCount, full.count)

        // Exact when the stream completed; an aborted generation (backgrounded/cancelled) never
        // yields `.info`, and no rate is better than a fabricated one — the stage timestamps are
        // still marked so the turn's breakdown stays complete.
        let stats = completion
        await MainActor.run {
            MetricsCollector.shared.markGenerationDone(
                tokenCount: stats?.generationTokenCount,
                duration: stats?.generateTime
            )
        }

        // Release the MLX buffer cache so vision memory doesn't pile up toward the jetsam limit.
        Memory.clearCache()

        let reply = full
        if !cancelRequested && myID == generationID {
            // Remember this exchange (vision Q&A included) so in-session follow-ups have context.
            ConversationContext.shared.record(user: text, assistant: reply)
            await MainActor.run { self.onAgentMessage?(reply) }
        }
    }

    /// Barge-in: stop streaming the current reply as soon as possible.
    func interrupt() {
        cancelRequested = true
        setProcessing(false)
    }

    // MARK: - Continuous live vision (watch loop)

    /// One frame → one short description. Built for the continuous watch loop, so it deliberately
    /// bypasses everything `sendMessage` does around a real turn: no conversation history, no
    /// onAgentMessage/TTS callbacks, and NO MetricsCollector marks — the loop runs between user
    /// turns, and its inferences stamping a dangling turn's timeline would corrupt turn metrics.
    /// Frame pacing is observed via the counted watch_* events instead.
    ///
    /// maxTokens is capped hard: telemetry showed command replies averaging ~90 tokens at 5-8
    /// tok/s under TTS contention — a paragraph per glance is what made the old behaviour describe
    /// a scene the wearer had already left.
    func describeFrame(_ jpeg: Data, prompt: String, maxTokens: Int = 40) async throws -> String {
        guard let container = modelContainer, visionReady else { throw GemmaLocalError.modelNotLoaded }
        guard UIApplication.shared.applicationState != .background else { throw GemmaLocalError.backgrounded }
        guard let ciImage = CIImage(data: jpeg) else { throw GemmaLocalError.badFrame }
        // Watch frames are ALWAYS bounded to 512 — including FastVLM, which sendMessage keeps at
        // native resolution. Native res is right when the user asked a question about detail; a
        // one-line ambient caption doesn't need it, and encode cost scales with resolution.
        // (Apple's own FastVLM live-captioning demo runs continuous captions with a short-output
        // prompt rather than high-res input.)
        let userInput = UserInput(
            chat: [
                // Prompt style borrowed from Apple's demo: brevity by INSTRUCTION ("about 15
                // words") rather than only by token cap — the model plans a short sentence
                // instead of getting truncated mid-thought.
                .init(role: .user, content: prompt + " Output should be brief, about 15 words or less. Only describe what is clearly visible.",
                      images: [.ciImage(ciImage)])
            ],
            processing: .init(resize: CGSize(width: 512, height: 512))
        )
        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            // temperature 0 (also per Apple's demo): deterministic captions mean the same scene
            // yields the same words, which is exactly what the chatter gate needs — rephrase
            // noise was what kept re-announcing unchanged scenes.
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)
            return try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)
        }
        var full = ""
        var iterator = stream.makeAsyncIterator()
        while let item = await iterator.next() {
            // Cancellable mid-generation (Apple demo pattern): when a user question arrives, the
            // watch task is cancelled and this bails before requesting the next token — freeing
            // the GPU within one decode step instead of making the question queue ~4s behind an
            // ambient caption nobody asked for.
            if Task.isCancelled { break }
            if case .chunk(let piece) = item { full += piece }
        }
        // Same jetsam hygiene as every other generate: vision encoders leave MLX buffers behind.
        Memory.clearCache()
        if Task.isCancelled { throw CancellationError() }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - KV prefix cache

    /// A `ChatSession` kept alive across turns so the routing prompt is prefilled ONCE.
    ///
    /// Telemetry showed prompt prefill dominating on-device latency — ~3s of a ~3.4s wait even
    /// after halving the prompt — because the whole system prompt was re-processed every turn.
    /// `ChatSession` retains its KV cache between `respond` calls, so the stable prefix is paid
    /// for once and conversation history accumulates incrementally instead of being re-prefilled.
    private var routingSession: ChatSession?
    /// What `routingSession` was built for. Any change (model switch, verbose↔concise, a prompt
    /// edit) must invalidate it — reusing a cache built from different tokens produces coherent-
    /// looking but wrong output, which is far harder to notice than a crash.
    private var routingSessionKey: String?

    /// Drop the cached session. Call when the model unloads or the conversation resets.
    func invalidateRoutingCache() {
        routingSession = nil
        routingSessionKey = nil
    }

    /// Generate with the KV prefix cache, creating or reusing a session as needed.
    ///
    /// - Parameters:
    ///   - prompt: split prompt; only `stable` is cached, `perTurn` rides with the user message.
    ///   - history: seeds a NEWLY created session so follow-ups still work after a model switch
    ///     or app restart. Ignored once the session exists — by then its cache holds the history.
    ///   - user: this turn's text.
    ///   - onPartial: cumulative output callback for streamed speech.
    private func cachedGenerate(prompt: LocalAgent.Prompt,
                                history: [ConversationContext.Turn],
                                user: String,
                                onPartial: ((String) -> Void)? = nil) async throws -> String {
        let entryAt = Date()
        guard let container = modelContainer else { throw GemmaLocalError.modelNotLoaded }
        guard UIApplication.shared.applicationState != .background else { throw GemmaLocalError.backgrounded }

        let key = (loadedModelId ?? "") + "\u{1}" + prompt.stable
        var seededHistory = false
        if routingSessionKey != key || routingSession == nil {
            routingSession = ChatSession(
                container,
                instructions: prompt.stable,
                generateParameters: GenerateParameters(maxTokens: 200, temperature: 0.3)
            )
            routingSessionKey = key
            seededHistory = true
            NSLog("[OV] GemmaLocal: new routing session (prefix will be prefilled once)")
        }
        guard let session = routingSession else { throw GemmaLocalError.modelNotLoaded }

        // Fresh session: fold prior turns into the first message so "what were we talking about?"
        // still resolves. Afterwards the session's own cache is the record.
        var message = ""
        if seededHistory, !history.isEmpty {
            let transcript = history
                .map { "\($0.role == "assistant" ? "Assistant" : "User"): \($0.content)" }
                .joined(separator: "\n")
            message += "Earlier in this conversation:\n\(transcript)\n\n"
        }
        if !prompt.perTurn.isEmpty { message += prompt.perTurn + "\n\n" }
        message += user

        // Sub-stage timing inside commit→first-token. KV caching removed the repeated prompt
        // prefill but barely moved ttft, so the cost is elsewhere in here — measure, don't guess.
        let genStart = Date()
        NSLog("[OV] ttft breakdown: setup before generate %.3fs", genStart.timeIntervalSince(entryAt))
        var firstChunkAt: Date?

        var full = ""
        // streamDetails (not streamResponse) so the library's `.info` completion event arrives:
        // it carries the exact token-id count and decode time. Chunk counting is not a token
        // count — one chunk can detokenize several tokens — and timeline-delta rates paired
        // mismatched windows. `.info` is the ground truth for tok/s.
        var completion: GenerateCompletionInfo?
        for try await item in session.streamDetails(to: message) {
            switch item {
            case .chunk(let chunk):
                if firstChunkAt == nil {
                    firstChunkAt = Date()
                    // Mark first token HERE, not from the onPartial callback. Generation is streamed
                    // internally either way, but onPartial is only supplied when the caller wants to
                    // speak mid-generation (Apple TTS). With Kokoro there is no callback, so the mark
                    // never fired: firstTokenAt got backfilled to generation-done, collapsing
                    // generation_s to ~0 and suppressing tok/s entirely — while the same time
                    // silently inflated ttft. The measurement changed, not the work.
                    await MainActor.run { MetricsCollector.shared.markFirstToken() }
                    NSLog("[OV] ttft breakdown: session→first chunk %.3fs (session %@, history seeded %@, message %d chars)",
                          Date().timeIntervalSince(genStart),
                          seededHistory ? "NEW" : "reused",
                          seededHistory ? "yes" : "no",
                          message.count)
                }
                full += chunk
                if let onPartial {
                    let snapshot = full
                    await MainActor.run { onPartial(snapshot) }
                }
            case .info(let info):
                completion = info
            default:
                break
            }
        }

        let stats = completion
        await MainActor.run {
            MetricsCollector.shared.markGenerationDone(
                tokenCount: stats?.generationTokenCount,
                duration: stats?.generateTime
            )
        }
        return full
    }

    /// ONE generation that either routes a face command, requests a web search, or answers. Delegates
    /// the prompt/parsing to LocalAgent (shared with the Apple Foundation backend).
    func routeCommand(_ command: String) async -> RouteResult {
        let history = ConversationContext.shared.turns
        let detail: LocalAgent.PromptDetail =
            GemmaLocalModel.from(modelId: loadedModelId ?? "").prefersConcisePrompt ? .concise : .verbose
        return await LocalAgent.route(command, history: history, detail: detail) { [weak self] prompt, hist, user in
            guard let self else { return nil }
            return try? await self.cachedGenerate(prompt: prompt, history: hist, user: user)
        }
    }

    /// Like `routeCommand`, but streams the cumulative model output via `onPartial` so the caller
    /// can start speaking a plain answer before generation finishes. Face/tool routes emit a JSON
    /// object beginning with "{"; the caller withholds speech until it sees the output isn't JSON.
    func routeCommandStreaming(_ command: String, onPartial: @escaping (String) -> Void) async -> RouteResult {
        let history = ConversationContext.shared.turns
        let detail: LocalAgent.PromptDetail =
            GemmaLocalModel.from(modelId: loadedModelId ?? "").prefersConcisePrompt ? .concise : .verbose
        return await LocalAgent.route(command, history: history, detail: detail) { [weak self] prompt, hist, user in
            guard let self else { return nil }
            return try? await self.cachedGenerate(prompt: prompt, history: hist, user: user,
                                                  onPartial: onPartial)
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
        await LocalAgent.answerWithSearchResult(question: question, result: result) { [weak self] prompt, _, user in
            guard let self else { return nil }
            return try? await self.rawGenerate(messages: [
                .init(role: .system, content: prompt.combined),
                .init(role: .user, content: user)
            ], maxTokens: 200, temperature: 0.4)
        }
    }

    /// One-off text with no history (AIBackend.completeText, used for meeting summaries). Loads the
    /// selected model if it isn't in memory yet; throws if it isn't downloaded or the app is in the
    /// background (Metal can't run there).
    func completeText(system: String, prompt: String) async throws -> String? {
        if modelContainer == nil {
            try await connect(modelId: SettingsManager.shared.settings.localGemmaModelId)
        }
        return try await rawGenerate(messages: [
            .init(role: .system, content: system),
            .init(role: .user, content: prompt)
        ], maxTokens: 600, temperature: 0.3)
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
        var chunkCount = 0
        var completion: GenerateCompletionInfo?
        for await item in stream {
            switch item {
            case .chunk(let piece):
                full += piece
                chunkCount += 1
                if chunkCount == 1 {
                    // NOTE: an earlier commit claimed this mark existed here; it did not — only
                    // sendMessage and cachedGenerate had it. Without it, rawGenerate turns
                    // (search answers, reformulation) backfilled firstToken to generation-done.
                    await MainActor.run { MetricsCollector.shared.markFirstToken() }
                }
                if let onPartial {
                    let snapshot = full
                    await MainActor.run { onPartial(snapshot) }
                }
            case .info(let info):
                completion = info
            default:
                break
            }
        }
        Memory.clearCache()

        // Telemetry: this is a generation path in its own right (search answers, reformulation),
        // so its exact stats must be reported too — the collector ACCUMULATES across passes, so
        // a route pass plus an answer pass sum into one consistent tok/s for the turn.
        let stats = completion
        await MainActor.run {
            MetricsCollector.shared.markGenerationDone(
                tokenCount: stats?.generationTokenCount,
                duration: stats?.generateTime
            )
        }
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
        case badFrame
        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The local Gemma model isn't loaded. Download it in Settings → AI Backend → Local (Gemma 4)."
            case .backgrounded:
                return "On-device AI can't run while the app is in the background. Bring OpenVision to the foreground."
            case .badFrame:
                return "The camera frame couldn't be decoded."
            }
        }
    }
}

extension GemmaLocalService: LocalTextLLM {}
