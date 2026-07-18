// OpenVision - AIBackendProtocol.swift
// The AIBackend contract every conversational backend conforms to, plus shared types.
//
// This is the app's pluggability seam: the voice agent drives whichever backend the user selected
// through this protocol alone — no concrete service types, no downcasts. Adding a backend =
// conform your service + add one case to AIBackendType + one line in AIBackendRegistry.

import Foundation

/// A conversational AI backend the voice agent can drive.
///
/// Capabilities have defaults, so a backend only declares what it actually supports:
/// - `localLLM` — an on-device routing brain (face intents, web search, native tools).
/// - `supportsImageInput` — `sendMessage` accepts a glasses frame for photo commands.
@MainActor
protocol AIBackend: AnyObject {
    /// The settings case this backend serves (drives selection in AIBackendRegistry).
    var backendType: AIBackendType { get }

    /// Full reply, delivered when generation completes.
    var onAgentMessage: ((String) -> Void)? { get set }
    /// Busy-state changes (drives the thinking/listening orb).
    var onProcessingChanged: ((Bool) -> Void)? { get set }

    /// Send a text turn, optionally with an image (only when `supportsImageInput`).
    func sendMessage(_ text: String, imageData: Data?) async throws

    // MARK: Capabilities (defaulted — override only what you support)

    /// On-device routing brain, if this backend has one (Gemma, Apple Intelligence).
    var localLLM: LocalTextLLM? { get }
    /// Whether sendMessage accepts imageData (OpenClaw, OpenAI, Gemma).
    var supportsImageInput: Bool { get }
}

extension AIBackend {
    var localLLM: LocalTextLLM? { nil }
    var supportsImageInput: Bool { false }
}

/// Maps the user's selected `AIBackendType` to the live service instance.
@MainActor
enum AIBackendRegistry {
    static func backend(for type: AIBackendType) -> AIBackend {
        switch type {
        case .openClaw: return OpenClawService.shared
        case .geminiLive: return GeminiLiveService.shared
        case .openAI: return OpenAIService.shared
        case .appleFoundation: return AppleFoundationService.shared
        case .localGemma: return GemmaLocalService.shared
        }
    }

    /// Every backend, for bulk wiring (e.g. attaching the shared reply/state callbacks once).
    static var all: [AIBackend] { AIBackendType.allCases.map(backend(for:)) }
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
