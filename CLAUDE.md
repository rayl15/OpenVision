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

2. Fill in Config.xcconfig:
   - `DEVELOPMENT_TEAM` - Your Apple Team ID
   - `META_APP_ID` - From Meta Developer Console
   - `CLIENT_TOKEN` - Format: `AR|APP_ID|TOKEN`

3. Open `OpenVision.xcodeproj` in Xcode

4. Build and run on physical iOS device

5. Register glasses: Settings → Glasses → Register

6. Configure AI: Settings → AI Backend

## Architecture

- MVVM + Services pattern
- @MainActor for thread safety
- Callback-based events (not Combine publishers)
- Singleton managers

## Key Files

### Services
- `Services/OpenClaw/OpenClawService.swift` - WebSocket client with auto-reconnect
- `Services/GeminiLive/GeminiLiveService.swift` - Native audio/video WebSocket
- `Services/Voice/VoiceCommandService.swift` - Wake word detection ("Ok Vision")
- `Services/Audio/AudioCaptureService.swift` - Microphone input for Gemini
- `Services/Audio/AudioPlaybackService.swift` - Speaker output for Gemini
- `Services/TTS/TTSService.swift` - Apple TTS for OpenClaw mode

### Managers
- `Managers/GlassesManager.swift` - DAT SDK wrapper (registration, streaming, photos)
- `Managers/SettingsManager.swift` - JSON persistence with debounce
- `Managers/ConversationManager.swift` - Chat history (not yet wired up)

### Views
- `Views/VoiceAgent/VoiceAgentView.swift` - Main conversation UI (~1100 lines)
- `Views/Settings/SettingsView.swift` - Configuration navigation
- `Views/MainTabView.swift` - Tab navigation

## AI Backends

### OpenClaw Mode (Default)
- Wake word: "Ok Vision"
- Text-based: Apple STT → OpenClaw WebSocket → Apple TTS
- 56+ tools available
- Better privacy (only listens after wake word)
- Photo capture on request

### Gemini Live Mode
- Activated by: "start video streaming"
- Native audio (no STT/TTS needed)
- Continuous 1fps video streaming from glasses
- Lower latency (~300ms vs ~1-2s)
- Exit with: "stop video"

## Important Patterns

### Connection Management
- OpenClaw: 12 reconnection attempts with exponential backoff (1s → 30s)
- Network monitoring via NWPathMonitor (auto-suspend on WiFi drop)
- App lifecycle handling (suspend on background, resume on foreground)

### Voice Flow
1. Wake word detection in `.idle` state
2. Transition to `.listening` → capture command
3. Silence detection (1.5s) ends capture
4. Transition to `.processing` → send to AI
5. AI response → TTS playback
6. Enter conversation mode (follow-ups without wake word)

### Glasses Integration
- Registration opens Meta AI app for OAuth
- URL callback handled in `OpenVisionApp.handleUrl()`
- StreamSession for camera: video frames + photo capture
- Use `SpecificDeviceSelector` for reliable streaming

## Configuration Files

### Config.xcconfig (Build-time, gitignored)
```
DEVELOPMENT_TEAM = ABC123XYZ
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.openvision
META_APP_ID = 1234567890
CLIENT_TOKEN = AR|1234567890|abcdef123456
APP_LINK_URL_SCHEME = openvision
```

### Config.swift (Runtime, gitignored)
- Optional default API keys
- Leave empty to require in-app configuration

### settings.json (Documents/, runtime)
- User preferences and API keys
- Auto-saved with 0.5s debounce

## Voice Commands

| Command | Action |
|---------|--------|
| "Ok Vision" | Wake word - activates listening |
| "Ok Vision stop" | Interrupt AI while speaking |
| "Take a photo" | Capture from glasses camera |
| "Start video streaming" | Switch to Gemini Live mode |
| "Stop video" | Exit Gemini Live mode |

## Common Issues

### Glasses Registration Fails
- Check `CLIENT_TOKEN` format: must be `AR|APP_ID|TOKEN`
- Ensure Meta AI app is installed with Developer Mode enabled

### CheckedContinuation Crash
- Ensure continuations are only resumed once
- Use `removeValue(forKey:)` pattern to prevent double-resume

### Gemini Transcribes Wrong Language
- Added Hindi fallback keywords for stop commands
- Gemini sometimes transcribes English as Hindi

## SDK References

- Meta DAT: https://github.com/facebook/meta-wearables-dat-ios
- Gemini Live: https://ai.google.dev/gemini-api/docs/live-api
