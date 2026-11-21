// OpenVision - GeminiLiveService.swift
// WebSocket client for Google Gemini Live API with native audio

import Foundation
import AVFoundation

/// Gemini Live WebSocket Service
///
/// Connects to Gemini Live API for real-time voice + vision AI.
/// Handles bidirectional audio streaming and video frame transmission.
@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Configuration

    private var apiKey: String {
        SettingsManager.shared.settings.geminiAPIKey
    }

    private var videoFPS: Int {
        SettingsManager.shared.settings.geminiVideoFPS
    }

    // MARK: - Callbacks

    var onTextReceived: ((String) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInputTranscription: ((String, Bool) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSetupComplete: Bool = false
    private var pendingInputTranscription = ""
    private var inputTurnCompleted = false
    private var lastFinalInputTranscription = ""
    private var lateInputTranscriptionTask: Task<Void, Never>?
    private static let inputTranscriptionFinalizationDelay: UInt64 = 600_000_000

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval {
        1.0 / Double(videoFPS)
    }

    // MARK: - Latency Tracking

    private var lastUserSpeechEnd: Date?

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection

    /// Connect to Gemini Live API
    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw AIBackendError.notConfigured
        }

        guard !connectionState.isUsable else { return }
        guard !connectionState.isAttempting else { return }

        connectionState = .connecting
        onConnectionStateChanged?(connectionState)

        do {
            let url = buildWebSocketURL()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30

            urlSession = URLSession(configuration: config)
            webSocket = urlSession?.webSocketTask(with: url)
            webSocket?.resume()

            startReceiving()

            // Wait for connection
            var connected = false
            for _ in 0..<15 {
                if webSocket?.state == .running {
                    connected = true
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard connected else {
                throw AIBackendError.connectionTimeout
            }

            // Send setup message
            try await sendSetup()

            // Wait for setup complete
            for _ in 0..<50 {
                if isSetupComplete {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard isSetupComplete else {
                throw AIBackendError.connectionFailed
            }

            connectionState = .connected
            onConnectionStateChanged?(connectionState)
            print("[GeminiLive] Connected")

        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            onConnectionStateChanged?(connectionState)
            closeWebSocket()
            throw error
        }
    }

    /// Disconnect from Gemini Live
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        print("[GeminiLive] Disconnecting")
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

    /// Build WebSocket URL
    private func buildWebSocketURL() -> URL {
        var components = URLComponents(string: Constants.GeminiLive.websocketEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]
        return components.url!
    }

    /// Close WebSocket
    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        isSetupComplete = false
        isModelSpeaking = false
        pendingInputTranscription = ""
        inputTurnCompleted = false
        lastFinalInputTranscription = ""
        lateInputTranscriptionTask?.cancel()
        lateInputTranscriptionTask = nil
    }

    // MARK: - Setup

    /// Send setup message to configure the session
    private func sendSetup() async throws {
        let setup: [String: Any] = [
            "setup": [
                "model": Constants.GeminiLive.modelName,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "thinkingConfig": [
                        "thinkingBudget": 0
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": buildSystemPrompt()]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "prefixPaddingMs": 40,
                        "silenceDurationMs": 500
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any],
                "tools": buildToolDeclarations()
            ]
        ]

        try await sendJSON(setup)
    }

    /// Build system prompt
    private func buildSystemPrompt() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var prompt = """
        You are a helpful AI assistant integrated with smart glasses. You can see what the user sees through their glasses camera.

        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        The current date and time is \(now) in the user's local time zone. Base any time on this.

        You can handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search/list notes auto-tagged with place and time), copy_to_clipboard, search_docs (search the user's imported manuals/recipes/guides — use it whenever they ask about their documents, and answer only from what it returns), and meetings (the user's recorded meeting notes — use it for questions about their meetings, decisions or action items). For a specific time of day (e.g. "6pm", "9:30am") pass the tool's hour (24-hour form) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for "in N minutes / from now". After a tool runs, briefly confirm what you did in one sentence.

        If the user asks you to do something beyond your capabilities, explain what you can help with instead.
        """

        // Add user's custom instructions
        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        // Add memories
        let memories = SettingsManager.shared.settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }

        return prompt
    }

    /// Build tool declarations: the on-device productivity tools (timers, reminders, calendar,
    /// notes, clipboard). Gemini nests function declarations under `tools: [{functionDeclarations:[…]}]`.
    private func buildToolDeclarations() -> [[String: Any]] {
        [["functionDeclarations": NativeToolRegistry.shared.geminiDeclarations]]
    }

    // MARK: - Send Audio

    /// Send audio data to Gemini
    func sendAudio(data: Data) {
        guard connectionState.isUsable, !isModelSpeaking else { return }
        if inputTurnCompleted {
            lateInputTranscriptionTask?.cancel()
            lateInputTranscriptionTask = nil
            finishInputTranscription()
            inputTurnCompleted = false
            pendingInputTranscription = ""
            lastFinalInputTranscription = ""
        }

        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(Constants.GeminiLive.inputSampleRate)",
                    "data": data.base64EncodedString()
                ]
            ]
        ]

        Task {
            try? await sendJSON(message)
        }
    }

    /// Notify that user stopped speaking
    func userStoppedSpeaking() {
        lastUserSpeechEnd = Date()
    }

    /// Send text message to Gemini
    func sendText(_ text: String) async throws {
        guard connectionState.isUsable else {
            throw AIBackendError.notConnected
        }
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [["text": text]]
                    ]
                ],
                "turnComplete": true
            ]
        ]

        try await sendJSON(message)
    }

    /// Interrupt the AI (barge-in support)
    func interrupt() async {
        // Send interrupt signal if model is speaking
        guard isModelSpeaking else { return }

        isModelSpeaking = false
        isProcessing = false
        print("[GeminiLive] Interrupted")
    }

    // MARK: - Send Video

    /// Send video frame to Gemini (throttled)
    func sendVideoFrame(imageData: Data) {
        guard connectionState.isUsable else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        let message: [String: Any] = [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": imageData.base64EncodedString()
                ]
            ]
        ]

        Task {
            try? await sendJSON(message)
        }
    }

    // MARK: - Send JSON

    /// Send JSON message
    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket = webSocket else {
            throw AIBackendError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: object)
        try await webSocket.send(.data(data))
    }

    // MARK: - Receive Loop

    /// Start receiving messages
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let webSocket = self.webSocket else { break }

                do {
                    let message = try await webSocket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        print("[GeminiLive] Receive error: \(error)")
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    /// Handle incoming message
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard let data = extractData(from: message),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Setup complete
        if json["setupComplete"] != nil {
            isSetupComplete = true
            return
        }

        // Server content (audio, text, etc.)
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
            return
        }

        // Input transcription (user's speech) - can come at root level
        if let inputTranscription = json["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            print("[GeminiLive] User said: \(text)")
            appendInputTranscription(text)
            if inputTurnCompleted { scheduleLateInputTranscriptionFinish() }
            return
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any] {
            await handleToolCall(toolCall)
            return
        }

        // Go away (server closing connection)
        if json["goAway"] != nil {
            print("[GeminiLive] Server requested disconnect")
            await handleDisconnect()
            return
        }
    }

    /// Extract data from WebSocket message
    private func extractData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return nil
        }
    }

    nonisolated static func mergeInputTranscription(_ current: String, with fragment: String) -> String {
        guard !fragment.isEmpty else { return current }
        guard !current.isEmpty else { return fragment }
        if fragment.hasPrefix(current) { return fragment }
        if current.hasPrefix(fragment) { return current }

        let maximumOverlap = min(current.count, fragment.count)
        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            if current.suffix(overlap) == fragment.prefix(overlap) {
                return current + String(fragment.dropFirst(overlap))
            }
        }
        return current + fragment
    }

    private func appendInputTranscription(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        pendingInputTranscription = Self.mergeInputTranscription(pendingInputTranscription, with: fragment)
        onInputTranscription?(pendingInputTranscription, false)
    }

    private func scheduleLateInputTranscriptionFinish() {
        lateInputTranscriptionTask?.cancel()
        lateInputTranscriptionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.inputTranscriptionFinalizationDelay)
            guard !Task.isCancelled, let self else { return }
            self.finishInputTranscription()
        }
    }

    private func finishInputTranscription() {
        lateInputTranscriptionTask?.cancel()
        lateInputTranscriptionTask = nil
        let transcript = pendingInputTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInputTranscription = ""
        guard !transcript.isEmpty, transcript != lastFinalInputTranscription else { return }
        lastFinalInputTranscription = transcript
        onInputTranscription?(transcript, true)
    }

    /// Handle server content
    private func handleServerContent(_ content: [String: Any]) {
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            appendInputTranscription(text)
            if inputTurnCompleted { scheduleLateInputTranscriptionFinish() }
        }

        if content["turnComplete"] as? Bool == true {
            inputTurnCompleted = true
            scheduleLateInputTranscriptionFinish()
            isModelSpeaking = false
            isProcessing = false
            onTurnComplete?()
            return
        }

        if content["interrupted"] as? Bool == true {
            pendingInputTranscription = ""
            inputTurnCompleted = false
            lateInputTranscriptionTask?.cancel()
            lateInputTranscriptionTask = nil
            isModelSpeaking = false
            isProcessing = false
            return
        }

        // Model turn
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {

                    // Track latency for first audio
                    if !isModelSpeaking, let speechEnd = lastUserSpeechEnd {
                        let latency = Date().timeIntervalSince(speechEnd) * 1000
                        print("[GeminiLive] Latency: \(Int(latency))ms")
                        lastUserSpeechEnd = nil
                    }

                    isModelSpeaking = true
                    isProcessing = true
                    onAudioReceived?(audioData)
                }

                // Text (transcription)
                if let text = part["text"] as? String {
                    onOutputTranscription?(text)
                }
            }
        }

    }

    /// Handle a tool call from Gemini: run each requested native tool and send the results back as a
    /// `toolResponse` so the model can speak a grounded confirmation in the same turn.
    private func handleToolCall(_ toolCall: [String: Any]) async {
        guard let calls = toolCall["functionCalls"] as? [[String: Any]], !calls.isEmpty else {
            print("[GeminiLive] toolCall with no functionCalls: \(toolCall)")
            return
        }

        var responses: [[String: Any]] = []
        for call in calls {
            guard let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any] ?? [:]
            let result = await NativeToolRegistry.shared.execute(name: name, args: args)
            var response: [String: Any] = ["name": name, "response": ["result": result]]
            if let id = call["id"] as? String { response["id"] = id }  // echo id so Gemini pairs the response
            responses.append(response)
        }

        guard !responses.isEmpty else { return }
        do {
            try await sendJSON(["toolResponse": ["functionResponses": responses]])
        } catch {
            print("[GeminiLive] Failed to send toolResponse: \(error)")
        }
    }

    /// Handle disconnect
    private func handleDisconnect() async {
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        onDisconnected?()
    }
}
