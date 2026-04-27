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

    func handleFixError(query: String, error: String) {
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.fixError(query: query, error: error, databaseType: databaseType)
        sendWithContext(prompt: prompt)
    }

    func handleExplainSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.explainQuery(selectedText, databaseType: databaseType)
        sendWithContext(prompt: prompt)
    }

    func handleOptimizeSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.optimizeQuery(selectedText, databaseType: databaseType)
        sendWithContext(prompt: prompt)
    }

    func editMessage(_ message: AIChatMessage) {
        guard message.role == .user, !isStreaming else { return }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }

        inputText = message.content
        messages.removeSubrange(idx...)
        persistCurrentConversation()
    }

    // MARK: - Constants

    /// Maximum number of messages to keep in memory to prevent unbounded growth
    private static let maxMessageCount = 200

    // MARK: - Private

    /// nonisolated(unsafe) is required because deinit is not @MainActor-isolated,
    /// so accessing a @MainActor property from deinit requires opting out of isolation.
    @ObservationIgnored nonisolated(unsafe) private var streamingTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var schemaFetchTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    private let chatStorage = AIChatStorage.shared
    private var sessionApprovedConnections: Set<UUID> = []
    private var pendingApproval: Bool = false

    // MARK: - Init

    init() {
        loadConversations()
    }

    deinit {
        streamingTask?.cancel()
        schemaFetchTask?.cancel()
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

        startStreaming()
    }

    /// Send a pre-filled prompt
    func sendWithContext(prompt: String) {
        let userMessage = AIChatMessage(role: .user, content: prompt)
        messages.append(userMessage)
        trimMessagesIfNeeded()
        errorMessage = nil

        startStreaming()
    }

    /// Cancel the current streaming response
    func cancelStream() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false

        // Remove empty assistant placeholder left by cancelled stream
        if let assistantID = streamingAssistantID,
           let idx = messages.firstIndex(where: { $0.id == assistantID }),
           messages[idx].content.isEmpty {
            messages.remove(at: idx)
        }
        streamingAssistantID = nil
        persistCurrentConversation()
    }

    /// Clear all recent conversations
    func clearConversation() {
        cancelStream()
        AIProviderFactory.resetCopilotConversation()
        Task { await chatStorage.deleteAll() }
        conversations.removeAll()
        messages.removeAll()
        activeConversationID = nil
        errorMessage = nil
    }

    /// Retry the last failed message
    func retry() {
        guard lastMessageFailed else { return }

        if let lastMessage = messages.last, lastMessage.role == .assistant {
            messages.removeLast()
        }

        guard messages.last?.role == .user else { return }

        lastMessageFailed = false
        errorMessage = nil
        startStreaming()
    }

    /// Regenerate the last assistant response
    func regenerate() {
        guard !isStreaming,
              let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant })
        else { return }

        AIProviderFactory.copilotDeleteLastTurn()
        messages.remove(at: lastAssistantIndex)
        errorMessage = nil
        startStreaming()
    }

    /// User confirmed AI access for the current connection
    func confirmAIAccess() {
        if let connectionID = connection?.id {
            sessionApprovedConnections.insert(connectionID)
        }
        guard pendingApproval else { return }
        pendingApproval = false
        startStreaming()
    }

    /// User denied AI access for the current connection
    func denyAIAccess() {
        pendingApproval = false
        if let last = messages.last, last.role == .user {
            messages.removeLast()
        }
    }

    // MARK: - Conversation Management

    /// Load saved conversations from disk
    func loadConversations() {
        let storage = chatStorage
        Task.detached(priority: .utility) { [weak self] in
            let loaded = await storage.loadAll()
            await MainActor.run {
                guard let self else { return }
                self.conversations = loaded
                if let mostRecent = loaded.first {
                    self.activeConversationID = mostRecent.id
                    self.messages = mostRecent.messages
                }
            }
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
        AIProviderFactory.resetCopilotConversation()
        cancelStream()
        persistCurrentConversation()
        messages = conversation.messages
        activeConversationID = conversation.id
        errorMessage = nil
    }

    /// Release all session-specific data to free memory on disconnect.
    /// Unlike `clearConversation()`, this does not delete persisted history.
    func clearSessionData() {
        AIProviderFactory.resetCopilotConversation()
        streamingTask?.cancel()
        streamingTask = nil
        schemaFetchTask?.cancel()
        schemaFetchTask = nil
        AIProviderFactory.invalidateCache()
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
        pendingApproval = false
    }

    /// Delete a conversation
    func deleteConversation(_ id: UUID) {
        if activeConversationID == id {
            AIProviderFactory.resetCopilotConversation()
        }
        Task { await chatStorage.delete(id) }
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
            Task { await chatStorage.save(conversation) }

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
            Task { await chatStorage.save(conversation) }
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
        // Ensure conversation starts with a user message (required by some providers)
        while messages.first?.role == .assistant {
            messages.removeFirst()
        }
    }

    private func startStreaming() {
        if streamingTask != nil {
            streamingTask?.cancel()
            streamingTask = nil
            if let id = streamingAssistantID,
               let idx = messages.firstIndex(where: { $0.id == id }),
               messages[idx].content.isEmpty {
                messages.remove(at: idx)
            }
            streamingAssistantID = nil
            isStreaming = false
        }

        lastMessageFailed = false

        let settings = AppSettingsManager.shared.ai

        guard let resolved = AIProviderFactory.resolve(settings: settings) else {
            errorMessage = String(localized: "No AI provider configured. Go to Settings > AI to add one.")
            return
        }

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
                    pendingApproval = true
                    showAIAccessConfirmation = true
                    return
                }
            }
        }

        let promptContext = capturePromptContext(settings: settings)

        // Create assistant message placeholder
        let assistantMessage = AIChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        trimMessagesIfNeeded()
        let assistantID = assistantMessage.id
        streamingAssistantID = assistantID

        isStreaming = true

        // Capture value types on main actor before detaching
        let chatMessages = Array(messages.dropLast())

        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Build system prompt off the main actor
                let systemPrompt: String? = promptContext.map {
                    AISchemaContext.buildSystemPrompt(
                        databaseType: $0.databaseType,
                        databaseName: $0.databaseName,
                        tables: $0.tables,
                        columnsByTable: $0.columnsByTable,
                        foreignKeys: $0.foreignKeys,
                        currentQuery: $0.currentQuery,
                        queryResults: $0.queryResults,
                        settings: $0.settings,
                        identifierQuote: $0.identifierQuote,
                        editorLanguage: $0.editorLanguage,
                        queryLanguageName: $0.queryLanguageName
                    )
                }

                // Pre-send size check
                let totalSize = ((systemPrompt ?? "") as NSString).length
                    + chatMessages.reduce(0) { $0 + ($1.content as NSString).length }
                if totalSize > 100_000 {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.errorMessage = String(
                            localized: "Message too large. Try disabling 'Include schema' or 'Include query results' in AI settings."
                        )
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                            self.messages.remove(at: idx)
                        }
                        self.isStreaming = false
                        self.streamingAssistantID = nil
                    }
                    return
                }

                let stream = resolved.provider.streamChat(
                    messages: chatMessages,
                    model: resolved.model,
                    systemPrompt: systemPrompt
                )

                // Batch tokens off the main actor, flush on interval
                var pendingContent = ""
                var pendingUsage: AITokenUsage?
                let flushInterval: ContinuousClock.Duration = .milliseconds(150)
                var lastFlushTime: ContinuousClock.Instant = .now

                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .text(let token):
                        pendingContent += token
                    case .usage(let usage):
                        pendingUsage = usage
                    }

                    if ContinuousClock.now - lastFlushTime >= flushInterval {
                        let content = pendingContent
                        let usage = pendingUsage
                        pendingContent = ""
                        pendingUsage = nil
                        await MainActor.run { [weak self] in
                            guard let self,
                                  let idx = self.messages.firstIndex(where: { $0.id == assistantID })
                            else { return }
                            if !content.isEmpty {
                                self.messages[idx].content += content
                            }
                            if let usage {
                                self.messages[idx].usage = usage
                            }
                        }
                        lastFlushTime = .now
                    }
                }

                // Final flush — deliver remaining buffered tokens
                if !Task.isCancelled, !pendingContent.isEmpty || pendingUsage != nil {
                    let content = pendingContent
                    let usage = pendingUsage
                    await MainActor.run { [weak self] in
                        guard let self,
                              let idx = self.messages.firstIndex(where: { $0.id == assistantID })
                        else { return }
                        if !content.isEmpty {
                            self.messages[idx].content += content
                        }
                        if let usage {
                            self.messages[idx].usage = usage
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isStreaming = false
                    self.streamingTask = nil
                    self.streamingAssistantID = nil
                    self.persistCurrentConversation()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
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

    private struct PromptContext: Sendable {
        let databaseType: DatabaseType
        let databaseName: String
        let tables: [TableInfo]
        let columnsByTable: [String: [ColumnInfo]]
        let foreignKeys: [String: [ForeignKeyInfo]]
        let currentQuery: String?
        let queryResults: String?
        let settings: AISettings
        let identifierQuote: String
        let editorLanguage: EditorLanguage
        let queryLanguageName: String
    }

    private func capturePromptContext(settings: AISettings) -> PromptContext? {
        guard let connection else { return nil }
        return PromptContext(
            databaseType: connection.type,
            databaseName: connection.database,
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            currentQuery: settings.includeCurrentQuery ? currentQuery : nil,
            queryResults: settings.includeQueryResults ? queryResults : nil,
            settings: settings,
            identifierQuote: PluginManager.shared.sqlDialect(for: connection.type)?.identifierQuote ?? "\"",
            editorLanguage: PluginManager.shared.editorLanguage(for: connection.type),
            queryLanguageName: PluginManager.shared.queryLanguageName(for: connection.type)
        )
    }

    // MARK: - Schema Context

    func fetchSchemaContext() {
        let settings = AppSettingsManager.shared.ai
        guard settings.includeSchema,
              let connection,
              let driver = DatabaseManager.shared.driver(for: connection.id)
        else { return }

        schemaFetchTask?.cancel()

        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        let capturedProvider = schemaProvider

        schemaFetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var columns: [String: [ColumnInfo]] = [:]
            var foreignKeys: [String: [ForeignKeyInfo]] = [:]

            let fetchColumns: @Sendable (TableInfo) async -> (String, [ColumnInfo]) = { table in
                if let provider = capturedProvider {
                    let cached = await provider.getColumns(for: table.name)
                    if !cached.isEmpty {
                        return (table.name, cached)
                    }
                }
                do {
                    let cols = try await driver.fetchColumns(table: table.name)
                    return (table.name, cols)
                } catch {
                    return (table.name, [])
                }
            }

            let concurrencyLimit = 4
            await withTaskGroup(of: (String, [ColumnInfo]).self) { group in
                var pending = tablesToFetch.makeIterator()

                // Seed initial batch
                for _ in 0..<concurrencyLimit {
                    guard let table = pending.next() else { break }
                    group.addTask { await fetchColumns(table) }
                }

                // Drip-feed remaining tables as each completes
                for await (tableName, cols) in group {
                    if !cols.isEmpty {
                        columns[tableName] = cols
                    }
                    if let next = pending.next() {
                        group.addTask { await fetchColumns(next) }
                    }
                }
            }

            do {
                let fkResult = try await driver.fetchForeignKeys(forTables: tablesToFetch.map(\.name))
                for (table, fks) in fkResult {
                    foreignKeys[table] = fks
                }
            } catch {
                // Foreign key fetch is best-effort for AI context
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.columnsByTable = columns
                self.foreignKeysByTable = foreignKeys
            }
        }
    }
}
