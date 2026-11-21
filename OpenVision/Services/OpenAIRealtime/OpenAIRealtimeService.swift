// OpenVision - OpenAIRealtimeService.swift
// WebSocket client for the OpenAI Realtime API (GA gpt-realtime) with live audio + video.
//
// Mirrors GeminiLiveService: bidirectional 24 kHz PCM16 audio over a WebSocket, plus glasses
// camera frames pushed as image messages into the conversation. Server-side VAD handles
// turn-taking, so we just stream mic audio up and play the model's audio deltas back.
//
// Both this service and GeminiLiveService conform to `LiveVideoService` so VoiceAgentView can
// drive either one through the same code path depending on the selected backend.

import Foundation
import AVFoundation

/// Backend-agnostic surface for the live audio + video mode. GeminiLiveService and
/// OpenAIRealtimeService both conform, so the view layer can pick one at runtime.
@MainActor
protocol LiveVideoService: AnyObject {
    var onAudioReceived: ((Data) -> Void)? { get set }
    var onInputTranscription: ((String, Bool) -> Void)? { get set }
    var onOutputTranscription: ((String) -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    /// Sample rate (Hz) this backend expects for uploaded mic audio (PCM16 mono).
    var inputSampleRate: Int { get }
    /// Sample rate (Hz) of the audio this backend returns (PCM16 mono).
    var outputSampleRate: Int { get }

    func connect() async throws
    func disconnect() async
    func reconnect() async throws
    func sendAudio(data: Data)
    func sendVideoFrame(imageData: Data)
}

/// OpenAI Realtime WebSocket Service
///
/// Connects to `wss://<host>/realtime` for real-time voice + vision. The user's OpenAI API key
/// (already configured for the chat backend) is reused; the Realtime endpoint is derived from
/// `openAIBaseURL`, so OpenAI-compatible gateways that expose /realtime work too.
@MainActor
final class OpenAIRealtimeService: ObservableObject, LiveVideoService {
    // MARK: - Singleton

    static let shared = OpenAIRealtimeService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Configuration

    private var settings: AppSettings { SettingsManager.shared.settings }
    private var apiKey: String { settings.openAIAPIKey }

    private var videoFPS: Int {
        max(1, settings.geminiVideoFPS)   // reuse the shared "live video fps" preference
    }

    let inputSampleRate = Constants.OpenAIRealtime.inputSampleRate
    let outputSampleRate = Constants.OpenAIRealtime.outputSampleRate

    // MARK: - Callbacks

