// OpenVision - AppSettings.swift
// Settings data model with Codable support for JSON persistence

import Foundation

/// The type of AI backend to use
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw = "openclaw"
    case geminiLive = "gemini_live"
    case openAI = "openai"
    case grok = "grok"
    case hermes = "hermes"
    case appleFoundation = "apple_foundation"
    case localGemma = "local_gemma"

    var displayName: String {
        switch self {
        case .openClaw: return "OpenClaw"
        case .geminiLive: return "Gemini Live"
        case .openAI: return "OpenAI"
        case .grok: return "Grok"
        case .hermes: return "Hermes"
        case .appleFoundation: return "Apple Intelligence"
        case .localGemma: return "Local (MLX)"
        }
    }

    var description: String {
        switch self {
        case .openClaw:
            return "Wake word activation, 56+ tools, task execution"
        case .geminiLive:
            return "Real-time voice + vision, continuous conversation"
        case .openAI:
            return "GPT — cloud text + vision (API key or ChatGPT subscription)"
        case .grok:
            return "xAI Grok — cloud text + vision (API key or SuperGrok)"
        case .hermes:
            return "Your Hermes Agent server — its tools, memory and skills"
        case .appleFoundation:
            return "On-device Apple model — private, no download (iOS 26+)"
        case .localGemma:
            return "On-device Gemma 4 — private, offline, no API cost"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "terminal"
        case .geminiLive: return "waveform"
        case .openAI: return "sparkles"
        case .grok: return "bolt"
        case .hermes: return "server.rack"
        case .appleFoundation: return "apple.logo"
        case .localGemma: return "cpu"
        }
    }
}

/// How the OpenAI backend authenticates.
enum OpenAIAuthMode: String, Codable, CaseIterable, Identifiable {
    /// API key against the public API (or any OpenAI-compatible base URL).
    case apiKey = "api_key"
    /// Sign in with a ChatGPT subscription (see ChatGPTSubscription).
    case chatGPTSubscription = "chatgpt_subscription"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .chatGPTSubscription: return "ChatGPT Subscription"
        }
    }
    /// The trade-off, shown where the choice is made.
    var summary: String {
        switch self {
        case .apiKey: return "Pay per use. Works with live video and OpenAI-compatible services."
        case .chatGPTSubscription: return "Use your Plus or Pro plan. Text and photos; no live video."
        }
    }
    var icon: String {
        switch self {
        case .apiKey: return "key"
        case .chatGPTSubscription: return "person.crop.circle"
        }
    }
}

/// How the Grok backend authenticates.
enum GrokAuthMode: String, Codable, CaseIterable, Identifiable {
    /// xAI API key (console.x.ai).
    case apiKey = "api_key"
    /// Sign in with a SuperGrok subscription (see GrokService).
    case superGrok = "supergrok"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .superGrok: return "SuperGrok Subscription"
        }
    }
    /// The trade-off, shown where the choice is made.
    var summary: String {
        switch self {
        case .apiKey: return "Pay per use with xAI API credits."
        case .superGrok: return "Use your SuperGrok plan. Text and photos."
        }
    }
    var icon: String {
        switch self {
        case .apiKey: return "key"
        case .superGrok: return "person.crop.circle"
        }
    }
}

/// How the Hermes backend connects.
enum HermesAuthMode: String, Codable, CaseIterable, Identifiable {
    /// The OpenAI-compatible API server (API_SERVER_KEY as bearer).
    case apiKey = "api_key"
    /// The web UI's username and password (native sign-in), chatting like Hermes Desktop.
    case password = "password"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .password: return "Username & Password"
        }
    }
    /// The trade-off, shown where the choice is made.
    var summary: String {
        switch self {
        case .apiKey: return "Hermes' API server. Stable and documented."
        case .password: return "Sign in like the web UI. Uses the Desktop app's protocol, which can change between Hermes versions."
        }
    }
    var icon: String {
        switch self {
        case .apiKey: return "key"
        case .password: return "person.crop.circle"
        }
    }
}

/// Which text-to-speech engine to use.
enum TTSEngineType: String, Codable, CaseIterable, Identifiable {
    case appleSystem = "apple"
    case kokoro = "kokoro"
    case grok = "grok"
    case openAI = "openai"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleSystem: return "Apple (system voice)"
        case .kokoro: return "Kokoro (natural, on-device)"
        case .grok: return "Grok (natural, cloud)"
        case .openAI: return "OpenAI (natural, cloud)"
        }
    }
}

/// App settings persisted to Documents/settings.json (API keys and tokens go to the Keychain; see SettingsSecrets)
struct AppSettings: Codable, Equatable {
    // MARK: - AI Backend Selection

    /// Which AI backend to use
    var aiBackend: AIBackendType = .openClaw

