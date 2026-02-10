// OpenVision - GeminiVisionService.swift
// Gemini Live as a vision-only sensor - receives video, can be queried for scene description
// This is NOT the brain - OpenClaw is. Gemini just provides "eyes".

import Foundation
import UIKit

/// Gemini Vision Service - Live video streaming with on-demand scene queries
///
/// Architecture:
/// - Receives continuous video frames (1fps) from glasses
/// - Can be queried: "What do you see?"
/// - Does NOT make decisions - just describes what it sees
/// - OpenClaw remains the brain for all decisions and actions
@MainActor
final class GeminiVisionService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiVisionService()

    // MARK: - Published State

    @Published var connectionState: GeminiVisionState = .disconnected
    @Published var isProcessingQuery: Bool = false
    @Published var lastSceneDescription: String = ""

    // MARK: - Connection State

    enum GeminiVisionState: Equatable {
        case disconnected
        case connecting
        case settingUp
        case ready
        case error(String)

        var isConnected: Bool {
            self == .ready
        }
    }

    // MARK: - Configuration

    private var apiKey: String {
        SettingsManager.shared.settings.geminiAPIKey
    }

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isSetupComplete: Bool = false

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private let frameInterval: TimeInterval = 0.5 // 2fps (better responsiveness than 1fps)
    private var framesSent: Int = 0

    // MARK: - Query Handling

    private var pendingQueryContinuation: CheckedContinuation<String, Error>?
    private var accumulatedResponse: String = ""

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection

    /// Connect to Gemini Live for vision-only mode
    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw GeminiVisionError.notConfigured
        }

        guard connectionState != .ready else { return }
        guard connectionState != .connecting && connectionState != .settingUp else { return }

        connectionState = .connecting
        print("[GeminiVision] Connecting...")

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
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            guard connected else {
                throw GeminiVisionError.connectionTimeout
            }

            connectionState = .settingUp

            // Send setup for vision-only mode
            try await sendSetup()

            // Wait for setup complete
            for _ in 0..<50 {
                if isSetupComplete {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            guard isSetupComplete else {
                throw GeminiVisionError.setupFailed
            }

            connectionState = .ready
            print("[GeminiVision] Connected and ready for video")

        } catch {
            connectionState = .error(error.localizedDescription)
            closeWebSocket()
            throw error
        }
    }

    /// Disconnect from Gemini
    func disconnect() {
        print("[GeminiVision] Disconnecting")
        connectionState = .disconnected
        closeWebSocket()
    }

    /// Build WebSocket URL
    private func buildWebSocketURL() -> URL {
        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        var components = URLComponents(string: baseURL)!
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

        // Fail any pending query
        pendingQueryContinuation?.resume(throwing: GeminiVisionError.disconnected)
        pendingQueryContinuation = nil
    }

    // MARK: - Setup

    /// Send setup message for vision-only mode
    private func sendSetup() async throws {
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-2.0-flash-exp",
                "generationConfig": [
                    "responseModalities": ["TEXT"], // Text responses only (no audio)
                    "temperature": 0.7
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": """
                        You are a vision sensor for a smart glasses assistant. Your ONLY job is to describe what you see in the video feed.

                        When asked to describe the scene:
                        - Be concise but informative (2-3 sentences max)
                        - Focus on the most relevant/interesting elements
                        - Mention people, objects, text, actions happening
                        - If you see text, read it out

                        You do NOT make decisions or take actions. You only describe what you see.
                        """]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": true // We control when to query, not automatic
                    ]
                ]
            ]
        ]

        try await sendJSON(setup)
    }

    // MARK: - Video Streaming

    /// Send a video frame to Gemini (throttled to 2fps)
    func sendVideoFrame(_ image: UIImage) {
        guard connectionState == .ready else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        // Resize for efficiency (640x480 is good for real-time)
        let resized = resizeImage(image, to: CGSize(width: 640, height: 480))

        guard let jpegData = resized.jpegData(compressionQuality: 0.6) else { return }

        framesSent += 1

        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "image/jpeg",
                        "data": jpegData.base64EncodedString()
                    ]
                ]
            ]
        ]

        Task {
            do {
                try await sendJSON(message)
                // Log every 10th frame
                if framesSent % 10 == 0 {
                    print("[GeminiVision] Sent frame #\(framesSent) (\(jpegData.count) bytes)")
                }
            } catch {
                print("[GeminiVision] Failed to send frame: \(error)")
            }
        }
    }

    /// Resize image for efficient transmission
    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let aspectWidth = size.width / image.size.width
        let aspectHeight = size.height / image.size.height
        let aspectRatio = min(aspectWidth, aspectHeight)

        let newSize = CGSize(
            width: image.size.width * aspectRatio,
            height: image.size.height * aspectRatio
        )

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        return resized
    }

    /// Send video frame from Data (already JPEG encoded)
    func sendVideoFrame(jpegData: Data) {
        guard connectionState == .ready else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        framesSent += 1

        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "image/jpeg",
                        "data": jpegData.base64EncodedString()
                    ]
                ]
            ]
        ]

        Task {
            do {
                try await sendJSON(message)
                if framesSent % 10 == 0 {
                    print("[GeminiVision] Sent frame #\(framesSent) (\(jpegData.count) bytes)")
                }
            } catch {
                print("[GeminiVision] Failed to send frame: \(error)")
            }
        }
    }

    // MARK: - Scene Query

    /// Ask Gemini to describe what it currently sees
    /// This is the main API for OpenClaw to query vision
    func describeScene(prompt: String = "What do you see right now? Be concise.") async throws -> String {
        guard connectionState == .ready else {
            throw GeminiVisionError.notConnected
        }

        guard pendingQueryContinuation == nil else {
            throw GeminiVisionError.queryInProgress
        }

        isProcessingQuery = true
        accumulatedResponse = ""

        defer {
            isProcessingQuery = false
        }

        // Send the query as a client content turn
        let query: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [["text": prompt]]
                    ]
                ],
                "turnComplete": true
            ]
        ]

        try await sendJSON(query)

        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { continuation in
            pendingQueryContinuation = continuation

            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = pendingQueryContinuation {
                    pendingQueryContinuation = nil
                    cont.resume(throwing: GeminiVisionError.queryTimeout)
                }
            }
        }
    }

    // MARK: - Send JSON

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket = webSocket else {
            throw GeminiVisionError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: object)
        try await webSocket.send(.data(data))
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
                        print("[GeminiVision] Receive error: \(error)")
                        await MainActor.run {
                            self.connectionState = .disconnected
                        }
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
            print("[GeminiVision] Setup complete")
            return
        }

        // Server content (response to our query)
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
            return
        }

        // GoAway
        if json["goAway"] != nil {
            print("[GeminiVision] Server closing connection")
            connectionState = .disconnected
            return
        }
    }

    /// Handle server content
    private func handleServerContent(_ content: [String: Any]) {
        // Model turn with text response
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String {
                    accumulatedResponse += text
                }
            }
        }

        // Turn complete - resolve the query
        if content["turnComplete"] as? Bool == true {
            let response = accumulatedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            lastSceneDescription = response

            if let continuation = pendingQueryContinuation {
                pendingQueryContinuation = nil
                continuation.resume(returning: response)
            }
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
}

// MARK: - Errors

enum GeminiVisionError: LocalizedError {
    case notConfigured
    case notConnected
    case connectionTimeout
    case setupFailed
    case disconnected
    case queryInProgress
    case queryTimeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Gemini API key not configured"
        case .notConnected: return "Not connected to Gemini"
        case .connectionTimeout: return "Connection timed out"
        case .setupFailed: return "Failed to setup Gemini session"
        case .disconnected: return "Disconnected from Gemini"
        case .queryInProgress: return "A query is already in progress"
        case .queryTimeout: return "Query timed out"
        }
    }
}
