# Changelog

All notable changes to OpenVision will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of OpenVision
- Dual AI backend support (OpenClaw + Gemini Live)
- Wake word activation ("Hey Vision") for privacy-focused voice control
- Meta Ray-Ban smart glasses integration via DAT SDK
- iPhone camera fallback for testing without glasses
- Beautiful glassmorphism UI with dark mode
- Auto-reconnect with exponential backoff (12 attempts, 1s → 30s)
- Network monitoring (pause on WiFi drop)
- Conversation history with persistence
- Memory management (AI can remember user preferences)
- In-app configuration (no hardcoded API keys)
- Text-to-speech for OpenClaw mode responses
- Barge-in support (interrupt AI while speaking)
- Animated onboarding experience
- Real-time audio waveform visualizer

### Technical
- MVVM + Services architecture
- WebSocket for OpenClaw (persistent connection vs HTTP)
- 20-second heartbeat ping/pong for connection health
- Debounced settings auto-save (0.5s)
- @MainActor isolation for thread safety
- Comprehensive documentation (README, SETUP, CONTRIBUTING)

## [1.0.0] - 2024-XX-XX

### Added
- First stable release

---

## Version History

### Planned Features

- [ ] Siri Shortcuts integration
- [ ] Apple Watch companion app
- [ ] Widget for quick access
- [ ] Custom TTS voices
- [ ] Offline mode with on-device models
- [ ] Multiple wake word options
- [ ] Conversation export (PDF, Markdown)
- [ ] iCloud sync for settings and history
