# OpenVision 👓🦞

The open-source iOS app connecting Meta Ray-Ban smart glasses to AI assistants.

> **Your glasses. Your AI. Your rules.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Swift 5](https://img.shields.io/badge/Swift-5-orange.svg)](https://swift.org)
[![iOS 16+](https://img.shields.io/badge/iOS-16+-blue.svg)](https://developer.apple.com/ios/)

## Features

### 🤖 Dual AI Backend Support
- **OpenClaw Mode**: Wake word activation, 56+ tools, task execution
- **Gemini Live Mode**: Real-time voice + vision, continuous conversation

### 🎤 Smart Voice Control
- Wake word activation ("Hey Vision") for privacy
- Barge-in support (interrupt AI anytime)
- Conversation mode (follow-ups without wake word)

### 📷 Glasses Integration
- Photo capture on voice command
- Video streaming to AI (Gemini Live mode)
- iPhone camera fallback for testing

### ⚙️ Zero Hardcoding
- All configuration in-app (URLs, API keys, preferences)
- No forking required to use
- Secure storage of credentials

### 🔄 Production-Ready
- Auto-reconnect with exponential backoff
- Network monitoring (pause on WiFi drop)
- Conversation history persistence

## Quick Start

### Prerequisites

- macOS with Xcode 15+
- iOS 16+ device (simulator doesn't support Bluetooth)
- Meta Ray-Ban smart glasses (optional, iPhone camera fallback available)
- One of:
  - [OpenClaw](https://github.com/openclaw/openclaw) instance (local or cloud)
  - [Gemini API key](https://aistudio.google.com/app/apikey)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/user/OpenVision.git
   cd OpenVision
   ```

2. **Copy configuration files**
   ```bash
   cp Config.xcconfig.example Config.xcconfig
   cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
   ```

3. **Configure Meta App ID**

   Edit `Config.xcconfig` and add your [Meta App ID](https://developer.meta.com):
   ```
   META_APP_ID = your_meta_app_id_here
   DEVELOPMENT_TEAM = your_team_id_here
   ```

4. **Open in Xcode**
   ```bash
   open OpenVision.xcodeproj
   ```

5. **Build and run** on your iOS device

6. **Configure AI backend** in app: Settings → AI Backend

## AI Backend Comparison

| Feature | OpenClaw | Gemini Live |
|---------|----------|-------------|
| **Voice Input** | Wake word + STT | Native (always on) |
| **Response** | TTS playback | Native audio |
| **Vision** | Photo on request | 1fps streaming |
| **Tools** | 56+ skills | Limited |
| **Privacy** | Better (wake word) | Always listening |
| **Latency** | Higher | Lower |
| **Best For** | Tasks & control | Conversation |

## Usage

### OpenClaw Mode

1. Say **"Hey Vision"** to activate
2. Ask your question or give a command
3. The AI responds via text-to-speech
4. Say **"take a photo"** to capture and analyze what you see
5. Continue the conversation naturally (no wake word needed)
6. Silence ends the conversation after timeout

### Gemini Live Mode

1. Just start talking (always listening)
2. AI responds with natural voice
3. Video from glasses streams continuously at 1fps
4. AI can see and respond to what you're looking at
5. Interrupt anytime by speaking

### Voice Commands

- **"Take a photo"** - Capture and analyze current view
- **"What do you see?"** - Analyze current view
- **"Remember that..."** - Store a memory
- **"Search for..."** - Web search (OpenClaw with Perplexity)
- **"Stop"** - End the conversation

## Configuration

### Settings

| Setting | Description |
|---------|-------------|
| **AI Backend** | Choose OpenClaw or Gemini Live |
| **Gateway URL** | OpenClaw WebSocket URL |
| **Auth Token** | OpenClaw authentication token |
| **Gemini API Key** | Google Gemini API key |
| **Wake Word** | Custom wake phrase (default: "Hey Vision") |
| **Custom Instructions** | Additional AI system prompt |
| **Memories** | Key-value pairs the AI can access |

### OpenClaw Setup

1. [Install OpenClaw](https://github.com/openclaw/openclaw) on your Mac/server
2. Get your gateway URL (e.g., `wss://localhost:18789`)
3. Generate an auth token
4. Enter both in Settings → AI Backend → OpenClaw Settings

### Gemini Setup

1. Get a [Gemini API key](https://aistudio.google.com/app/apikey)
2. Enter it in Settings → AI Backend → Gemini Settings

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        OpenVision App                           │
├─────────────────────────────────────────────────────────────────┤
│  UI Layer (SwiftUI)                                             │
│  ├── MainTabView (Voice, History, Settings)                     │
│  ├── VoiceAgentView (Live conversation UI)                      │
│  └── SettingsView (Configuration panels)                        │
├─────────────────────────────────────────────────────────────────┤
│  Service Layer                                                  │
│  ├── OpenClawService (WebSocket with auto-reconnect)            │
│  ├── GeminiLiveService (Native audio WebSocket)                 │
│  ├── VoiceCommandService (Wake word + STT)                      │
│  └── GlassesCameraService (DAT SDK camera)                      │
├─────────────────────────────────────────────────────────────────┤
│  Manager Layer                                                  │
│  ├── SettingsManager (JSON persistence)                         │
│  ├── GlassesManager (DAT SDK wrapper)                           │
│  └── ConversationManager (Chat history)                         │
└─────────────────────────────────────────────────────────────────┘
```

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details.

### Development

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Style

- Follow Swift API Design Guidelines
- Use `@MainActor` for all UI-related code
- Add documentation comments to public APIs
- Write tests for new features

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [Google Gemini](https://ai.google.dev)

## Support

- [GitHub Issues](https://github.com/user/OpenVision/issues) - Bug reports and feature requests
- [Discussions](https://github.com/user/OpenVision/discussions) - Questions and community

---

**Made with ❤️ by the open-source community**