    // MARK: - OpenClaw Configuration

    /// OpenClaw gateway WebSocket URL (e.g., "wss://openclaw.example.com")
    var openClawGatewayURL: String = ""

    /// OpenClaw authentication token
    var openClawAuthToken: String = ""

    // MARK: - Gemini Live Configuration

    /// Google Gemini API key
    var geminiAPIKey: String = ""

    // MARK: - OpenAI Configuration

    /// API key, or a ChatGPT subscription sign-in (tokens live in the Keychain, not here).
    var openAIAuthMode: OpenAIAuthMode = .apiKey

    /// Model used with a ChatGPT subscription. The subscription serves a different, per-account
    /// set of models than the API, so this is separate from `openAIModel`.
    var openAISubscriptionModel: String = ChatGPTSubscription.defaultModel

    /// OpenAI (or OpenAI-compatible) API key.
    var openAIAPIKey: String = ""

    /// Chat model id. gpt-4o-mini is cheap and supports vision — a good default for testing.
    var openAIModel: String = "gpt-4o-mini"

    /// API base URL. Override to point at any OpenAI-compatible endpoint (OpenRouter, a local
    /// server, Azure-style gateways, etc.). No trailing slash.
    var openAIBaseURL: String = "https://api.openai.com/v1"

    /// Voice for the OpenAI speech engine (needs an API key; the subscription doesn't cover speech).
    var openAITTSVoice: String = CloudTTSService.openAIDefaultVoice

    /// Realtime model id used for live audio + video mode (GA gpt-realtime).
    var openAIRealtimeModel: String = "gpt-realtime"

    /// Voice used by the OpenAI Realtime backend.
    var openAIRealtimeVoice: String = "marin"

    // MARK: - Grok Configuration

    /// xAI API key, or a SuperGrok sign-in (tokens live in the Keychain, not here).
    var grokAuthMode: GrokAuthMode = .apiKey

    /// xAI API key.
    var grokAPIKey: String = ""

    /// Grok model id. Both sign-in methods use the same public API, so one model setting serves both.
    var grokModel: String = GrokService.defaultModel

    /// Voice for the Grok speech engine (xAI TTS voice id, e.g. "ara").
    var grokVoice: String = CloudTTSService.grokDefaultVoice

    // MARK: - Hermes Configuration

    /// API key (API server) or the web UI's username and password.
    var hermesAuthMode: HermesAuthMode = .apiKey

    /// Address of the Hermes web UI (`hermes dashboard`, port 9119 by default), for
    /// username-and-password sign-in. Tokens live in the Keychain, not here.
    var hermesDashboardURL: String = ""

    /// OpenVision conversation id → Hermes' stored chat session id (username-and-password
    /// mode), so each History conversation continues its own Hermes chat across launches.
    var hermesSessions: [String: String] = [:]

    /// Address of the user's Hermes API server, e.g. "https://hermes.example.com" (the `/v1`
    /// suffix and a `/p/<profile>` prefix are both accepted).
    var hermesServerURL: String = ""

    /// The server's API_SERVER_KEY. It grants Hermes' tools, terminal included.
    var hermesAPIKey: String = ""

    // MARK: - Web Search

    /// Tavily API key (free tier). When set, web search uses Tavily (real live content, built for
    /// LLMs) as the primary source, falling back to keyless DuckDuckGo otherwise.
    var tavilyAPIKey: String = ""

    // MARK: - Local Gemma Configuration

    /// HuggingFace repo id of the on-device Gemma 4 model to load.
    /// Matches `GemmaLocalModel.e2b.modelId` (note the validated capital-E2B casing).
    var localGemmaModelId: String = "mlx-community/gemma-4-E2B-it-4bit"

    /// Whether the selected Gemma model has finished downloading and is ready to load.
    /// Set by the model-manager / GemmaLocalService once the snapshot is on disk.
    var localGemmaModelReady: Bool = false

    // MARK: - Voice Settings

    /// Wake word phrase (default: "Ok Vision")
    var wakeWord: String = "Ok Vision"

    /// Whether wake word detection is enabled (OpenClaw mode only)
    var wakeWordEnabled: Bool = true

    /// Play activation chime on wake word detection
    var playActivationSound: Bool = true

    /// Conversation timeout in seconds (auto-end after silence)
    var conversationTimeout: TimeInterval = 30

    /// Selected TTS voice identifier for the Apple system voice (nil = system default)
    var selectedVoiceIdentifier: String? = nil

    /// Which TTS engine to speak with. Apple (system voice) is the default and always available;
    /// Kokoro is on-device neural TTS (natural, offline) once its model is downloaded.
    var ttsEngine: TTSEngineType = .appleSystem

    /// Selected Kokoro voice (e.g. "af_heart"). First letter: a = American, b = British.
    var kokoroVoice: String = "af_heart"

