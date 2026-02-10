// OpenVision - Constants.swift
// App-wide constants

import Foundation

enum Constants {
    // MARK: - OpenClaw

    enum OpenClaw {
        /// Maximum reconnection attempts before giving up
        static let maxReconnectAttempts = 12

        /// Initial reconnection delay in seconds
        static let initialReconnectDelay: TimeInterval = 1.0

        /// Maximum reconnection delay in seconds
        static let maxReconnectDelay: TimeInterval = 30.0

        /// Heartbeat ping interval in seconds
        static let heartbeatInterval: TimeInterval = 20.0

        /// Pong timeout in seconds
        static let pongTimeout: TimeInterval = 10.0
    }

    // MARK: - Gemini Live

    enum GeminiLive {
        /// WebSocket endpoint for Gemini Live API
        static let websocketEndpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

        /// Model name (native audio model for real-time voice + video)
        static let modelName = "models/gemini-2.5-flash-native-audio-preview-12-2025"

        /// Input audio sample rate (Hz)
        static let inputSampleRate = 16000

        /// Output audio sample rate (Hz)
        static let outputSampleRate = 24000

        /// Audio chunk size in milliseconds
        static let audioChunkMs = 100

        /// JPEG quality for video frames (0.0 - 1.0)
        static let videoJPEGQuality: CGFloat = 0.5

        /// Default video frame rate (fps)
        static let defaultVideoFPS = 1
    }

    // MARK: - Voice

    enum Voice {
        /// Default wake word
        static let defaultWakeWord = "Hey Vision"

        /// Wake word cooldown to prevent double-detection (seconds)
        static let wakeWordCooldown: TimeInterval = 0.8

        /// Command capture timeout (seconds)
        static let commandTimeout: TimeInterval = 10.0

        /// Silence timeout to end command capture (seconds)
        static let silenceTimeout: TimeInterval = 4.0

        /// Default conversation timeout (seconds)
        static let conversationTimeout: TimeInterval = 30.0
    }

    // MARK: - Audio

    enum Audio {
        /// PCM format: 16-bit signed integer
        static let pcmBitDepth = 16

        /// Mono channel count
        static let monoChannels = 1

        /// Audio buffer size in samples
        static let bufferSize = 1024
    }

    // MARK: - Camera

    enum Camera {
        /// Maximum photo dimension for compression
        static let maxPhotoDimension: CGFloat = 512

        /// JPEG compression quality for photos
        static let photoJPEGQuality: CGFloat = 0.5

        /// Photo capture timeout (seconds)
        static let captureTimeout: TimeInterval = 10.0
    }

    // MARK: - UI

    enum UI {
        /// Animation duration for state transitions
        static let animationDuration: TimeInterval = 0.3

        /// Debounce interval for search/filter
        static let debounceInterval: TimeInterval = 0.3
    }

    // MARK: - Storage

    enum Storage {
        /// Settings file name
        static let settingsFileName = "settings.json"

        /// Conversations file name
        static let conversationsFileName = "conversations.json"

        /// Maximum conversations to keep
        static let maxConversations = 100

        /// Conversation inactivity timeout before starting new (seconds)
        static let conversationInactivityTimeout: TimeInterval = 300 // 5 minutes
    }
}
