// OpenVision - OpenClawService.swift
// Production-grade WebSocket client for OpenClaw with auto-reconnect
//
// Features:
// - Persistent WebSocket connection
// - Auto-reconnect with exponential backoff (12 attempts, 1s → 30s)
// - Heartbeat ping/pong (20s interval)
// - Network monitoring (pause on WiFi drop)
// - App lifecycle handling (suspend on background)
// - Tool status tracking

import Foundation
import Network
import Combine
import UIKit

/// OpenClaw WebSocket Service
///
/// Connects to an OpenClaw gateway via WebSocket for real-time AI communication.
/// Handles connection management, auto-reconnect, and message routing.
@MainActor
final class OpenClawService: ObservableObject {
    // MARK: - Singleton

    static let shared = OpenClawService()

    // MARK: - Published State

    /// Current connection state
    @Published var connectionState: AIConnectionState = .disconnected

    /// Whether agent is currently processing a request
    @Published var isProcessing: Bool = false

    /// Current tool being executed (nil if none)
    @Published var currentToolName: String?

    /// Whether a tool is currently running
    @Published var isToolRunning: Bool = false

    /// Last error message
    @Published var lastError: String?

    /// Debug info for troubleshooting
    @Published var debugInfo: String = ""

    // MARK: - Configuration (from SettingsManager)

    private var gatewayURL: URL? {
        guard let urlString = SettingsManager.shared.settings.openClawGatewayURL.nilIfEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return url
    }

    private var authToken: String {
        SettingsManager.shared.settings.openClawAuthToken
    }

    // MARK: - Callbacks

    /// Called when agent sends a text response
    var onAgentMessage: ((String) -> Void)?

    /// Called when agent processing state changes
    var onProcessingChanged: ((Bool) -> Void)?

    /// Called when tool status changes
    var onToolStatusChanged: ((String?, Bool) -> Void)?

    /// Called when a tool needs to be executed (returns tool result via callback)
    var onToolCall: ((String, [String: Any], @escaping (String) -> Void) -> Void)?

    /// Called when connection state changes
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?

    /// Called when fully disconnected (not during reconnect)
    var onDisconnected: (() -> Void)?

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var requestCounter: Int = 0
    private var pendingRequests: [String: CheckedContinuation<OpenClawResponse, Error>] = [:]
    private var receiveTask: Task<Void, Never>?

    // MARK: - Reconnection

    private var intentionalDisconnect: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var hasConnectedBefore: Bool = false

