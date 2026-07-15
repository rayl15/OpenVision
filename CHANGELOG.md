# Changelog

All notable changes to OpenVision will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
