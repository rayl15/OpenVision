# Changelog

All notable changes to OpenVision will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **OpenClaw backend can now reach a gateway on the local network.** Previously only a gateway on localhost worked: the handshake negotiated protocol 3 (current gateways speak 4), sent no role or scopes, and presented no device identity — so `chat.send` failed with `missing scope: operator.write` even though the connection itself succeeded. The app now signs an Ed25519 device identity (persisted in the Keychain) that the gateway holds as a pairing request; approve it once with `openclaw devices approve <requestId>`. See SETUP.md
- Reconnecting to an OpenClaw gateway no longer fails with `device nonce mismatch`. Each socket gets its own `connect.challenge` nonce and the signature covers it, so caching the first one meant the initial connection after launch succeeded and every reconnect afterwards failed
- Added `NSLocalNetworkUsageDescription`, without which iOS silently blocks connections to a LAN gateway rather than prompting for consent

## [2.11.0] - 2026-08-15

### Added
- **Continuous live vision** — in local live video mode (FastVLM/SmolVLM2), the assistant now watches the glasses feed continuously: it describes each new scene once your view settles, keeps that as silent context on screen, and uses it to ground your questions instantly. It only *speaks* when you ask — say **"start narrating"** for spoken scene descriptions (accessibility), "stop narrating" to go quiet again
- **Acoustic voice-activity detection** — end-of-turn is now detected from the microphone signal (on-device Silero VAD on the Neural Engine) instead of a fixed 4-second silence timer. Finish a sentence and the assistant responds in about a second; pause mid-thought and it waits
- **Kokoro streaming** — with the Kokoro voice selected, replies are now spoken sentence-by-sentence while the model is still writing (~1.2s faster per turn), with strict ordering and interruption-safe playback
- **Self-hosted telemetry** (opt-in, off by default) — per-turn latency breakdown (endpointing / time-to-first-token / generation / speech), tokens/sec, success and interruption rates, device health (memory, thermal, jetsam headroom), pushed to your own InfluxDB with a provisioned Grafana dashboard (`telemetry/docker-compose.yml`). Numbers only — never transcripts or prompts

### Changed
- **Bonsai 8B gets a concise routing prompt** (60% shorter), roughly halving its time-to-first-token; smaller models keep the fully-worked-examples prompt they need
- The local backend keeps a KV prefix cache across turns, so the routing prompt is processed once per session instead of every turn
- Live-mode questions answer against the freshest camera frame with the watch loop's recent description attached as grounding

### Fixed
- Replies are no longer cut off mid-sentence by background narration; ambient speech can only ever speak into silence
- Voice replies with Kokoro no longer play sentences out of order
- A reply could be dropped entirely when generation finished before the first sentence's synthesis
- Numerous telemetry corrections (honest audio-start timing, exact library-reported token counts, per-model tagging) — see commit history for the full audit

## [2.10.0] - 2026-08-14

### Added
- **Bonsai 8B** local model — an 8B-parameter model (1-bit quantized Qwen3-8B) that runs on-device in **1.28 GB**, a third of Gemma 4 E2B's footprint, with a stronger base for following instructions. Text-only; vision stays on SmolVLM2 / FastVLM

