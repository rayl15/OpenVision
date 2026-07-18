// OpenVision - AIBackendConformances.swift
// AIBackend conformances for the five services, in one place so the adapters are easy to audit.
//
// Three services (OpenClaw, OpenAI, Gemma) already match the protocol surface and conform for
// free; Apple Intelligence and Gemini Live get thin adapters where their native APIs differ.

import Foundation

// MARK: - OpenClaw

extension OpenClawService: AIBackend {
    var backendType: AIBackendType { .openClaw }
    var supportsImageInput: Bool { true }
}

// MARK: - OpenAI

extension OpenAIService: AIBackend {
    var backendType: AIBackendType { .openAI }
    var supportsImageInput: Bool { true }
}

// MARK: - Local Gemma (MLX)

extension GemmaLocalService: AIBackend {
    var backendType: AIBackendType { .localGemma }
    var supportsImageInput: Bool { true }
    var localLLM: LocalTextLLM? { self }
}

// MARK: - Apple Intelligence

extension AppleFoundationService: AIBackend {
    var backendType: AIBackendType { .appleFoundation }
    var localLLM: LocalTextLLM? { self }

    /// Text-only backend — sends the prompt and ignores the image (supportsImageInput is false,
    /// so callers route photo commands elsewhere).
    func sendMessage(_ text: String, imageData: Data?) async throws {
        await sendMessage(text)
    }
}

// MARK: - Gemini Live

extension GeminiLiveService: AIBackend {
    var backendType: AIBackendType { .geminiLive }

    /// Gemini Live is a streaming session: replies arrive via onOutputTranscription /
    /// onTurnComplete (wired by the voice agent), not a whole-message callback — so the
    /// request/response callbacks are intentionally inert here.
    var onAgentMessage: ((String) -> Void)? {
        get { nil }
        set {}
    }
    var onProcessingChanged: ((Bool) -> Void)? {
        get { nil }
        set {}
    }

    /// Video frames stream continuously in live mode; a "message" is just a text turn.
    func sendMessage(_ text: String, imageData: Data?) async throws {
        try await sendText(text)
    }
}
