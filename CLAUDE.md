# OpenVision

Open-source iOS app connecting Meta Ray-Ban glasses to AI assistants (OpenClaw + Gemini Live).

## Stack

- Swift 5 / SwiftUI
- Meta Wearables DAT SDK (MWDATCore, MWDATCamera)
- WebSocket (URLSessionWebSocketTask)
- Apple Speech Recognition
- AVAudioEngine for audio I/O

## Quick Start

1. Copy config files:
   - `Config.xcconfig.example` → `Config.xcconfig`
   - `OpenVision/Config/Config.swift.example` → `OpenVision/Config/Config.swift`

2. Fill in your Meta App ID in `Config.xcconfig`

3. Open `OpenVision.xcodeproj` in Xcode

4. Build and run on physical iOS device

5. Configure AI backend in app: Settings → AI Backend

## Architecture

- MVVM + Services pattern
- @MainActor for thread safety
- Combine for reactive state
- Pluggable AI backends via protocol

## Key Files

### Services
- `Services/OpenClaw/OpenClawService.swift` - WebSocket client with auto-reconnect (12 attempts, exponential backoff)
- `Services/GeminiLive/GeminiLiveService.swift` - Native audio WebSocket for Gemini Live
- `Services/Voice/VoiceCommandService.swift` - Wake word detection ("Hey Vision")
- `Services/Audio/AudioCaptureService.swift` - Microphone input via AVAudioEngine
- `Services/Camera/GlassesCameraService.swift` - DAT SDK camera streaming

### Managers
- `Managers/SettingsManager.swift` - JSON persistence with 0.5s debounce
- `Managers/GlassesManager.swift` - DAT SDK wrapper for glasses registration/connection
- `Managers/ConversationManager.swift` - Chat history persistence

### Views
- `Views/MainTabView.swift` - Tab navigation (Voice, History, Settings)
- `Views/VoiceAgent/VoiceAgentView.swift` - Main conversation UI
- `Views/Settings/SettingsView.swift` - Configuration panels

## AI Backends

### OpenClaw Mode
- Wake word activation ("Hey Vision")
- Text-based: STT → OpenClaw → TTS
- 56+ tools via WebSocket
- Better privacy (only listens after wake word)
- Best for: Tasks, tools, control

### Gemini Live Mode
- Always listening (native VAD)
- Native audio: speech-to-speech
- Continuous 1fps video streaming
- Lower latency
- Best for: Continuous conversation

## Patterns

- **Listener tokens**: Retained for DAT SDK subscriptions
- **Debounced saves**: 0.5s debounce for settings changes
- **Exponential backoff**: 1s → 30s over 12 reconnection attempts
- **Network monitoring**: NWPathMonitor pauses connection on WiFi drop
- **@MainActor isolation**: All managers and services are MainActor-isolated

## Configuration

### Settings Storage
- File: `Documents/settings.json`
- Model: `AppSettings` struct (Codable)
- Debounced auto-save on property changes

### Build Configuration
- `Config.xcconfig`: Bundle ID, Team ID, Meta App ID
- `Config.swift`: Optional default API keys (can be empty)

## Testing

- Run tests: Cmd+U in Xcode
- Mock services in `Tests/Mocks/`
- iPhone camera mode for testing without glasses
- Mock device support via MWDATMockDevice

## SDK Documentation

### Meta Wearables DAT
- GitHub: https://github.com/facebook/meta-wearables-dat-ios
- Developer Center: https://developer.meta.com/docs/wearables

### OpenClaw
- GitHub: https://github.com/openclaw/openclaw
- Docs: https://openclaw.ai/docs

### Gemini Live
- Docs: https://ai.google.dev/gemini-api/docs/live-api
