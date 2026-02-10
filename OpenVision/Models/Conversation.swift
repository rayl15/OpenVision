// OpenVision - Conversation.swift
// Conversation and message data models

import Foundation

/// A conversation with the AI assistant
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [Message]
    let createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [Message] = [],
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    /// Whether this conversation contains any photos
    var hasPhotos: Bool {
        messages.contains { $0.hasPhoto }
    }

    /// Generate a title from the first user message
    mutating func generateTitle() {
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            let content = firstUserMessage.content
            let words = content.split(separator: " ").prefix(6)
            title = words.joined(separator: " ")
            if content.split(separator: " ").count > 6 {
                title += "..."
            }
        }
    }

    /// Add a message to the conversation
    mutating func addMessage(_ message: Message) {
        messages.append(message)
        lastActivityAt = Date()

        // Auto-generate title from first user message
        if title == "New Conversation" && message.role == .user {
            generateTitle()
        }
    }
}

/// A single message in a conversation
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var photoData: Data?
    var toolName: String?
    var toolResult: String?

    enum Role: String, Codable {
        case user
        case assistant
        case system
        case tool
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        photoData: Data? = nil,
        toolName: String? = nil,
        toolResult: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.photoData = photoData
        self.toolName = toolName
        self.toolResult = toolResult
    }

    /// Whether this message includes a photo
    var hasPhoto: Bool {
        photoData != nil
    }

    /// Whether this message is a tool call
    var isToolCall: Bool {
        toolName != nil
    }

    // MARK: - Factory Methods

    static func user(_ content: String, photoData: Data? = nil) -> Message {
        Message(role: .user, content: content, photoData: photoData)
    }

    static func assistant(_ content: String) -> Message {
        Message(role: .assistant, content: content)
    }

    static func system(_ content: String) -> Message {
        Message(role: .system, content: content)
    }

    static func tool(name: String, result: String) -> Message {
        Message(role: .tool, content: result, toolName: name, toolResult: result)
    }
}
