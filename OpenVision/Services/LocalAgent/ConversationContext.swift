// OpenVision - ConversationContext.swift
// A small, bounded record of the current conversation so follow-up questions work
// ("what's the capital of France?" → "what's its population?").
//
// Used by the stateless prompt-based backends (Local Gemma, OpenAI). Cloud backends that keep
// their own server-side context (OpenClaw, Gemini Live) ignore this. Apple Foundation keeps
// context natively via a reused LanguageModelSession, so it doesn't read this either.

import Foundation

@MainActor
final class ConversationContext {
    static let shared = ConversationContext()

    struct Turn { let role: String; let content: String }   // role: "user" | "assistant"

    private(set) var turns: [Turn] = []

    /// Keep the last few exchanges — enough for natural follow-ups, bounded so local models stay
    /// well within their memory/context budget.
    private let maxMessages = 8

    private init() {}

    func record(user: String, assistant: String) {
        append(role: "user", content: user)
        append(role: "assistant", content: assistant)
    }

    func clear() { turns.removeAll() }

    private func append(role: String, content: String) {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        turns.append(Turn(role: role, content: clean))
        if turns.count > maxMessages { turns.removeFirst(turns.count - maxMessages) }
    }
}
