// OpenVision - AIBackendProtocol.swift
// Common interface for AI backends (OpenClaw, Gemini Live)

import Foundation

/// Protocol defining the interface for AI backends
@MainActor
protocol AIBackendProtocol: ObservableObject {
    /// Current connection state
    var connectionState: AIConnectionState { get }

    /// Whether the backend is currently processing a request
    var isProcessing: Bool { get }

    /// Connect to the AI backend
    func connect() async throws

    /// Disconnect from the AI backend
    func disconnect() async

    /// Send a text message to the AI
    func sendMessage(_ text: String) async throws

    /// Send a message with an image
    func sendMessage(_ text: String, imageData: Data?) async throws

    /// Cancel any ongoing request
    func cancelRequest()
}

/// Connection state for AI backends
enum AIConnectionState: Equatable, CustomStringConvertible {
    /// Not connected
    case disconnected

    /// Connection attempt in progress
    case connecting

    /// Fully connected and operational
    case connected

    /// Auto-reconnecting after unexpected drop
    case reconnecting(attempt: Int)

    /// App backgrounded, connection intentionally paused
    case suspended

    /// Connection failed after max retries
    case failed(String)

    var isUsable: Bool {
        if case .connected = self { return true }
        return false
    }

    var isAttempting: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let n): return "Reconnecting (attempt \(n))..."
        case .suspended: return "Suspended"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var statusColor: String {
        switch self {
        case .disconnected: return "gray"
        case .connecting, .reconnecting: return "orange"
        case .connected: return "green"
        case .suspended: return "yellow"
        case .failed: return "red"
        }
    }
}

/// Events emitted by AI backends
enum AIBackendEvent {
    /// Agent started/stopped processing
    case processingChanged(Bool)

    /// Agent sent a text response
    case agentMessage(String)

    /// User's speech was transcribed
    case userTranscription(String)

    /// Tool execution status changed
    case toolStatus(name: String?, isRunning: Bool)

    /// Audio data received (for Gemini Live)
    case audioReceived(Data)

    /// Connection state changed
    case connectionStateChanged(AIConnectionState)

    /// Error occurred
    case error(Error)
}

/// Errors specific to AI backends
enum AIBackendError: LocalizedError {
    case notConfigured
    case notConnected
    case connectionFailed
    case connectionTimeout
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI backend not configured"
        case .notConnected: return "Not connected to AI backend"
        case .connectionFailed: return "Failed to connect to AI backend"
        case .connectionTimeout: return "Connection timed out"
        case .invalidResponse: return "Invalid response from AI backend"
        case .requestFailed(let msg): return "Request failed: \(msg)"
        }
    }
}
