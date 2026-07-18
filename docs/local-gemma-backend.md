# Local Gemma Backend (On-Device, MLX)

> ## Update (2026-07): Gemma 4 E2B loading — shipped & resolved
>
> Gemma 4 E2B (`mlx-community/gemma-4-E2B-it-4bit`) now loads and runs on-device, including native
> tool-calling (see [native-tools.md](native-tools.md)). Getting there uncovered a chain of
> `mlx-swift-lm` issues — recorded here so nobody re-debugs them:
>
> 1. **`per_layer_model_projection` shape mismatch** (`[8960,192]` vs `[8960,1536]`) on 3.31.3 —
>    fixed by moving to **3.31.4** (PR #309 makes that layer quantizable).
> 2. **Load path.** E2B is a *multimodal* checkpoint (weights prefixed `language_model.`, plus
>    vision/audio towers), so it must load via **`VLMModelFactory`**, not the text `LLMModelFactory`.
>    It is text-only in OpenVision (`supportsOnDeviceVision == false`) — its image encoder blows the
>    ~6 GB jetsam cap — but still loads through the VLM factory.
> 3. **The real bug — shared-KV layers.** E2B's config sets `num_kv_shared_layers: 20`, so its last
>    20 layers (15–34) reuse an earlier layer's K/V and ship **no** `k_proj`/`v_proj`/`k_norm`. The
>    3.31.4 *tag*'s VLM backbone built those projections for **every** layer (never passed
>    `kvSharedOnly`), so it demanded weights the checkpoint omits → `keyNotFound(... layers.15 ...)`.
>    Fixed on a **main commit past the tag**: `68947cc` ("Fix MLXVLM Gemma4 loader to honor
>    num_kv_shared_layers") passes `kvSharedOnly` per layer and guards the attention on
>    `isKVSharedLayer`.
>
> **Pin:** `project.yml` pins `mlx-swift-lm` to the exact revision **`68947ccdca79…`** — *not* main
> HEAD, because a later commit (#369) adopts a newer `mlx-swift` API (`greatestFiniteMagnitudeArray`)
> that our pinned `mlx-swift` 0.31.4 (shared with the vendored Kokoro TTS) doesn't have. `68947cc` is
> the sweet spot: it has the E2B fix but not the incompatible API bump.
>
> **Tool-calling** on the local backend is done via JSON-in-text in `LocalAgent.route` (the model
> emits `{"tool":…}`), *not* Gemma 4's native `<|tool_call>` tokens — mlx-swift-lm can't parse those
> yet ([issue #259](https://github.com/ml-explore/mlx-swift-lm/issues/259)).

---

Status: **Design / proposed** · Target device: **iPhone 17 Pro (A19 Pro, ~12GB RAM)**
Decision: **Phase 1 targets Gemma 4 E2B** (`mlx-community/gemma-4-e2b-it-4bit`, ~3.6GB).
Route: **B — official pinned `mlx-swift-lm 3.31.3` + our own Gemma 4 model port**, sourced from the
**MIT** upstream [`vdthatte/gemma4-ios`](https://github.com/vdthatte/gemma4-ios) (MIT → clean for our
MIT repo). OpenGlasses (BSL 1.1) is **read-only reference** for wiring patterns only — no BSL code
copied. Branch: `feat/local-gemma-backend`.

## Goal

Add a **third AI backend** — an on-device Gemma model (text + vision) running via **MLX** —
alongside the existing OpenClaw and Gemini Live backends. Local-first for **zero marginal
cost, privacy, and offline** use. Selection is a **manual knob** in Settings → no auto-routing
and no cloud fallback (a user flips to Local or Cloud explicitly).

## Why now / why this works

- **iPhone 17 Pro removes the RAM gate** — a vision-capable Gemma E-series model (~3.6GB+)
  loads with headroom. On 6–8GB phones this would be marginal; on 12GB it's comfortable.
- **MLX, not MediaPipe.** The earlier on-device attempt failed on MediaPipe's iOS limitations
  (text-only, picky model support). MLX (`mlx-swift`) is the proven iOS path — Metal-backed,
  supports Gemma/Qwen incl. vision. It integrates as a **Swift Package** (we just removed the
  CocoaPods layer — clean slate).

## Honest expectations

- On-device Gemma vision is good for scene description / identification / general Q&A, but
  **weaker than Gemini Flash** on dense OCR, tiny text, and niche world-knowledge.
- Local-first to save cost is the right default; users who want max quality flip the knob to Cloud.

## The knob (minimal surface)

`AIBackendType` already drives the picker (`AIBackendSettingsView` iterates `.allCases`).
Add one case and it appears automatically:

```swift
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw   = "openclaw"
    case geminiLive = "gemini_live"
    case localGemma = "local_gemma"   // NEW
}
```

## Architecture

- **`GemmaLocalService`** (`Services/GemmaLocal/`) — singleton `.shared`, conforms to the same
  backend shape as `OpenClawService` / `GeminiLiveService` (uses `AIConnectionState`,
  callbacks not Combine, `@MainActor`). "Connect" = load model into memory; "disconnect" = unload.
- **Model manager** — download Gemma weights from HuggingFace Hub on first use, store locally,
  load once. New `GemmaSettingsView` for download/manage/select (reference: OpenGlasses'
  "Download & Manage Models" screen).
- **Vision flow** — reuse the existing glasses photo capture path; feed `UIImage` + prompt into
  the VLM. No new camera code.

## Touch points

| File | Change |
|------|--------|
| `Models/AppSettings.swift` | add `.localGemma` case + `displayName`/`description`/`icon`; `isCurrentBackendConfigured` (model downloaded?) |
| `Views/Settings/AIBackendSettingsView.swift` | auto-renders new case; add config link → `GemmaSettingsView` |
| `Views/Settings/GemmaSettingsView.swift` | NEW — model download/select/manage |
| `Views/VoiceAgent/VoiceAgentView.swift` | extend the `switch aiBackend` sites (connect / disconnect / send) |
| `Services/GemmaLocal/GemmaLocalService.swift` | NEW — MLX load + text/vision inference |
| `project.yml` | add MLX swift package(s) under `packages:`, then `xcodegen generate` |

## Phasing

1. **Text tier** — MLX package added, Gemma text model loads + answers, download UI. Proves the
   framework works end-to-end (the part that bit us before). Knob selectable.
2. **Vision** — glasses photo → VLM → spoken description. The real payoff.
3. **Features on top** — translation, smart capture, identify-this, etc. now run free/private/offline.

## Pinned specifics (researched 2026-06)

**MLX Swift package (SPM, not pods):**
```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3"))
```
Products: **MLXLLM**, **MLXVLM**, **MLXLMCommon**. (MLXLLM/MLXVLM moved out of
`mlx-swift-examples` into this reusable-libraries repo.) Swift 6 / Xcode 16+; Metal GPU required.

**Gemma 4 — the target model family (text + image + audio + video, 128K context, native
function calling / JSON output, Apache-2):**

| Variant | Effective params | MLX 4-bit on-disk | HF repo |
|---------|------------------|-------------------|---------|
| **E2B** | 2.3B (5.1B w/ embeds) | **~3.6 GB** | `mlx-community/gemma-4-e2b-it-4bit` |
| **E4B** | 4.5B (8B w/ embeds)   | **~5.2 GB** | `mlx-community/gemma-4-e4b-it-4bit` |

Both fit the 17 Pro (~12GB) with headroom. **E2B = faster/snappier (recommended default for a
voice assistant); E4B = higher quality.**

**⚠️ Key risk — Gemma 4 model type is NOT yet upstream in `mlx-swift-lm`.** The reusable repo
ships Gemma **3** out of the box; Gemma **4** needs the `"gemma4"` / `"gemma4_text"` model types
registered via the community port [`VincentGourbin/gemma-4-swift-mlx`](https://github.com/VincentGourbin/gemma-4-swift-mlx)
(built on `mlx-swift` + `mlx-swift-lm`, **macOS-validated; iOS not yet confirmed**). So Gemma 4 on
iOS is bleeding edge and needs validation/porting.

**Fallback path (lower risk):** **Gemma 3 (4B) VLM**, which `mlx-swift-lm` supports today on iOS
— proven, slightly older, smaller capability set (no audio).

**Tool calling:** Gemma 4 does native function calling and can respond in JSON without special
prompting — format to be validated against our tool plumbing in Phase 1.

**Still to settle during build:** thermals/battery on sustained A19 Pro inference + unload-on-
background policy; multi-GB first-run download UX (progress, Wi-Fi-only gating).

## Implementation path (verified against the reference package)

**Depend on `Gemma4Swift` directly** (don't hand-port the registration). It's a consumable SwiftPM
library that registers `gemma4` into `mlx-swift-lm` and exposes a clean pipeline:

```
.package(url: "https://github.com/VincentGourbin/gemma-4-swift-mlx", branch: "main")
```
- Platforms: **macOS 15 / iOS 17** (✅ iOS supported). Our app is iOS 16 → **bump the deploy target
  to 17 for this feature, or gate the Local backend behind `if #available(iOS 17)`**.
- Transitive deps: `mlx-swift`, `swift-transformers`, **`mlx-swift-lm` (main, unpinned)**,
  `swift-mlx-profiler`. ⚠️ Note the unpinned `main` dependency — pin our own resolved version.

**Confirmed public API (`@MainActor @Observable final class Gemma4Pipeline`):**
```swift
let pipeline = Gemma4Pipeline()
try await pipeline.load(.e2b4bit, downloadIfNeeded: true) { p in /* p.fraction */ }
// text:
let answer = try await pipeline.chat(prompt:, systemPrompt:, temperature: 0.3, maxTokens: 1024)
let stream = try pipeline.chatStream(prompt:, ...)            // AsyncThrowingStream<String,Error>
let next   = try await pipeline.continueChat(prompt:)         // multi-turn
// vision:
let s = try pipeline.chatStreamMultimodal(prompt:, pixelValues: MLXArray, ...)
```

**Phase-1 (text) uses only confirmed-public calls** → low risk, ready to scaffold.

**Phase-2 (vision) caveat — the one real unknown:** `chatStreamMultimodal` wants a **pre-processed
`MLXArray` of pixel values**, not a `UIImage`. `CGImageLoader.load(from:)` is public (→ `CGImage`),
but the `CGImage → pixelValues` step lives in `Gemma4UnifiedImageProcessor` / `Gemma4Processor`,
which **may be internal**. If so, options: (a) fork to expose it, (b) replicate Gemma-4 image
preprocessing ourselves, or (c) use MLXVLM's own processor. **Resolve before committing to vision.**

## Phase 1 — scaffolded (this branch), needs on-device build to validate

**What landed on `feat/local-gemma-backend`:**
- `AppSettings`: `localGemma` enum case (knob auto-appears), `localGemmaModelId`, `localGemmaModelReady`.
- `Services/GemmaLocal/GemmaLocalService.swift` — backend wrapper (load/unload/generate/interrupt),
  registers `gemma4` into `LLMTypeRegistry`, streams via `MLXLMCommon.generate`.
- `Services/GemmaLocal/Vendor/Gemma4Text.swift` — the MIT model port (verbatim) + its LICENSE.
- `Views/Settings/GemmaSettingsView.swift` — model download/manage UI; sets `localGemmaModelReady`.
- `AIBackendSettingsView` — "Local Gemma" config link with ready badge.
- `VoiceAgentView` — all 6 backend `switch` sites wired (connect/disconnect/interrupt/send) +
  response callbacks (`onAgentMessage` → TTS, `onProcessingChanged` → state).
- `project.yml` — `mlx-swift-lm` @ 3.31.3 (products MLXLLM, MLXLMCommon); deploy target 16 → 18.

**Chose to vendor only `Gemma4Text.swift`** (not the upstream's `MLXService`/`ChatMessage`) — the
latter ship a SwiftData `Conversation` that collides with our model; the loader logic was rewritten
in `GemmaLocalService` instead.

**Cannot be built in this environment** (needs Xcode + a physical iPhone 17 Pro + a multi-GB model
download). First on-device build should verify these API touch-points against mlx-swift-lm 3.31.3:
- `LLMModelFactory.shared.loadContainer(configuration:) { progress in … }` (default hub)
- `LLMTypeRegistry.shared.registerModelType("gemma4") { data in … }`
- `Chat.Message(role:content:)`, `UserInput(chat:)`, `GenerateParameters(temperature:)`
- the generation stream's element type (`Generation.chunk(String)` — confirm the case name)
- `MLX` / `MLXNN` import transitively via the two products (else add `mlx-swift` explicitly)
- SPM platform resolution at iOS 18 (revert to 16 + `@available` gate if older support is wanted)