### Changed
- `mlx-swift` now resolves to the [PrismML fork](https://github.com/PrismML-Eng/mlx-swift) (pinned to `v0.31.6_prism`), which supplies the 1-bit Metal kernels that upstream mlx-swift does not have yet. All existing local models and the vendored Kokoro TTS run unchanged against it
- **Building now requires the Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`) and `-skipPackagePluginValidation` — see [SETUP.md](SETUP.md)

### Fixed
- Apple Intelligence web search no longer overflows the model's 4096-token context — the Tavily payload is capped and the session retries on failure (#53)

## [2.9.0] - 2026-07-26

### Added
- **Document RAG** — import PDFs and text files, then ask grounded questions about them entirely on-device (embedding-based retrieval, no cloud). Includes a `search_docs` tool and **focus mode**: "open my \<doc\>" pins a document so every following question is answered from it (#52)
- **POV session recording** — record the glasses' point of view (video + scene audio + the assistant's spoken replies) straight to Photos, for demo clips (#50)

### Changed
- Local vision turns now carry document context, and the previous model's memory is freed before a new one loads (prevents jetsam kills when switching models)
- Kokoro TTS synthesizes per sentence rather than per reply — a long reply could previously spike memory past the jetsam limit and kill the app

### Fixed
- Wake-word reliability: canceled speech-recognition tasks no longer deliver stale callbacks that tore the recognizer down roughly once a second and shredded commands
- The recognizer now restarts from both idle and conversation modes, so the app can no longer sit deaf after a recognizer death

## [2.8.0] - 2026-07-18

### Added
- **Native productivity tools** — timers, pomodoro, reminders, calendar events, GPS+time tagged notes, and clipboard, all by voice, across four AI backends (#48)
- **On-device Gemma 4 E2B** with native tool-calling, joining the local model lineup (#48)
- First automated test suite (31 tests) covering date math, routing, and parsing (#49)
- README badges and modern GitHub issue forms (#43)

### Changed
- Architecture refactor to MVVM behind an `AIBackend` protocol — views render, view models orchestrate, and adding a backend is now a conformance plus two lines. Extension guides in [docs/architecture.md](docs/architecture.md) (#49)
- Relative time requests ("in 15 minutes") are resolved in code rather than trusted to the model, which routinely got absolute times wrong (#48)

## [2.7.0] - 2026-07-15

### Added
- Complete emerald UI redesign: a new animated "swirl" assistant orb with distinct idle / listening / thinking / speaking states, an emerald-on-black theme, and floating transcript bubbles (#30)
- Working conversation history — every voice and live-video exchange is recorded (transcript only; camera frames are never stored), with search, swipe-to-delete, and resumable conversations (#34)
- Session memory that survives across wake-ups within a conversation, so follow-ups like "what were we just talking about?" work (#34)
- Per-model capability hints in the Local Models picker to make the memory-vs-speed trade-off clear (#35)
- Pull request template (#41)

### Changed
- Local model management overhaul: byte-accurate download progress (no more 0% → 100% jump), accurate per-model on-disk sizes, per-model delete, and a durable model store in Application Support that survives app updates and storage pressure — previously downloaded weights could be silently purged from Caches and re-downloaded (#31)
- Switching between already-downloaded local models now takes effect immediately (#31)
- README: new emerald banner and a single screenshot montage (#32)

### Fixed
- Replies no longer get cut off mid-speech by phantom "Ok Vision" wake-word matches or over-eager barge-in (#30)
- The UI no longer flips to "Listening" while the assistant is still speaking (#30)
- Reclaimed orphaned multi-GB model-download temp files on launch (#31)

### Dev
- CodeRabbit AI code review enabled on pull requests (#33)

## [2.6.0] - 2026-07-11

### Added
- Apple FastVLM 0.5B as an on-device vision model — fastest real-time vision (#25)
- Fresher live-video frames and a grounding prompt to reduce vision hallucinations (#25)

### Fixed
- API keys now persist across app updates; correct local-model label shown (#26)

## [2.5.0] - 2026-07-11

### Added
- Streaming Apple TTS for on-device replies — speaks while generating (#21)
- Wake-word chime plays on the glasses without a Bluetooth blip on repeats (#22)

### Fixed
- "Ok Vision stop" now fully stops instead of looping in listening (#23)

## [2.4.0] - 2026-07-11

### Added
- On-device vision with SmolVLM2 — photos and fully-local live video (#17)
- OpenAI Realtime live-video backend (gpt-realtime)

### Fixed
- App version now displays correctly (#18)

## [2.3.x]

### Added
- On-device neural TTS (Kokoro-82M via MLX)
- Local model picker and smarter web search (Tavily live search)
- Glasses Bluetooth mic + wake word that survives camera use

## [2.0.0 – 2.3.0]

Earlier releases established the foundation: Meta Ray-Ban integration via the DAT SDK, OpenClaw + Gemini Live + Apple Intelligence backends, wake-word voice control, conversation history and memory, glassmorphism UI, auto-reconnect with backoff, and fully in-app configuration (no hardcoded keys).

---

## Roadmap

Community proposals and good-first-issues live in [the issue tracker](https://github.com/rayl15/OpenVision/issues). Current directions:

- [ ] Battery- and thermal-aware power modes ([#36](https://github.com/rayl15/OpenVision/issues/36))
- [ ] Siri Shortcuts integration
- [ ] Conversation export (Markdown)
- [ ] iCloud sync for settings and history
- [ ] Apple Watch companion app