    var onAudioReceived: ((Data) -> Void)?
    var onInputTranscription: ((String, Bool) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSessionReady: Bool = false

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval { 1.0 / Double(videoFPS) }

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection

    func connect() async throws {
        guard !apiKey.isEmpty else { throw AIBackendError.notConfigured }
        guard !connectionState.isUsable, !connectionState.isAttempting else { return }

        connectionState = .connecting
        onConnectionStateChanged?(connectionState)

        do {
            guard let url = buildWebSocketURL() else { throw AIBackendError.connectionFailed }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            urlSession = URLSession(configuration: config)
            webSocket = urlSession?.webSocketTask(with: request)
            webSocket?.resume()

            startReceiving()

            // Wait for the socket to come up.
            var running = false
            for _ in 0..<15 {
                if webSocket?.state == .running { running = true; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard running else { throw AIBackendError.connectionTimeout }

            // The server sends `session.created`; once we see it we push our session config and
            // mark the session ready (isSessionReady).
            for _ in 0..<50 {
                if isSessionReady { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard isSessionReady else { throw AIBackendError.connectionFailed }

            connectionState = .connected
            onConnectionStateChanged?(connectionState)
            print("[OpenAIRealtime] Connected")

        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            onConnectionStateChanged?(connectionState)
            closeWebSocket()
            throw error
        }
    }

    func disconnect() async {
        guard connectionState != .disconnected else { return }
        print("[OpenAIRealtime] Disconnecting")
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        onDisconnected?()
    }

    /// Replace the server-side conversation without ending live video mode.
    func reconnect() async throws {
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        try await connect()
    }

    /// Derive the Realtime WebSocket URL from the configured OpenAI base URL.
    /// e.g. https://api.openai.com/v1 → wss://api.openai.com/v1/realtime?model=gpt-realtime
    private func buildWebSocketURL() -> URL? {
        var base = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        }
        let model = settings.openAIRealtimeModel.isEmpty
            ? Constants.OpenAIRealtime.modelName : settings.openAIRealtimeModel
        var components = URLComponents(string: base + Constants.OpenAIRealtime.websocketPath)
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        return components?.url
    }

    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isSessionReady = false
        isModelSpeaking = false
        isProcessing = false
    }

    // MARK: - Session setup

    /// Configure the session: PCM16 in/out at 24 kHz, server VAD turn-taking, audio output with a
    /// voice, and input transcription so spoken "stop video" commands surface as text.
    private func sendSessionUpdate() async throws {
        let voice = settings.openAIRealtimeVoice.isEmpty
            ? Constants.OpenAIRealtime.voice : settings.openAIRealtimeVoice

        let session: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": buildSystemPrompt(),
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": inputSampleRate
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                            "create_response": true,
                            "interrupt_response": true
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": outputSampleRate
                        ],
                        "voice": voice
                    ]
                ]
            ]
        ]
        try await sendJSON(session)
    }

    private func buildSystemPrompt() -> String {
        var prompt = """
        You are a helpful AI assistant integrated with smart glasses. You can see what the user sees through their glasses camera.

        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        If the user asks you to do something beyond your capabilities, explain what you can help with instead.
        """

        let userPrompt = settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        let memories = settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }
        return prompt
    }

    // MARK: - Send Audio

    func sendAudio(data: Data) {
        guard connectionState.isUsable, !isModelSpeaking else { return }

        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        Task { try? await sendJSON(message) }
    }

    // MARK: - Send Video

    func sendVideoFrame(imageData: Data) {
        guard connectionState.isUsable, !isModelSpeaking else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        // Add the frame as an image message. It becomes visual context for the model's next reply;
        // it does NOT trigger a response on its own (server VAD drives responses off speech).
        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let message: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]
        ]
        Task { try? await sendJSON(message) }
    }

    // MARK: - Send JSON

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket = webSocket else { throw AIBackendError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await webSocket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let webSocket = self.webSocket else { break }
                do {
                    let message = try await webSocket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        print("[OpenAIRealtime] Receive error: \(error)")
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard let data = extractData(from: message),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            // Push our config, then consider the session ready to stream.
            do {
                try await sendSessionUpdate()
                isSessionReady = true
            } catch {
                print("[OpenAIRealtime] session.update failed: \(error)")
            }

        case "session.updated":
            isSessionReady = true

        case "input_audio_buffer.speech_started":
            // User started talking → the server will interrupt the model. Reflect that locally.
            isModelSpeaking = false
            isProcessing = true

        case "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let audio = Data(base64Encoded: b64) {
                isModelSpeaking = true
                isProcessing = true
                onAudioReceived?(audio)
            }

        case "response.output_audio_transcript.delta":
            if let text = json["delta"] as? String, !text.isEmpty {
                onOutputTranscription?(text)
            }

        case "conversation.item.input_audio_transcription.completed":
            let text = json["transcript"] as? String ?? ""
            if !text.isEmpty { onInputTranscription?(text, true) }

        case "conversation.item.input_audio_transcription.delta":
            let text = json["delta"] as? String ?? ""
            if !text.isEmpty { onInputTranscription?(text, false) }

        case "response.done", "response.output_audio.done":
            isModelSpeaking = false
            isProcessing = false
            onTurnComplete?()

        case "error":
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            print("[OpenAIRealtime] Server error: \(detail)")
            lastError = detail

        default:
            break
        }
    }

    private func extractData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return nil
        }
    }

    private func handleDisconnect() async {
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        onDisconnected?()
    }
}

// MARK: - GeminiLiveService conformance

/// GeminiLiveService already implements the whole surface; expose its sample rates so it satisfies
/// `LiveVideoService` and can be selected interchangeably with the OpenAI backend.
extension GeminiLiveService: LiveVideoService {
    var inputSampleRate: Int { Constants.GeminiLive.inputSampleRate }
    var outputSampleRate: Int { Constants.GeminiLive.outputSampleRate }
}