    // MARK: - Telemetry (opt-in, self-hosted)

    /// Push runtime metrics to your own InfluxDB. OFF by default and inert until a URL is set.
    /// Sends timings and device health only — never transcripts, replies, or tool arguments.
    var telemetryEnabled: Bool = false
    /// Base URL of your InfluxDB, e.g. "http://192.168.1.20:8086". Use the LAN IP or a `.local`
    /// name, never localhost — on the phone that would be the phone.
    var telemetryURL: String = ""
    var telemetryBucket: String = "metrics"
    var telemetryOrg: String = "openvision"
    /// InfluxDB v2 API token. Preferred; when empty the username/password below are used (v1).
    var telemetryToken: String = ""
    var telemetryUsername: String = ""
    var telemetryPassword: String = ""
    /// Tag on every point so several devices stay distinguishable in Grafana.
    var telemetryDeviceName: String = "iphone"

    /// Prefer the glasses' Bluetooth microphone for voice input when they're the connected audio
    /// device — true hands-free. Falls back to the phone mic automatically when the glasses aren't
    /// the audio route. Turn off to always use the phone. (Glasses mic uses more battery.)
    var preferGlassesMic: Bool = true

    // MARK: - AI Customization

    /// Custom instructions appended to AI system prompt
    var userPrompt: String = ""

    /// Key-value memories the AI can read and manage
    var memories: [String: String] = [:]

    // MARK: - Advanced Settings

    /// Auto-reconnect on connection drop
    var autoReconnect: Bool = true

    /// Show live transcripts in UI
    var showTranscripts: Bool = true

    /// Video frame rate for Gemini Live (frames per second)
    var geminiVideoFPS: Int = 1

    // MARK: - Computed Properties

    /// Whether OpenClaw is configured (has URL and token)
    var isOpenClawConfigured: Bool {
        !openClawGatewayURL.isEmpty && !openClawAuthToken.isEmpty
    }

    /// Whether Gemini is configured (has API key)
    var isGeminiConfigured: Bool {
        !geminiAPIKey.isEmpty
    }

    /// Whether OpenAI is configured (API key, or signed in to a ChatGPT subscription)
    var isOpenAIConfigured: Bool {
        switch openAIAuthMode {
        case .apiKey: return isOpenAIAPIKeyConfigured
        case .chatGPTSubscription: return OAuthTokenStore.shared.isSignedIn(ChatGPTSubscription.provider)
        }
    }

    /// Whether the public OpenAI API — Realtime live video, speech — can be used. It needs a real
    /// API key: the ChatGPT subscription backend serves the Responses API only.
    var isOpenAIAPIAvailable: Bool {
        openAIAuthMode == .apiKey && isOpenAIAPIKeyConfigured
    }

    private var isOpenAIAPIKeyConfigured: Bool {
        !openAIAPIKey.isEmpty && !openAIBaseURL.isEmpty
    }

    /// Whether Grok is configured (API key, or signed in to SuperGrok)
    var isGrokConfigured: Bool {
        switch grokAuthMode {
        case .apiKey: return !grokAPIKey.isEmpty
        case .superGrok: return OAuthTokenStore.shared.isSignedIn(GrokService.provider)
        }
    }

    /// Whether Hermes is configured (server URL and API key)
    var isHermesConfigured: Bool {
        switch hermesAuthMode {
        case .apiKey:
            return HermesService.apiBase(from: hermesServerURL) != nil && !hermesAPIKey.isEmpty
        case .password:
            guard let base = HermesDashboard.base(from: hermesDashboardURL) else { return false }
            return OAuthTokenStore.shared.isSignedIn(HermesDashboard.provider(base: base))
        }
    }

    /// Whether the local Gemma backend is ready (model downloaded)
    var isLocalGemmaConfigured: Bool {
        localGemmaModelReady
    }

    /// Whether the currently selected backend is configured
    var isCurrentBackendConfigured: Bool {
        switch aiBackend {
        case .openClaw: return isOpenClawConfigured
        case .geminiLive: return isGeminiConfigured
        case .openAI: return isOpenAIConfigured
        case .grok: return isGrokConfigured
        case .hermes: return isHermesConfigured
        case .appleFoundation: return true   // OS-managed; availability checked at connect
        case .localGemma: return isLocalGemmaConfigured
        }
    }

    /// Backend label for the UI. For the local backend, reflects the *actually selected* MLX model
    /// (Qwen / SmolVLM / FastVLM / …) instead of a fixed name, so the main-screen pill is accurate.
    var backendDisplayName: String {
        guard aiBackend == .localGemma else { return aiBackend.displayName }
        return "Local · \(GemmaLocalModel.from(modelId: localGemmaModelId).displayName)"
    }
}
