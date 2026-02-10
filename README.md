# OpenVision 👓

The open-source iOS app connecting Meta Ray-Ban smart glasses to AI assistants.

> **Your glasses. Your AI. Your rules.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Swift 5](https://img.shields.io/badge/Swift-5-orange.svg)](https://swift.org)
[![iOS 16+](https://img.shields.io/badge/iOS-16+-blue.svg)](https://developer.apple.com/ios/)

## Features

### Dual AI Backend Support
- **OpenClaw Mode**: Wake word activation, 56+ tools, task execution via WebSocket
- **Gemini Live Mode**: Real-time voice + vision with native audio streaming

### Smart Voice Control
- Wake word activation ("Ok Vision") for privacy
- Barge-in support - interrupt AI anytime by saying "Ok Vision"
- Conversation mode - follow-up questions without wake word
- "Ok Vision stop" - stop AI mid-speech

### Glasses Integration
- Photo capture on voice command ("take a photo")
- Live video streaming to Gemini (1fps)
- Seamless glasses registration via Meta AI app

### Production-Ready
- Auto-reconnect with exponential backoff (12 attempts)
- Network monitoring (auto-pause on WiFi drop)
- App lifecycle handling (suspend/resume connections)
- Secure credential storage

### Zero Hardcoding
- All API keys configurable in-app
- No code changes needed to use
- Example config files included

---

## Screenshots

<p align="center">
  <img src="docs/images/voice-interface.png" width="180" alt="Voice Interface"/>
  &nbsp;&nbsp;
  <img src="docs/images/settings.png" width="180" alt="Settings"/>
  &nbsp;&nbsp;
  <img src="docs/images/ai-backend.png" width="180" alt="AI Backend Selection"/>
  &nbsp;&nbsp;
  <img src="docs/images/glasses-settings.png" width="180" alt="Glasses Settings"/>
</p>

| Screen | Description |
|--------|-------------|
| **Voice Interface** | Main conversation screen with wake word prompt, waveform visualizer, and quick actions (camera, settings) |
| **Settings** | Configure AI backend, glasses, voice control, and advanced options |
| **AI Backend** | Choose between OpenClaw (tools & privacy) or Gemini Live (low latency) |
| **Glasses** | Register glasses with Meta AI, view device status, control camera streaming |

---

## Quick Start

### Prerequisites

- macOS with Xcode 15+
- Physical iOS 16+ device (simulator doesn't support Bluetooth)
- Meta Ray-Ban smart glasses
- Meta Developer account for glasses registration
- One of:
  - [OpenClaw](https://github.com/openclaw/openclaw) instance
  - [Gemini API key](https://aistudio.google.com/app/apikey)

### Step 1: Clone & Configure

```bash
git clone https://github.com/anthropics/OpenVision.git
cd OpenVision/meta-vision

# Copy config templates
cp Config.xcconfig.example Config.xcconfig
cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
```

### Step 2: Get Meta Credentials

1. Go to [Meta Developer Console](https://developer.meta.com)
2. Create an app or use existing one
3. Enable "Wearables" capability
4. Copy your **App ID** and **Client Token**

### Step 3: Edit Config.xcconfig

```bash
# Your Apple Team ID (from Xcode or Apple Developer Portal)
DEVELOPMENT_TEAM = ABC123XYZ

# Your app's bundle identifier
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.openvision

# Meta App ID from developer console
META_APP_ID = 1234567890

# Client Token - MUST be in this format: AR|APP_ID|TOKEN
CLIENT_TOKEN = AR|1234567890|abcdef123456789

# URL scheme for Meta AI callback
APP_LINK_URL_SCHEME = openvision
```

### Step 4: Build & Run

```bash
open OpenVision.xcodeproj
```

1. Select your iOS device (not simulator)
2. Build and run (⌘R)
3. On first launch, go to **Settings → Glasses → Register**
4. This opens Meta AI app to grant access
5. Return to OpenVision

### Step 5: Configure AI Backend

**For Gemini Live:**
1. Get API key from [AI Studio](https://aistudio.google.com/app/apikey)
2. Settings → AI Backend → Gemini Settings
3. Paste your API key

**For OpenClaw:**
1. Install [OpenClaw](https://github.com/openclaw/openclaw)
2. Settings → AI Backend → OpenClaw Settings
3. Enter gateway URL and auth token

---

## Usage

### OpenClaw Mode (Default)

```
You: "Ok Vision"                    → Wake word activates listening
You: "What's the weather today?"    → AI processes and responds via TTS
You: "Take a photo"                 → Captures from glasses, analyzes
You: "Ok Vision stop"               → Interrupts AI mid-speech
[Silence for 30s]                   → Conversation ends
```

### Gemini Live Mode

```
You: "Ok Vision, start video streaming"  → Switches to Gemini Live
[Camera streams at 1fps to Gemini]
You: "What am I looking at?"             → Gemini sees and responds
You: "Stop video"                        → Returns to OpenClaw mode
```

### Voice Commands

| Command | Action |
|---------|--------|
| "Ok Vision" | Activate listening (wake word) |
| "Ok Vision stop" | Stop AI while speaking |
| "Take a photo" | Capture and analyze view |
| "What do you see?" | Describe current view |
| "Start video streaming" | Switch to Gemini Live mode |
| "Stop video" | Exit Gemini Live mode |

---

## AI Backend Comparison

| Feature | OpenClaw | Gemini Live |
|---------|----------|-------------|
| **Voice Input** | Wake word + Apple STT | Native VAD (always on) |
| **Voice Output** | Apple TTS | Native audio stream |
| **Vision** | Photo on request | Continuous 1fps video |
| **Tools** | 56+ skills | Limited |
| **Privacy** | Better (wake word) | Always listening |
| **Latency** | ~1-2s | ~300-500ms |
| **Best For** | Tasks, tools, control | Natural conversation |

---

## Settings

### AI Section
| Setting | Description |
|---------|-------------|
| **AI Backend** | Choose OpenClaw or Gemini Live |
| **OpenClaw Gateway** | WebSocket URL (e.g., `wss://localhost:18789`) |
| **OpenClaw Token** | Authentication token |
| **Gemini API Key** | Google API key |
| **Custom Instructions** | Additional system prompt (Gemini only) |
| **Memories** | Key-value context for AI (Gemini only) |

### Voice Section
| Setting | Description |
|---------|-------------|
| **Wake Word** | Activation phrase (default: "Ok Vision") |
| **Wake Word Enabled** | Toggle wake word requirement |
| **Activation Sound** | Play chime on wake word |
| **Conversation Timeout** | Auto-end after silence (15s-2min) |

### Hardware Section
| Setting | Description |
|---------|-------------|
| **Glasses Registration** | Register/unregister with Meta AI |
| **Connection Status** | View connected devices |
| **Camera Controls** | Manual stream start/stop |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        OpenVision App                           │
├─────────────────────────────────────────────────────────────────┤
│  Views (SwiftUI)                                                │
│  ├── VoiceAgentView      Main conversation interface            │
│  ├── SettingsView        Configuration panels                   │
│  └── HistoryView         Past conversations                     │
├─────────────────────────────────────────────────────────────────┤
│  Services                                                       │
│  ├── OpenClawService     WebSocket client, auto-reconnect       │
│  ├── GeminiLiveService   Native audio/video WebSocket           │
│  ├── VoiceCommandService Wake word detection, Apple STT         │
│  ├── TTSService          Text-to-speech for OpenClaw            │
│  ├── AudioCaptureService Microphone input for Gemini            │
│  └── AudioPlaybackService Speaker output for Gemini             │
├─────────────────────────────────────────────────────────────────┤
│  Managers                                                       │
│  ├── GlassesManager      Meta DAT SDK wrapper                   │
│  ├── SettingsManager     JSON persistence with debounce         │
│  └── ConversationManager Chat history storage                   │
├─────────────────────────────────────────────────────────────────┤
│  External                                                       │
│  ├── Meta DAT SDK        Glasses camera & registration          │
│  ├── Apple Speech        Speech recognition                     │
│  └── AVFoundation        Audio capture & playback               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Glasses won't register
- Ensure Meta AI app is installed and you're signed in
- Enable Developer Mode in Meta AI app settings
- Check that your Meta App ID matches the developer console

### "Configuration Invalid" error
- Verify `CLIENT_TOKEN` format: `AR|APP_ID|TOKEN`
- Check all Config.xcconfig values are filled in
- Ensure bundle ID matches what's in Meta Developer Console

### No audio from glasses
- Check Bluetooth connection in iOS Settings
- Ensure glasses are set as audio output device
- Try disconnecting and reconnecting glasses

### Gemini Live fails to connect
- Verify API key is correct
- Check internet connection
- Ensure you have Gemini API access (not all regions supported)

### OpenClaw connection drops
- App auto-reconnects up to 12 times with exponential backoff
- Check if OpenClaw server is running
- Verify gateway URL uses `wss://` (not `ws://`) for secure connection

---

## Development

### Project Structure

```
OpenVision/
├── App/                    App entry point, URL handling
├── Config/                 Configuration files
├── Models/                 Data models (Settings, Conversation)
├── Services/
│   ├── AIBackend/          Connection state, errors
│   ├── OpenClaw/           WebSocket client
│   ├── GeminiLive/         Native audio WebSocket
│   ├── Voice/              Wake word, STT
│   ├── Audio/              Capture & playback
│   └── TTS/                Text-to-speech
├── Managers/               Singletons (Settings, Glasses)
├── Views/
│   ├── VoiceAgent/         Main UI
│   ├── Settings/           Config screens
│   ├── History/            Chat history
│   └── Components/         Reusable UI
└── Utilities/              Extensions, helpers
```

### Key Patterns

- **@MainActor** - All managers and services are main-actor isolated
- **Callbacks** - Services use callbacks (not Combine) for events
- **Singleton managers** - GlassesManager, SettingsManager, etc.
- **Exponential backoff** - OpenClaw reconnects with jittered delay

### Building

```bash
# Build for device
xcodebuild -scheme OpenVision -destination 'platform=iOS,name=iPhone' build

# Install on connected device
xcrun devicectl device install app --device <DEVICE_ID> \
  ~/Library/Developer/Xcode/DerivedData/.../OpenVision.app
```

---

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Style

- Follow Swift API Design Guidelines
- Use `@MainActor` for UI-related code
- Add documentation comments for public APIs
- Keep services focused and single-responsibility

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Acknowledgments

- [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios) - Glasses integration
- [Google Gemini](https://ai.google.dev) - Live audio/video AI
- [OpenClaw](https://github.com/openclaw/openclaw) - AI assistant framework

---

**Built with Swift and ❤️**
