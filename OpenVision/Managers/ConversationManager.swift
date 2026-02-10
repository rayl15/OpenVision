// OpenVision - ConversationManager.swift
// Manages conversation history with persistence

import Foundation

/// Manages conversation history and persistence
@MainActor
final class ConversationManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ConversationManager()

    // MARK: - Published State

    /// All conversations
    @Published var conversations: [Conversation] = []

    /// Currently active conversation
    @Published var currentConversation: Conversation?

    // MARK: - File Storage

    private let fileURL: URL

    // MARK: - Configuration

    /// Inactivity timeout before starting new conversation (5 minutes)
    private let inactivityTimeout: TimeInterval = Constants.Storage.conversationInactivityTimeout

    /// Maximum conversations to keep
    private let maxConversations: Int = Constants.Storage.maxConversations

    // MARK: - Initialization

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documentsURL.appendingPathComponent(Constants.Storage.conversationsFileName)

        loadConversations()
    }

    // MARK: - Conversation Management

    /// Start a new conversation
    func startNewConversation() {
        let conversation = Conversation()
        currentConversation = conversation
        conversations.insert(conversation, at: 0)
        saveConversations()
        print("[ConversationManager] Started new conversation: \(conversation.id)")
    }

    /// Get or create current conversation
    func getOrCreateCurrentConversation() -> Conversation {
        // Check if current conversation is still active
        if let current = currentConversation {
            let timeSinceActivity = Date().timeIntervalSince(current.lastActivityAt)
            if timeSinceActivity < inactivityTimeout {
                return current
            }
        }

        // Start new conversation
        startNewConversation()
        return currentConversation!
    }

    /// Add a message to the current conversation
    func addMessage(_ message: Message) {
        var conversation = getOrCreateCurrentConversation()
        conversation.addMessage(message)

        // Update in list
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        }

        currentConversation = conversation
        saveConversations()
    }

    /// Add user message
    func addUserMessage(_ text: String, photoData: Data? = nil) {
        let message = Message.user(text, photoData: photoData)
        addMessage(message)
    }

    /// Add assistant message
    func addAssistantMessage(_ text: String) {
        let message = Message.assistant(text)
        addMessage(message)
    }

    /// Add tool message
    func addToolMessage(name: String, result: String) {
        let message = Message.tool(name: name, result: result)
        addMessage(message)
    }

    /// Delete a conversation
    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }

        if currentConversation?.id == conversation.id {
            currentConversation = nil
        }

        saveConversations()
        print("[ConversationManager] Deleted conversation: \(conversation.id)")
    }

    /// Delete all conversations
    func deleteAllConversations() {
        conversations.removeAll()
        currentConversation = nil
        saveConversations()
        print("[ConversationManager] Deleted all conversations")
    }

    /// Resume a conversation
    func resumeConversation(_ conversation: Conversation) {
        currentConversation = conversation

        // Move to top of list
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
        }

        print("[ConversationManager] Resumed conversation: \(conversation.id)")
    }

    // MARK: - Persistence

    /// Load conversations from disk
    private func loadConversations() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[ConversationManager] No conversations file found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            conversations = try decoder.decode([Conversation].self, from: data)
            print("[ConversationManager] Loaded \(conversations.count) conversations")

            // Set current conversation to most recent
            currentConversation = conversations.first

        } catch {
            print("[ConversationManager] Error loading conversations: \(error)")
        }
    }

    /// Save conversations to disk
    private func saveConversations() {
        // Trim to max conversations
        if conversations.count > maxConversations {
            conversations = Array(conversations.prefix(maxConversations))
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
            print("[ConversationManager] Saved \(conversations.count) conversations")

        } catch {
            print("[ConversationManager] Error saving conversations: \(error)")
        }
    }

    // MARK: - Search

    /// Search conversations
    func search(_ query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query) ||
            conversation.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(query)
            }
        }
    }

    // MARK: - Statistics

    /// Total message count across all conversations
    var totalMessageCount: Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    /// Total photo count across all conversations
    var totalPhotoCount: Int {
        conversations.reduce(0) { sum, conversation in
            sum + conversation.messages.filter { $0.hasPhoto }.count
        }
    }
}