    // MARK: - Network Monitoring

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "openvision.network")
    private var isNetworkAvailable: Bool = true

    // MARK: - Heartbeat

    private var heartbeatTask: Task<Void, Never>?
    private var awaitingPong: Bool = false

    // MARK: - App Lifecycle

    private var lifecycleObservers: [Any] = []
    private var wasConnectedBeforeSuspend: Bool = false

    // MARK: - Initialization

    private init() {
        setupNetworkMonitor()
        setupLifecycleObservers()
    }

    deinit {
        networkMonitor.cancel()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - State Machine

    /// Transition to a new connection state
    private func transition(to newState: AIConnectionState) {
        let oldState = connectionState
        guard oldState != newState else { return }

        print("[OpenClaw] \(oldState.description) → \(newState.description)")
        connectionState = newState

        onConnectionStateChanged?(newState)

        // State entry side effects
        switch newState {
        case .connected:
            hasConnectedBefore = true
            startHeartbeat()

        case .reconnecting(let attempt):
            stopHeartbeat()
            scheduleReconnect(attempt: attempt)

        case .disconnected:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.notConnected)
            onDisconnected?()

        case .suspended:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.notConnected)

        case .failed:
            stopHeartbeat()
            cancelReconnect()
            closeWebSocket()
            failPendingRequests(error: AIBackendError.connectionFailed)
            onDisconnected?()

        case .connecting:
            break
        }
    }

    // MARK: - Connection

    /// Connect to OpenClaw gateway
    func connect() async throws {
        // Check configuration
        guard gatewayURL != nil, !authToken.isEmpty else {
            throw AIBackendError.notConfigured
        }

        // Already connected?
        guard !connectionState.isUsable else {
            debugInfo = "Already connected"
            return
        }

        // Already attempting?
        guard !connectionState.isAttempting else {
            debugInfo = "Connection in progress"
            return
        }

        intentionalDisconnect = false
        lastError = nil
        transition(to: .connecting)

        try await performConnect()
    }

    /// Internal connect implementation
    private func performConnect() async throws {
        closeWebSocket()
        requestCounter = 0
        failPendingRequests(error: AIBackendError.notConnected)

        guard !Task.isCancelled else { return }

        do {
            debugInfo = "Creating WebSocket..."

            guard let url = buildWebSocketURL() else {
                throw AIBackendError.notConfigured
            }

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300

            urlSession = URLSession(configuration: config)
            webSocket = urlSession?.webSocketTask(with: url)
            webSocket?.resume()

            // Start receive loop
            startReceiving()

            // Wait for connection (up to 5 seconds)
            debugInfo = "Waiting for connection..."
            var connected = false
            for _ in 0..<25 {
                guard !Task.isCancelled else {
                    closeWebSocket()
                    return
                }
                if webSocket?.state == .running {
                    connected = true
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard connected else {
                throw AIBackendError.connectionTimeout
            }

            guard !Task.isCancelled else {
                closeWebSocket()
                return
            }

            // Send handshake
            debugInfo = "Sending handshake..."
            try await sendHandshake()

            transition(to: .connected)
            debugInfo = "Connected!"
            print("[OpenClaw] Connected successfully")

        } catch is CancellationError {
            closeWebSocket()
            return

        } catch {
            lastError = error.localizedDescription
            debugInfo = "Error: \(error.localizedDescription)"
            print("[OpenClaw] Connection error: \(error)")

            closeWebSocket()

            // Handle reconnect for auto-reconnect attempts
            if case .reconnecting = connectionState {
                return
            }

            // Decide whether to auto-reconnect
            if !intentionalDisconnect && isNetworkAvailable {
                transition(to: .reconnecting(attempt: 1))
                throw error
            } else {
                transition(to: .failed("Connection failed"))
                throw error
            }
        }
    }

    /// Disconnect intentionally
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        print("[OpenClaw] Intentional disconnect")
        intentionalDisconnect = true
        transition(to: .disconnected)
    }

    /// Build WebSocket URL with authentication
    private func buildWebSocketURL() -> URL? {
        guard var components = URLComponents(url: gatewayURL!, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Ensure WebSocket scheme
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }

        // Add path if needed
        if components.path.isEmpty {
            components.path = "/ws"
        }

        // Add token
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: authToken))
        components.queryItems = queryItems

        return components.url
    }

    /// Close WebSocket without changing state
    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// Fail all pending requests
    private func failPendingRequests(error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Handshake

    /// Send initial connect handshake
    private func sendHandshake() async throws {
        // Match xmeta's handshake format exactly
        let params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "cli",
                "displayName": "OpenVision",
                "version": "1.0.0",
                "platform": "ios",
                "mode": "cli"
            ],
            "caps": [String](), // Empty array like xmeta
            "auth": ["token": authToken],
            "locale": "en-US",
            "userAgent": "OpenVision/1.0.0"
        ]

        let response = try await sendRequest(method: .connect, params: params)

        guard response.ok else {
            let errorMsg = response.error?.message ?? "Handshake failed"
            throw AIBackendError.requestFailed(errorMsg)
        }
    }

    // MARK: - Send Message

    /// Session key for conversation continuity
    private static var sessionKey = "openvision-\(UUID().uuidString.prefix(8))"

    /// Send a text message to the AI agent
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard connectionState.isUsable else {
            throw AIBackendError.notConnected
        }

        isProcessing = true
        onProcessingChanged?(true)

        // Build params in the format expected by chat.send
        var params: [String: Any] = [
            "message": text,
            "sessionKey": Self.sessionKey,
            "idempotencyKey": UUID().uuidString
        ]

        // Add image as attachment if provided
        if let imageData = imageData {
            let attachment: [String: Any] = [
                "type": "image",
                "mimeType": "image/jpeg",
                "content": imageData.base64EncodedString()
            ]
            params["attachments"] = [attachment]
        }

        print("[OpenClaw] Sending message: \(text.prefix(50))...")

        let response = try await sendRequest(method: .sendMessage, params: params)

        guard response.ok else {
            isProcessing = false
            onProcessingChanged?(false)
            let errorMsg = response.error?.message ?? "Message failed"
            throw AIBackendError.requestFailed(errorMsg)
        }

        // Response comes via events (onAgentMessage callback), not in the initial response
        print("[OpenClaw] Message sent, waiting for response events...")
    }

    /// Cancel the current request/run
    func cancelRequest() {
        guard connectionState.isUsable else { return }

        Task {
            _ = try? await sendRequest(method: .cancelRun, params: [:])
        }

        isProcessing = false
        isToolRunning = false
        currentToolName = nil
        onProcessingChanged?(false)
        onToolStatusChanged?(nil, false)
    }

    /// Interrupt the AI (barge-in support)
    func interrupt() async {
        cancelRequest()
    }

    /// Send tool result back to OpenClaw
    func sendToolResult(callId: String, result: String) async throws {
        guard connectionState.isUsable else { return }

        let params: [String: Any] = [
            "callId": callId,
            "result": result
        ]

        print("[OpenClaw] Sending tool result for \(callId): \(result.prefix(50))...")
        _ = try await sendRequest(method: .toolResult, params: params)
    }

    // MARK: - Request/Response

    /// Send a request and wait for response
    private func sendRequest(method: OpenClawMethod, params: [String: Any]) async throws -> OpenClawResponse {
        guard let webSocket = webSocket, webSocket.state == .running else {
            throw AIBackendError.notConnected
        }

        requestCounter += 1
        let requestId = "req-\(requestCounter)"

        let request = OpenClawRequest(id: requestId, method: method.rawValue, params: params)

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            // Store continuation first
            pendingRequests[requestId] = continuation

            webSocket.send(.data(data)) { [weak self] error in
                if let error = error {
                    // Only resume if we can remove from pending (prevents double-resume)
                    Task { @MainActor in
                        if self?.pendingRequests.removeValue(forKey: requestId) != nil {
                            continuation.resume(throwing: error)
                        }
                        // If removeValue returns nil, the continuation was already
                        // resumed by handleResponse or failPendingRequests
                    }
                }
            }
        }
    }

    // MARK: - Receive Loop

    /// Start receiving messages from WebSocket
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let webSocket = self.webSocket else { break }

                do {
                    let message = try await webSocket.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.handleConnectionDrop(error: error)
                    }
                    break
                }
            }
        }
    }

    /// Handle incoming WebSocket message
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data

        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            return
        }

        // Try to decode as response
        if let response = try? JSONDecoder().decode(OpenClawResponse.self, from: data),
           response.type == "res" {
            handleResponse(response)
            return
        }

        // Try to decode as event
        if let event = try? JSONDecoder().decode(OpenClawEvent.self, from: data),
           event.type == "event" {
            handleEvent(event)
            return
        }

        print("[OpenClaw] Unknown message type")
    }

    /// Handle response to a request
    private func handleResponse(_ response: OpenClawResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.id) else {
            print("[OpenClaw] No pending request for \(response.id)")
            return
        }

        continuation.resume(returning: response)
    }

    /// Accumulated response text for streaming
    private var accumulatedResponse: String = ""

    /// Handle event from server
    private func handleEvent(_ event: OpenClawEvent) {
        guard let payload = event.payload else {
            print("[OpenClaw] Event without payload: \(event.event)")
            return
        }

        switch event.event {
        case "agent":
            // Agent streaming events - check the stream type
            let stream = payload["stream"]?.stringValue ?? ""
            let data = payload["data"]?.dictionaryValue ?? [:]

            switch stream {
            case "assistant":
                // Text chunk from assistant
                if let text = data["text"] as? String, !text.isEmpty {
                    accumulatedResponse += text
                    print("[OpenClaw] Assistant chunk: \(text.prefix(50))...")
                }

            case "tool":
                // Tool events
                if let toolName = data["name"] as? String {
                    currentToolName = toolName
                    isToolRunning = true
                    onToolStatusChanged?(toolName, true)
                    print("[OpenClaw] Tool call: \(toolName)")

                    // Extract tool arguments
                    let args = data["arguments"] as? [String: Any] ?? data["input"] as? [String: Any] ?? [:]
                    let toolCallId = data["id"] as? String ?? data["callId"] as? String

                    // Call the tool handler if registered
                    onToolCall?(toolName, args) { [weak self] result in
                        Task { @MainActor in
                            // Send tool result back if we have a call ID
                            if let callId = toolCallId {
                                try? await self?.sendToolResult(callId: callId, result: result)
                            }
                            self?.isToolRunning = false
                            self?.onToolStatusChanged?(self?.currentToolName, false)
                        }
                    }
                }
                if let status = data["status"] as? String, status == "complete" {
                    isToolRunning = false
                    onToolStatusChanged?(currentToolName, false)
                }

            default:
                print("[OpenClaw] Agent stream: \(stream)")
            }

        case "chat":
            // Chat events - check the state
            let state = payload["state"]?.stringValue ?? ""
            print("[OpenClaw] Chat event: state=\(state)")

            switch state {
            case "delta":
                // Streaming delta - accumulate text
                if let message = payload["message"]?.dictionaryValue,
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if let text = block["text"] as? String, !text.isEmpty {
                            accumulatedResponse += text
                            print("[OpenClaw] Delta: \(text.prefix(30))...")
                        }
                    }
                }

            case "final":
                // Final response
                print("[OpenClaw] Got final response!")
                isProcessing = false
                onProcessingChanged?(false)

                var finalText = ""
                if let message = payload["message"]?.dictionaryValue,
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if let text = block["text"] as? String {
                            finalText += text
                        }
                    }
                }

                // Use final text or accumulated text
                let responseText = !finalText.isEmpty ? finalText : accumulatedResponse

                if !responseText.isEmpty {
                    print("[OpenClaw] Response: \(responseText.prefix(100))...")
                    onAgentMessage?(responseText)
                } else {
                    print("[OpenClaw] No response text found!")
                }

                // Reset for next message
                accumulatedResponse = ""

            case "error":
                isProcessing = false
                onProcessingChanged?(false)
                let errorMsg = payload["errorMessage"]?.stringValue ?? "Unknown error"
                print("[OpenClaw] Chat error: \(errorMsg)")
                lastError = errorMsg
                onAgentMessage?("Sorry, there was an error: \(errorMsg)")
                accumulatedResponse = ""

            case "aborted":
                isProcessing = false
                onProcessingChanged?(false)
                print("[OpenClaw] Chat aborted")
                accumulatedResponse = ""

            default:
                print("[OpenClaw] Chat state: \(state)")
            }

        case "connect.challenge", "tick", "presence", "health":
            // Ignore these events
            break

        default:
            print("[OpenClaw] Unknown event: \(event.event)")
        }
    }

    /// Handle connection drop
    private func handleConnectionDrop(error: Error) async {
        print("[OpenClaw] Connection dropped: \(error)")

        guard !intentionalDisconnect else {
            transition(to: .disconnected)
            return
        }

        // Auto-reconnect if we had a successful connection before
        if hasConnectedBefore && isNetworkAvailable {
            transition(to: .reconnecting(attempt: 1))
        } else {
            transition(to: .failed(error.localizedDescription))
        }
    }

    // MARK: - Auto-Reconnect

    /// Schedule reconnect with exponential backoff
    private func scheduleReconnect(attempt: Int) {
        guard attempt <= Constants.OpenClaw.maxReconnectAttempts else {
            print("[OpenClaw] Max reconnect attempts exceeded")
            transition(to: .failed("Max reconnect attempts exceeded"))
            return
        }

        // Calculate delay with full jitter
        let baseDelay = Constants.OpenClaw.initialReconnectDelay
        let maxDelay = Constants.OpenClaw.maxReconnectDelay
        let exponentialDelay = min(maxDelay, baseDelay * pow(2.0, Double(attempt - 1)))
        let jitteredDelay = Double.random(in: 0...exponentialDelay)

        print("[OpenClaw] Scheduling reconnect attempt \(attempt) in \(String(format: "%.1f", jitteredDelay))s")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(jitteredDelay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await self?.attemptReconnect(attempt: attempt)
        }
    }

    /// Attempt reconnection
    private func attemptReconnect(attempt: Int) async {
        guard case .reconnecting = connectionState else { return }

        do {
            try await performConnect()
        } catch {
            // performConnect handles the transition to next reconnect attempt
            if case .reconnecting = connectionState {
                transition(to: .reconnecting(attempt: attempt + 1))
            }
        }
    }

    /// Cancel scheduled reconnect
    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Heartbeat

    /// Start heartbeat ping/pong
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Constants.OpenClaw.heartbeatInterval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                await self?.sendPing()
            }
        }
    }

    /// Stop heartbeat
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        awaitingPong = false
    }

    /// Send ping and expect pong
    private func sendPing() async {
        guard let webSocket = webSocket, webSocket.state == .running else { return }

        if awaitingPong {
            // Previous pong never arrived - connection is dead
            print("[OpenClaw] Pong timeout - connection dead")
            await handleConnectionDrop(error: AIBackendError.connectionTimeout)
            return
        }

        awaitingPong = true

        webSocket.sendPing { [weak self] error in
            Task { @MainActor in
                if let error = error {
                    print("[OpenClaw] Ping failed: \(error)")
                    await self?.handleConnectionDrop(error: error)
                } else {
                    self?.awaitingPong = false
                }
            }
        }
    }

    // MARK: - Network Monitoring

    /// Setup network path monitor
    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let wasAvailable = self?.isNetworkAvailable ?? true
                self?.isNetworkAvailable = path.status == .satisfied

                if !wasAvailable && path.status == .satisfied {
                    // Network restored - reconnect if suspended
                    if self?.connectionState == .suspended {
                        print("[OpenClaw] Network restored, resuming connection")
                        try? await self?.connect()
                    }
                } else if wasAvailable && path.status != .satisfied {
                    // Network lost - suspend if connected
                    if self?.connectionState.isUsable == true {
                        print("[OpenClaw] Network lost, suspending connection")
                        self?.transition(to: .suspended)
                    }
                }
            }
        }

        networkMonitor.start(queue: networkQueue)
    }

    // MARK: - App Lifecycle

    /// Setup app lifecycle observers
    private func setupLifecycleObservers() {
        // App entering background
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBackground()
            }
        }

        // App entering foreground
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppForeground()
            }
        }

        lifecycleObservers = [backgroundObserver, foregroundObserver]
    }

    /// Handle app entering background
    private func handleAppBackground() {
        if connectionState.isUsable {
            wasConnectedBeforeSuspend = true
            transition(to: .suspended)
        } else {
            wasConnectedBeforeSuspend = false
        }
    }

    /// Handle app entering foreground
    private func handleAppForeground() async {
        if wasConnectedBeforeSuspend && connectionState == .suspended {
            print("[OpenClaw] Resuming connection after foreground")
            try? await connect()
        }
    }

    // MARK: - Test Connection

    /// Test connection to the gateway (for settings UI)
    func testConnection() async -> Result<Void, Error> {
        guard gatewayURL != nil, !authToken.isEmpty else {
            return .failure(AIBackendError.notConfigured)
        }

        do {
            // Save current state
            let wasConnected = connectionState.isUsable

            // If not connected, try to connect
            if !wasConnected {
                try await connect()
            }

            // If we got here, connection succeeded
            if !wasConnected {
                // Disconnect if we connected just for the test
                await disconnect()
            }

            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - String Extension

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
