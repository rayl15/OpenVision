# Architecture

How OpenVision is organized, and the seams to use when extending it.

```
OpenVision/
├── App/                 App entry (OpenVisionApp)
├── Config/              Constants + xcconfig-backed configuration (zero hardcoding)
├── Managers/            App-wide state: SettingsManager, GlassesManager
├── Models/              Value types & settings enums (AIBackendType, TTSEngineType, …)
├── Services/            One folder per domain — the backbone of the app
│   ├── AIBackend/       AIBackend protocol + registry + conformances, OpenAIService
│   ├── AppleFoundation/ Apple Intelligence backend (+ its native Tool wrappers)
│   ├── Audio/           Audio session, capture, playback, sounds
│   ├── GeminiLive/      Gemini Live websocket backend + Gemini vision
│   ├── GemmaLocal/      On-device MLX models (Gemma 4, SmolVLM2, FastVLM, Qwen)
│   ├── LocalAgent/      Shared routing brain for on-device models (JSON-in-text)
│   ├── NativeTools/     Productivity tools (timer, reminder, calendar, note, …)
│   ├── OpenAIRealtime/  OpenAI Realtime (live audio/video)
│   ├── OpenClaw/        OpenClaw agentic backend
│   ├── TTS/             Apple TTS + Kokoro neural TTS
│   ├── Voice/           Wake word + speech recognition (VoiceCommandService)
│   ├── Vision/          Face recognition (Apple Vision)
│   └── Web/             Web search (Tavily / DuckDuckGo)
├── Views/               SwiftUI. MVVM: Views render; ViewModels orchestrate.
│   └── VoiceAgent/      VoiceAgentView (UI) + VoiceAgentViewModel (all orchestration)
└── Utilities/           Small helpers
OpenVisionTests/         Unit tests (pure logic: date resolution, routing, chunking)
```

## Patterns

- **MVVM** on the main screen: `VoiceAgentView` is rendering + interaction forwarding only;
  `VoiceAgentViewModel` (a `@MainActor ObservableObject`) owns session lifecycle, command
  routing, live-video modes, TTS streaming, and history. Service callbacks capture the
  ViewModel weakly — services are app-lifetime singletons and must not pin it.
- **Protocol seams, not concrete types**, wherever behavior varies:
  - `AIBackend` — every conversational backend (see below).
  - `LocalTextLLM` — the on-device routing brain (Gemma, Apple Intelligence), including a
    `routeCommandStreaming` capability with a non-streaming default.
  - `NativeTool` — one productivity tool; the registry adapts it to every backend's
    function-calling format ([docs/native-tools.md](native-tools.md)).
  - `LiveVideoService` — realtime audio/video backends (Gemini Live, OpenAI Realtime).
- **Services are singletons** (`Service.shared`) orchestrated from the ViewModel. Pure logic
  that needs testing lives in enums/free functions (`NativeToolSupport`, `LocalAgent`,
  `TextChunking`) so tests never touch hardware, network, or models.

## The AIBackend seam

`Services/AIBackend/AIBackendProtocol.swift` defines the contract; the voice agent drives
whichever backend the user selected through it — no downcasts, no per-backend switches:

```swift
@MainActor protocol AIBackend: AnyObject {
    var backendType: AIBackendType { get }
    var onAgentMessage: ((String) -> Void)? { get set }
    var onProcessingChanged: ((Bool) -> Void)? { get set }
    func sendMessage(_ text: String, imageData: Data?) async throws
    // Capabilities (defaulted):
    var localLLM: LocalTextLLM? { get }        // on-device routing brain
    var supportsImageInput: Bool { get }       // photo commands attach a glasses frame
}
```

**Adding a backend:**
1. Write your service (any shape you like internally).
2. Conform it to `AIBackend` in `AIBackendConformances.swift` (thin adapter if names differ).
3. Add a case to `AIBackendType` (Models/AppSettings.swift) and one line to `AIBackendRegistry`.
4. If it should run the productivity tools, wire its function-calling loop to
   `NativeToolRegistry.shared` (see how OpenAI/Gemini do it).

**Adding a native tool:** see [docs/native-tools.md](native-tools.md) — implement `NativeTool`,
register it, add the Apple `Tool` wrapper, and mention it in the backend prompts.

## Tests

`OpenVisionTests` runs via the standard test action:

```bash
xcodebuild test -project OpenVision.xcodeproj -scheme OpenVision -destination "id=<device-udid>"
```

Current coverage is the pure logic where silent regressions hurt: tool date resolution
("remind me at 6 PM" → exactly 6:00 PM), the local model's JSON router, and TTS sentence
chunking. New pure logic should come with tests; hardware/model paths are verified on-device.
