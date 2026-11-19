# Changelog

All notable changes to OpenVision will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed (meeting notes, from the PR #76 review)
- "Don't record this meeting" started recording: a start command may now contain only the phrase and filler words
- New words after a stop phrase ("…stop transcribing, please") now restart the 1.5 s pause instead of stopping early
- After a re-summary, Add to Reminders lost its tick (the action item's id changed), so the same reminder could be added twice
- The storage-failure warning could be cut off by the next spoken notice
- The Meetings tab named Hermes/OpenClaw as the summary writer (it's Apple Intelligence) and didn't update when the backend changed
- Privacy notes now cover OpenAI-compatible base URLs, ChatGPT sign-in (chatgpt.com), the cloud request made before an Apple Intelligence fallback, the Hermes/OpenClaw fallback, and the spoken recap going to a cloud voice
- Add to Reminders' fallback match after a re-summary now requires the same task, owner and due date, so another person's item can't be ticked
- A stop flow still speaking a warning can no longer speak over, or summarise during, a meeting started meanwhile

### Changed (docs)
- README and SETUP: current Wearables Developer Center steps (Apple Team ID and Camera access fields), **Install/Update Glasses App** after registering, and a "Device unavailable" troubleshooting entry

### Fixed (meeting notes, from the PR #75 review)
- A stop phrase in the middle of a sentence ("we should stop transcribing invoices manually") ended the meeting and cut the transcript; stop phrases now count only at the end of what was said, after a 1.5 s pause
- A start phrase anywhere in a command ("remind me to record the meeting at 3") started recording; it now has to be the command itself, give or take a filler word
- Deleting a meeting while its summary was being written (or while Add to Reminders ran) brought it back
- A meeting file that couldn't be written was reported as saved; now you're told, and it stays in the Meetings tab until the app quits so it can be shared
- Summaries failed on newer OpenAI models that reject `max_tokens`
- A watchdog restart dropped up to ~3 s of audio; the new recognizer now starts before the old one is retired
- The docs and settings now say plainly that the transcript text goes to a cloud backend for the summary (audio and transcription stay on the phone)

### Added
- **Meeting notes** — "Ok Vision, start taking notes" (or **Start** in the new **Meetings** tab) transcribes a meeting on the phone and, when you say "stop taking notes", writes a summary with a title, decisions and action items using the current AI backend, then reads a short recap aloud. Speech recognition runs on the phone (Apple's on-device `SpeechAnalyzer` on iOS 26+, on-device `SFSpeechRecognizer` for English otherwise) and audio is never uploaded; the transcript text goes to the selected AI backend for the summary, which is a cloud provider for OpenAI, Grok and Gemini
- **Meeting languages** — Settings → Voice → Meeting Notes → Language: English, **Hindi**, **Hinglish** (Apple's `mul_IN` multilingual model, for meetings that switch languages mid-sentence) and 10 more Indian languages, with Hindi and Hinglish stop phrases. A language's speech model downloads once, with progress; meeting audio is never sent to Apple's servers instead
- **Meetings tab** — live transcript and timer, open action items across meetings, meetings grouped by day, search, share, re-summarise, delete, and **Add to Reminders** per action item
- **`meetings` tool** on OpenAI, Grok, Gemini Live, Apple Intelligence and Gemma: "what did we decide this morning?", "what are my action items?"
- `AIBackend.completeText(system:prompt:)` — one-off text with no history or tools, implemented for OpenAI (API key and ChatGPT subscription), Grok, Gemini (REST, same key), Apple Intelligence and Gemma; plus `textContextTokens` and `canWriteLanguage(_:)` so callers can size requests and pick an output language
- Meeting notes mic setting: phone (default, hears the room) or glasses

### Changed
- Apple Intelligence requests are sized from the model's reported context window (`SystemLanguageModel.contextSize`, 8,192 tokens on iOS 27) instead of assuming 4,096
- `VoiceCommandService` can be suspended, so the wake-word listener can't start alongside another mic user

### Reliability (meeting notes)
- Saved every 30 s; a meeting cut off by a crash reopens with its transcript and is summarised automatically
- Watchdog: re-arms a silent mic, restarts a recognizer that ends or stalls (20 s of speech with no text), keeps unfinished words across restarts, and never lets a stuck recognizer hang "stop"
- Summaries that need on-device AI while the phone is locked are written automatically the next time the app is opened
- Once-a-minute health log (words, restarts, memory, CPU, thermal state, battery, foreground/background) for soak tests; counts only, never transcript text

### Known limitations
- Recording with the phone locked has not been verified on a device yet; a 5-minute foreground test ran at ~100–130 MB, ~25% CPU and nominal thermal state
- No speaker names (Apple's recognizers don't separate voices)
- The stop phrase must be said in English, Hindi or Hinglish; the Stop button works for every language

## [2.14.0] - 2026-10-02

### Added
- **Grok backend** — xAI Grok joins as the sixth backend, over xAI's public Chat Completions API with an xAI API key or a **SuperGrok subscription sign-in**. Photos from the glasses, web search, the native tools and conversation history all work through the same code as OpenAI (now shared in `CloudChat`). The model picker loads your account's live model list; default is the `grok-4.20-non-reasoning` alias (#61)
- **ChatGPT subscription sign-in for the OpenAI backend** — Settings → OpenAI gains a "Connect With" choice: API key, or sign in with your ChatGPT Plus/Pro account and use the subscription. OAuth with PKCE, tokens in the Keychain, single-flight rotation-safe refresh. Text, photos, web search and tools work; live video still needs an API key. Uses the Codex CLI's integration surface, so it is unofficial and could change without notice (#60)
- **Cloud voices** — two new speech engines next to Apple and Kokoro: **Grok** (28 multilingual voices, follows the reply's language) and **OpenAI** (`gpt-4o-mini-tts`, 13 voices; needs an API key with credits). Sentences are synthesized as they're written, at most three in flight, and played in order and gaplessly; the voice is mixed into session recordings like Kokoro's (#61)
- **Voice previews** — every neural engine's voice list has a play button per voice, so you can hear a voice before choosing it (#61)

### Changed
- `mlx-swift-lm` pin moved to upstream `14414441`, which fixes `MLXFoundationModels` against the Xcode 27 release SDK. **Building on Xcode 27 now works**; the Gemma 4 E2B loader fix is retained (#59)
- Kokoro and the cloud voices sit behind one `NeuralSpeechEngine` protocol, so stop, barge-in and the speaking state behave identically for every neural voice (#61)

### Fixed
- Ambient watch-loop narration could reset a streaming reply's speaking state mid-reply and let barge-in fire on the assistant's own voice; fixed for Kokoro and the cloud engines (#61)
- Player-node completion callbacks from a stopped reply can no longer decrement the buffer count of the reply that replaced it (#61)

### Known limitations
- OpenAI voice has not yet been verified on a device (no contributor had API credits); it shares the Grok playback path
- A cloud-voice sentence that fails to synthesize is skipped and logged rather than spoken by the Apple voice (#62)
- Signing in to ChatGPT on the phone appears to end a Codex CLI session for the same account, and vice versa

## [2.13.0] - 2026-08-17

### Changed
- **Meta DAT SDK 0.5.0 → 0.9.0** — newer glasses (Ray-Ban Meta Gen 2 "Blayzer Optics", Meta Glasses, Oakley Meta) were invisible because the pinned SDK predated the hardware. Migrated to the 0.9.0 camera lifecycle (`DeviceSession` → `addCamera` → `camera.stream`, session must reach `.started` first). Field-verified on Ray-Ban Meta Gen 1/2 and Blayzer Gen 2 (#55)
- **Required one-time setup for source builders**: in the Wearables Developer Center fill your Apple Team ID and toggle Camera access ON, then Unregister → Register in the app, then tap the new **Install/Update Glasses App** button. Requires glasses firmware V126+, Meta AI V282+, iOS 17.2+. See SETUP.md

### Added
- **Install/Update Glasses App** button in glasses settings, which stages the on-glasses developer component via Meta AI. Without it, sessions die with "Device unavailable" (#55)
- Session error-stream and device compatibility diagnostics (#55)

### Fixed
- Stream errors no longer pop a modal while the app is backgrounded; the raw codec pauses by design on screen lock (#55)

## [2.12.0] - 2026-08-15

### Added
- **Scene-identity context gating** for local live vision — cached descriptions, grounding hints and history are only injected when the current frame still shows the scene they came from, so a small VLM no longer repeats an old scene after a head-turn
- Wake word recognized mid-sentence while no audio is playing
- In live mode a bare **"stop"** silences speech and stays in live video; **"stop video"** exits. Stop matching is word-boundary aware ("desktop" no longer triggers it)
- In-flight scene descriptions are cancellable, so a question never queues behind one

### Changed
- Meta DAT SDK 0.4.0 → 0.5.0 (first step toward newer glasses; completed in 2.13.0)
- Live-vision answers run at 512px, temperature 0, with a rolling scene memory

### Fixed
- Barge-in now works with Kokoro TTS and while the agent is thinking; it was Apple-TTS-only
- "Please upload an image" refusal loop: vision questions outside live mode get spoken guidance instead of an imageless model call, and refusal turns are quarantined from history
- A `stopWords` redeclaration that collided with the fuzzy video-stop matcher

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
