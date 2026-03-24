//
//  AIChatViewModel.swift
//  TablePro
//
//  View model for AI chat panel - manages conversation, streaming, and provider resolution.
//

import Foundation
import Observation
import os
import TableProPluginKit

/// View model for the AI chat panel
@MainActor @Observable
final class AIChatViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AIChatViewModel")

    // MARK: - Published State

    var messages: [AIChatMessage] = []
    var inputText: String = ""
    var isStreaming: Bool = false
    var errorMessage: String?
    var lastMessageFailed: Bool = false
    var conversations: [AIConversation] = []
    var activeConversationID: UUID?
    var showAIAccessConfirmation = false

    // MARK: - Context Properties

    /// Current database connection (set by parent view)
    var connection: DatabaseConnection?

    /// Available tables in the current database
    var tables: [TableInfo] = []

    /// Column info by table name (for schema context)
    var columnsByTable: [String: [ColumnInfo]] = [:]

    /// Foreign keys by table name
    var foreignKeysByTable: [String: [ForeignKeyInfo]] = [:]

    /// Schema provider for reusing cached column data (set by parent coordinator)
    var schemaProvider: SQLSchemaProvider?

    /// Current query text from the active editor tab
    var currentQuery: String?

    /// Query results summary from the active tab
    var queryResults: String?

    // MARK: - AI Action Dispatch

    private var queryLanguage: String {
        guard let type = connection?.type else { return "sql" }
        return PluginManager.shared.editorLanguage(for: type).codeBlockTag
    }

    private var queryTypeName: String {
        guard let type = connection?.type else { return "SQL query" }
        return "\(PluginManager.shared.queryLanguageName(for: type)) query"
    }

    func handleFixError(query: String, error: String) {
        startNewConversation()
        let prompt = "Fix this \(queryTypeName) error:\n\nQuery:\n```\(queryLanguage)\n\(query)\n```\n\nError: \(error)"
        sendWithContext(prompt: prompt, feature: .fixError)
    }

    func handleExplainSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let prompt = "Explain this \(queryTypeName):\n```\(queryLanguage)\n\(selectedText)\n```"
        sendWithContext(prompt: prompt, feature: .explainQuery)
    }

    func handleOptimizeSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let prompt = "Optimize this \(queryTypeName):\n```\(queryLanguage)\n\(selectedText)\n```"
        sendWithContext(prompt: prompt, feature: .optimizeQuery)
    }

    // MARK: - Constants

    /// Maximum number of messages to keep in memory to prevent unbounded growth
    private static let maxMessageCount = 200

    // MARK: - Private

    /// nonisolated(unsafe) is required because deinit is not @MainActor-isolated,
    /// so accessing a @MainActor property from deinit requires opting out of isolation.
    @ObservationIgnored nonisolated(unsafe) private var streamingTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    private var lastUsedFeature: AIFeature = .chat
    private let chatStorage = AIChatStorage.shared
    private var sessionApprovedConnections: Set<UUID> = []
    private var pendingFeature: AIFeature?

    // MARK: - Init

    init() {
        loadConversations()
    }

    deinit {
        streamingTask?.cancel()
    }

    // MARK: - Actions

    /// Send the current input text as a user message
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMessage = AIChatMessage(role: .user, content: text)
        messages.append(userMessage)
        trimMessagesIfNeeded()
        inputText = ""
        errorMessage = nil

        startStreaming(feature: .chat)
    }

    /// Send a pre-filled prompt for a specific AI feature
    func sendWithContext(prompt: String, feature: AIFeature) {
        let userMessage = AIChatMessage(role: .user, content: prompt)
        messages.append(userMessage)
        trimMessagesIfNeeded()
        errorMessage = nil

        startStreaming(feature: feature)
    }

    /// Cancel the current streaming response
    func cancelStream() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false

        // Remove empty assistant placeholder left by cancelled stream
        if let last = messages.last, last.role == .assistant, last.content.isEmpty {
            messages.removeLast()
        }
        streamingAssistantID = nil
        persistCurrentConversation()
    }

    /// Clear all recent conversations
    func clearConversation() {
        cancelStream()
        chatStorage.deleteAll()
        conversations.removeAll()
        messages.removeAll()
        activeConversationID = nil
        errorMessage = nil
    }

    /// Retry the last failed message
    func retry() {
        guard lastMessageFailed else { return }

        // Remove failed assistant message if present
        if let lastMessage = messages.last, lastMessage.role == .assistant {
            messages.removeLast()
        }

        // Verify the last message is a user message before retrying
        guard messages.last?.role == .user else { return }

        lastMessageFailed = false
        errorMessage = nil
        startStreaming(feature: lastUsedFeature)
    }

    /// Regenerate the last assistant response
    func regenerate() {
        guard !isStreaming,
              let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant })
        else { return }

        messages.remove(at: lastAssistantIndex)
        errorMessage = nil
        startStreaming(feature: lastUsedFeature)
    }

    /// User confirmed AI access for the current connection
    func confirmAIAccess() {
        if let connectionID = connection?.id {
            sessionApprovedConnections.insert(connectionID)
        }
        if let feature = pendingFeature {
            pendingFeature = nil
            startStreaming(feature: feature)
        }
    }

    /// User denied AI access for the current connection
    func denyAIAccess() {
        pendingFeature = nil
        // Remove the last user message since we can't process it
        if let last = messages.last, last.role == .user {
            messages.removeLast()
        }
    }

    // MARK: - Conversation Management

    /// Load saved conversations from disk
    func loadConversations() {
        conversations = chatStorage.loadAll()
        // Restore most recent conversation if available
        if let mostRecent = conversations.first {
            activeConversationID = mostRecent.id
            messages = mostRecent.messages
        }
    }

    /// Start a new conversation
    func startNewConversation() {
        cancelStream()
        persistCurrentConversation()
        messages.removeAll()
        activeConversationID = nil
        errorMessage = nil
    }

    /// Switch to an existing conversation
    func switchConversation(to id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        cancelStream()
        persistCurrentConversation()
        messages = conversation.messages
        activeConversationID = conversation.id
        errorMessage = nil
    }

    /// Release all session-specific data to free memory on disconnect.
    /// Unlike `clearConversation()`, this does not delete persisted history.
    func clearSessionData() {
        streamingTask?.cancel()
        streamingTask = nil
        schemaProvider = nil
        connection = nil
        tables = []
        columnsByTable = [:]
        foreignKeysByTable = [:]
        currentQuery = nil
        queryResults = nil
        messages = []
        errorMessage = nil
        lastMessageFailed = false
        activeConversationID = nil
        sessionApprovedConnections = []
        isStreaming = false
        streamingAssistantID = nil
        pendingFeature = nil
    }

    /// Delete a conversation
    func deleteConversation(_ id: UUID) {
        chatStorage.delete(id)
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = nil
            messages.removeAll()
        }
    }

    /// Persist the current conversation to disk
    func persistCurrentConversation() {
        guard !messages.isEmpty else { return }

        if let existingID = activeConversationID,
           var conversation = conversations.first(where: { $0.id == existingID }) {
            // Update existing conversation
            conversation.messages = messages
            conversation.updatedAt = Date()
            conversation.updateTitle()
            conversation.connectionName = connection?.name
            chatStorage.save(conversation)

            if let index = conversations.firstIndex(where: { $0.id == existingID }) {
                conversations[index] = conversation
            }
        } else {
            // Create new conversation
            var conversation = AIConversation(
                messages: messages,
                connectionName: connection?.name
            )
            conversation.updateTitle()
            chatStorage.save(conversation)
            activeConversationID = conversation.id
            conversations.insert(conversation, at: 0)
        }
    }

    // MARK: - Private Methods

    /// Trims the messages array to stay within `maxMessageCount`, removing oldest messages first.
    private func trimMessagesIfNeeded() {
        if messages.count > Self.maxMessageCount {
            messages.removeFirst(messages.count - Self.maxMessageCount)
        }
    }

    private func startStreaming(feature: AIFeature) {
        lastUsedFeature = feature
        lastMessageFailed = false

        let settings = AppSettingsManager.shared.ai

        // Resolve provider from feature routing or use first enabled provider
        guard let (config, apiKey) = AIProviderFactory.resolveProvider(for: feature, settings: settings) else {
            errorMessage = String(localized: "No AI provider configured. Go to Settings > AI to add one.")
            return
        }

        // Check connection policy
        if connection != nil {
            if let policy = resolveConnectionPolicy(settings: settings) {
                if policy == .never {
                    errorMessage = String(localized: "AI is disabled for this connection.")
                    if let last = messages.last, last.role == .user {
                        messages.removeLast()
                    }
                    return
                }
                if policy == .askEachTime {
                    pendingFeature = feature
                    showAIAccessConfirmation = true
                    return
                }
            }
        }

        let provider = AIProviderFactory.createProvider(for: config, apiKey: apiKey)
        let model = AIProviderFactory.resolveModel(for: feature, config: config, settings: settings)
        let systemPrompt = buildSystemPrompt(settings: settings)

        // Create assistant message placeholder
        let assistantMessage = AIChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        trimMessagesIfNeeded()
        let assistantID = assistantMessage.id
        streamingAssistantID = assistantID

        isStreaming = true

        streamingTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Exclude the empty assistant placeholder from sent messages
                let chatMessages = Array(self.messages.dropLast())
                let stream = provider.streamChat(
                    messages: chatMessages,
                    model: model,
                    systemPrompt: systemPrompt
                )

                for try await event in stream {
                    guard !Task.isCancelled,
                          let idx = self.messages.firstIndex(where: { $0.id == assistantID })
                    else { break }
                    switch event {
                    case .text(let token):
                        self.messages[idx].content += token
                    case .usage(let usage):
                        self.messages[idx].usage = usage
                    }
                }

                self.isStreaming = false
                self.streamingTask = nil
                self.streamingAssistantID = nil
                self.persistCurrentConversation()
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("Streaming failed: \(error.localizedDescription)")
                    self.lastMessageFailed = true
                    self.errorMessage = error.localizedDescription

                    // Remove empty assistant message on error
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }),
                       self.messages[idx].content.isEmpty {
                        self.messages.remove(at: idx)
                    }
                }
                self.isStreaming = false
                self.streamingTask = nil
                self.streamingAssistantID = nil
            }
        }
    }

    private func resolveConnectionPolicy(settings: AISettings) -> AIConnectionPolicy? {
        let policy = connection?.aiPolicy ?? settings.defaultConnectionPolicy

        if policy == .askEachTime {
            // If already approved this session, treat as always allow
            if let connectionID = connection?.id, sessionApprovedConnections.contains(connectionID) {
                return .alwaysAllow
            }
            return .askEachTime
        }

        return policy
    }

    private func buildSystemPrompt(settings: AISettings) -> String? {
        guard let connection else { return nil }

        let idQuote = PluginManager.shared.sqlDialect(for: connection.type)?.identifierQuote ?? "\""
        return AISchemaContext.buildSystemPrompt(
            databaseType: connection.type,
            databaseName: connection.database,
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            currentQuery: settings.includeCurrentQuery ? currentQuery : nil,
            queryResults: settings.includeQueryResults ? queryResults : nil,
            settings: settings,
            identifierQuote: idQuote
        )
    }
}
