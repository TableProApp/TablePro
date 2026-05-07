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

    var messages: [ChatTurn] = []
    var inputText: String = ""
    var isStreaming: Bool = false
    var errorMessage: String? {
        didSet {
            if errorMessage == nil {
                lastError = nil
            }
        }
    }
    var lastError: AIProviderError?
    var lastMessageFailed: Bool = false

    var canRetryLastFailure: Bool {
        lastError?.isRetryable ?? true
    }
    var conversations: [AIConversation] = []
    var activeConversationID: UUID?
    var showAIAccessConfirmation = false
    var selectedProviderId: UUID?
    var selectedModel: String?
    var availableModels: [UUID: [String]] = [:]
    var attachedContext: [ContextItem] = []

    // MARK: - Context Properties

    /// Current database connection (set by parent view)
    var connection: DatabaseConnection?

    /// Tables for the current connection. Always derived live from `SchemaService`,
    /// so reads stay in sync with schema reloads without any push-from-upstream plumbing.
    var tables: [TableInfo] {
        guard let id = connection?.id else { return [] }
        return SchemaService.shared.tables(for: id)
    }

    /// Column info cache populated on-demand when chips are attached or
    /// schema is auto-included. Keyed by table name within the active connection.
    var columnsByTable: [String: [ColumnInfo]] = [:]

    /// Foreign keys cache populated alongside columns.
    var foreignKeysByTable: [String: [ForeignKeyInfo]] = [:]

    @ObservationIgnored private var inFlightColumnFetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlightSchemaLoad: Task<Void, Never>?

    /// Current query text from the active editor tab
    var currentQuery: String?

    /// Query results summary from the active tab
    var queryResults: String?

    // MARK: - AI Action Dispatch

    func loadAvailableModels() async {
        let settings = AppSettingsManager.shared.ai
        let pending = settings.providers.filter { availableModels[$0.id] == nil }
        guard !pending.isEmpty else { return }

        let results = await withTaskGroup(of: (UUID, [String]?).self) { group in
            for config in pending {
                let apiKey: String?
                switch config.type.authStyle {
                case .apiKey:
                    apiKey = AIKeyStorage.shared.loadAPIKey(for: config.id)
                case .oauth, .none:
                    apiKey = nil
                }
                group.addTask {
                    let transport = await AIProviderFactory.createProvider(for: config, apiKey: apiKey)
                    do {
                        let models = try await transport.fetchAvailableModels()
                        return (config.id, models)
                    } catch is CancellationError {
                        return (config.id, nil)
                    } catch {
                        return (config.id, [])
                    }
                }
            }

            var collected: [(UUID, [String]?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        guard !Task.isCancelled else { return }

        for (id, models) in results {
            guard let models else { continue }
            if models.isEmpty {
                let fallback = pending.first(where: { $0.id == id })?.model
                availableModels[id] = (fallback?.isEmpty == false) ? [fallback ?? ""] : []
            } else {
                availableModels[id] = models
            }
        }
    }

    func runSlashCommand(_ command: SlashCommand, body: String = "") {
        inputText = ""
        errorMessage = nil

        let invocationText = body.isEmpty ? "/\(command.name)" : "/\(command.name) \(body)"
        let databaseType = connection?.type ?? .mysql

        switch command {
        case .help:
            let helpMarkdown = Self.helpMarkdown
            if let last = messages.last, last.role == .assistant, last.plainText == helpMarkdown {
                return
            }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            messages.append(ChatTurn(role: .assistant, blocks: [.text(helpMarkdown)]))
        case .explain:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            sendWithContext(prompt: AIPromptTemplates.explainQuery(query, databaseType: databaseType))
        case .optimize:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            sendWithContext(prompt: AIPromptTemplates.optimizeQuery(query, databaseType: databaseType))
        case .fix:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            let lastError = queryResults ?? ""
            sendWithContext(prompt: AIPromptTemplates.fixError(query: query, error: lastError, databaseType: databaseType))
        }
    }

    func runCustomSlashCommand(_ command: CustomSlashCommand, body: String = "") async {
        guard command.isValid else {
            Self.logger.warning("runCustomSlashCommand called with invalid command: name=\(command.name, privacy: .public)")
            return
        }
        inputText = ""
        errorMessage = nil
        let invocationText = body.isEmpty ? "/\(command.name)" : "/\(command.name) \(body)"
        let needsSchema = command.promptTemplate.contains(CustomSlashCommandVariable.schema.placeholder)
        if needsSchema {
            await ensureSchemaLoaded()
        }
        let renderingContext = CustomSlashCommandRenderer.Context(
            query: currentQuery,
            schema: needsSchema ? renderedSchemaSection() : nil,
            database: connection.flatMap { DatabaseManager.shared.activeDatabaseName(for: $0) },
            body: body
        )
        let prompt = CustomSlashCommandRenderer.render(command, context: renderingContext)
        messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
        sendWithContext(prompt: prompt)
    }

    private func renderedSchemaSection() -> String? {
        guard !tables.isEmpty else { return nil }
        let settings = AppSettingsManager.shared.ai
        let identifierQuote = connection.flatMap {
            PluginManager.shared.sqlDialect(for: $0.type)?.identifierQuote
        } ?? "\""
        let section = AISchemaContext.buildSchemaSection(
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            maxTables: settings.maxSchemaTables,
            identifierQuote: identifierQuote
        )
        return section.isEmpty ? nil : section
    }

    private func resolveQuery(body: String, command: SlashCommand) -> String? {
        if !body.isEmpty {
            return body
        }
        if let editorQuery = currentQuery, !editorQuery.isEmpty {
            return editorQuery
        }
        errorMessage = String(
            format: String(localized: "/%@ needs a query: type one in the editor or after the command."),
            command.name
        )
        return nil
    }

    private static let helpMarkdown: String = {
        let lines = SlashCommand.allCommands
            .map { "- `/\($0.name)` · \($0.description)" }
            .joined(separator: "\n")
        return String(localized: "**Available commands:**") + "\n\n" + lines
    }()

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

    func editMessage(_ message: ChatTurn) {
        guard message.role == .user, !isStreaming else { return }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }

        inputText = message.plainText
        attachedContext = message.blocks.compactMap { block in
            if case .attachment(let item) = block { return item }
            return nil
        }
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
    @ObservationIgnored private var prepTask: Task<Void, Never>?
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
    }

    // MARK: - Actions

    /// Send the current input text as a user message
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let parsed = SlashCommand.parse(text) {
            runSlashCommand(parsed.command, body: parsed.body)
            return
        }

        var blocks: [ChatContentBlock] = [.text(text)]
        blocks.append(contentsOf: attachedContext.map { .attachment($0) })

        messages.append(ChatTurn(role: .user, blocks: blocks))
        trimMessagesIfNeeded()
        inputText = ""
        attachedContext = []
        errorMessage = nil

        startStreaming()
    }

    func attach(_ item: ContextItem) {
        guard !attachedContext.contains(where: { $0.stableKey == item.stableKey }) else { return }
        attachedContext.append(item)
        Task { await primeAttachmentData(for: item) }
    }

    private func primeAttachmentData(for item: ContextItem) async {
        switch item {
        case .schema:
            await ensureSchemaLoaded()
        case .table(_, let name):
            await ensureColumnsLoaded(forTable: name)
        case .savedQuery(let id, _):
            await ensureSavedQueryLoaded(id: id)
        case .currentQuery, .queryResult, .file:
            break
        }
    }

    /// Loaded `SQLFavorite` instances keyed by id, populated when saved-query
    /// chips are attached so `resolveSavedQueryAttachment` can serialize them.
    @ObservationIgnored private var cachedSavedQueries: [UUID: SQLFavorite] = [:]

    /// Saved queries available as `@`-mention candidates for the active connection.
    /// Refreshed on connection change via `loadSavedQueries()`.
    var savedQueries: [SQLFavorite] = []

    func loadSavedQueries() async {
        guard let connectionId = connection?.id else {
            savedQueries = []
            return
        }
        let favorites = await SQLFavoriteManager.shared.fetchFavorites(connectionId: connectionId)
        savedQueries = favorites
        for favorite in favorites {
            cachedSavedQueries[favorite.id] = favorite
        }
    }

    private func ensureSavedQueryLoaded(id: UUID) async {
        if cachedSavedQueries[id] != nil { return }
        if let favorite = await SQLFavoriteManager.shared.fetchFavorite(id: id) {
            cachedSavedQueries[id] = favorite
        }
    }

    /// Ensure column + foreign-key data for `tableName` is in `columnsByTable`.
    /// Idempotent and dedups concurrent calls so chip attach + send-time resolve
    /// share a single fetch.
    func ensureColumnsLoaded(forTable tableName: String) async {
        if let existing = columnsByTable[tableName], !existing.isEmpty { return }
        if let inFlight = inFlightColumnFetches[tableName] {
            await inFlight.value
            return
        }
        guard let connection,
              let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
        let task: Task<Void, Never> = Task { [weak self] in
            let columns: [ColumnInfo]
            do {
                columns = try await driver.fetchColumns(table: tableName)
            } catch {
                Self.logger.warning("Column fetch failed for \(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                columns = []
            }
            let fkMap: [String: [ForeignKeyInfo]]
            do {
                fkMap = try await driver.fetchForeignKeys(forTables: [tableName])
            } catch {
                Self.logger.warning("Foreign key fetch failed for \(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                fkMap = [:]
            }
            guard !Task.isCancelled, let self else { return }
            self.columnsByTable[tableName] = columns
            if let fks = fkMap[tableName] {
                self.foreignKeysByTable[tableName] = fks
            }
            self.inFlightColumnFetches[tableName] = nil
        }
        inFlightColumnFetches[tableName] = task
        await task.value
    }

    /// Ensure column data is loaded for all tables in the live schema (capped by
    /// `maxSchemaTables`). Used by `@Schema` chip resolution and the
    /// auto-include-schema system-prompt path.
    func ensureSchemaLoaded() async {
        if let inFlight = inFlightSchemaLoad {
            await inFlight.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runSchemaLoad()
        }
        inFlightSchemaLoad = task
        await task.value
        inFlightSchemaLoad = nil
    }

    private func runSchemaLoad() async {
        guard let connection,
              let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
        let settings = AppSettingsManager.shared.ai
        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        guard !tablesToFetch.isEmpty else { return }

        await withTaskGroup(of: (String, [ColumnInfo]).self) { group in
            for table in tablesToFetch where (columnsByTable[table.name] ?? []).isEmpty {
                let name = table.name
                group.addTask {
                    do {
                        let cols = try await driver.fetchColumns(table: name)
                        return (name, cols)
                    } catch {
                        Self.logger.warning("Schema column fetch failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return (name, [])
                    }
                }
            }
            for await (name, cols) in group {
                columnsByTable[name] = cols
            }
        }

        guard !Task.isCancelled else { return }

        let needsFKFetch = tablesToFetch.contains { foreignKeysByTable[$0.name] == nil }
        guard needsFKFetch else { return }
        do {
            let fkMap = try await driver.fetchForeignKeys(forTables: tablesToFetch.map(\.name))
            for (name, fks) in fkMap {
                foreignKeysByTable[name] = fks
            }
        } catch {
            Self.logger.warning("Foreign key bulk fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func detach(_ item: ContextItem) {
        attachedContext.removeAll { $0.stableKey == item.stableKey }
    }

    /// Produce a wire-ready copy of a turn with `.attachment` blocks expanded
    /// into appended text. Awaits any uncached column/foreign-key data so the
    /// AI receives real schema instead of a "(columns not loaded)" placeholder.
    /// The stored `messages` array keeps the raw form so `editMessage` can
    /// recover the typed text and attachments cleanly.
    func resolveTurnForWire(_ turn: ChatTurn) async -> ChatTurn {
        let attachments = turn.blocks.compactMap { block -> ContextItem? in
            if case .attachment(let item) = block { return item }
            return nil
        }
        guard !attachments.isEmpty else { return turn }

        for item in attachments {
            await primeAttachmentData(for: item)
        }

        let typed = turn.blocks.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined()

        let resolved = attachments
            .compactMap { resolveAttachment($0) }
            .joined(separator: "\n\n")
        if resolved.isEmpty { return turn }

        let combined = typed.isEmpty ? resolved : typed + "\n\n---\n\n" + resolved
        return ChatTurn(
            id: turn.id,
            role: turn.role,
            blocks: [.text(combined)],
            timestamp: turn.timestamp,
            usage: turn.usage,
            modelId: turn.modelId,
            providerId: turn.providerId
        )
    }

    private func resolveAttachment(_ item: ContextItem) -> String? {
        switch item {
        case .schema:
            return resolveSchemaAttachment()
        case .table(_, let name):
            return resolveTableAttachment(name: name)
        case .currentQuery(let text):
            let snapshot = text.isEmpty ? (currentQuery ?? "") : text
            guard !snapshot.isEmpty else { return nil }
            return "## Current Query\n```\n\(snapshot)\n```"
        case .queryResult(let summary):
            let snapshot = summary.isEmpty ? (queryResults ?? "") : summary
            guard !snapshot.isEmpty else { return nil }
            return "## Query Results\n\(snapshot)"
        case .savedQuery(let id, let name):
            return resolveSavedQueryAttachment(id: id, fallbackName: name)
        case .file:
            return nil
        }
    }

    private func resolveSavedQueryAttachment(id: UUID, fallbackName: String) -> String? {
        guard let favorite = cachedSavedQueries[id] else { return nil }
        let displayName = favorite.name.isEmpty ? fallbackName : favorite.name
        let header = displayName.isEmpty
            ? String(localized: "Saved Query")
            : "\(String(localized: "Saved Query")): \(displayName)"
        return "## \(header)\n```sql\n\(favorite.query)\n```"
    }

    private func resolveSchemaAttachment() -> String? {
        guard !tables.isEmpty else { return nil }
        let settings = AppSettingsManager.shared.ai
        let identifierQuote = connection.flatMap {
            PluginManager.shared.sqlDialect(for: $0.type)?.identifierQuote
        } ?? "\""
        let section = AISchemaContext.buildSchemaSection(
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            maxTables: settings.maxSchemaTables,
            identifierQuote: identifierQuote
        )
        guard !section.isEmpty else { return nil }
        return "## Schema\n\(section)"
    }

    private func resolveTableAttachment(name: String) -> String? {
        let columns = columnsByTable[name] ?? []
        guard !columns.isEmpty else { return nil }
        let foreignKeys = foreignKeysByTable[name] ?? []
        var lines: [String] = ["## Table \(name)"]
        for column in columns {
            lines.append("- \(column.name): \(column.dataType)")
        }
        if !foreignKeys.isEmpty {
            lines.append("Foreign keys:")
            for foreign in foreignKeys {
                lines.append("- \(foreign.column) -> \(foreign.referencedTable).\(foreign.referencedColumn)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Send a pre-filled prompt
    func sendWithContext(prompt: String) {
        let userMessage = ChatTurn(role: .user, blocks: [.text(prompt)])
        messages.append(userMessage)
        trimMessagesIfNeeded()
        errorMessage = nil

        startStreaming()
    }

    /// Cancel the current streaming response
    func cancelStream() {
        prepTask?.cancel()
        prepTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        ToolApprovalCenter.shared.cancelAll()
        isStreaming = false

        // Remove empty assistant placeholder left by cancelled stream
        if let assistantID = streamingAssistantID,
           let idx = messages.firstIndex(where: { $0.id == assistantID }),
           messages[idx].plainText.isEmpty {
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
        prepTask?.cancel()
        prepTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        AIProviderFactory.invalidateCache()
        connection = nil
        columnsByTable = [:]
        foreignKeysByTable = [:]
        inFlightColumnFetches.values.forEach { $0.cancel() }
        inFlightColumnFetches.removeAll()
        inFlightSchemaLoad?.cancel()
        inFlightSchemaLoad = nil
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
        prepTask?.cancel()
        prepTask = nil
        if streamingTask != nil {
            streamingTask?.cancel()
            streamingTask = nil
            if let id = streamingAssistantID,
               let idx = messages.firstIndex(where: { $0.id == id }),
               messages[idx].plainText.isEmpty {
                messages.remove(at: idx)
            }
            streamingAssistantID = nil
            isStreaming = false
        }

        lastMessageFailed = false

        let settings = AppSettingsManager.shared.ai

        let resolved = AIProviderFactory.resolve(settings: settings, overrideProviderId: selectedProviderId, overrideModel: selectedModel)
        guard let resolved else {
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

        let assistantMessage = ChatTurn(role: .assistant, blocks: [], modelId: resolved.model, providerId: resolved.config.id.uuidString)
        messages.append(assistantMessage)
        trimMessagesIfNeeded()
        let assistantID = assistantMessage.id
        streamingAssistantID = assistantID

        isStreaming = true

        prepTask?.cancel()
        prepTask = Task { [weak self] in
            guard let self else { return }
            if settings.includeSchema {
                await self.ensureSchemaLoaded()
            }
            guard !Task.isCancelled else { return }
            let promptContext = self.capturePromptContext(settings: settings)
            var chatMessages: [ChatTurn] = []
            for turn in self.messages.dropLast() {
                chatMessages.append(await self.resolveTurnForWire(turn))
            }
            guard !Task.isCancelled else { return }
            self.runStream(
                chatMessages: chatMessages,
                promptContext: promptContext,
                resolved: resolved,
                assistantID: assistantID,
                settings: settings
            )
            self.prepTask = nil
        }
    }

    private static let maxToolRoundtrips = 10

    private func runStream(
        chatMessages: [ChatTurn],
        promptContext: PromptContext?,
        resolved: AIProviderFactory.ResolvedProvider,
        assistantID: UUID,
        settings: AISettings
    ) {
        let chatMode = settings.chatMode
        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let systemPrompt = Self.buildSystemPrompt(promptContext, mode: chatMode)
                guard let self else { return }
                let preflightOK = await self.preflightCheck(
                    systemPrompt: systemPrompt,
                    turns: chatMessages,
                    assistantID: assistantID
                )
                guard preflightOK else { return }

                let toolSpecs = await MainActor.run { ChatToolRegistry.shared.allSpecs(for: chatMode) }
                var workingTurns = chatMessages
                var currentAssistantID = assistantID
                let flushInterval: ContinuousClock.Duration = .milliseconds(150)

                for roundtrip in 0..<Self.maxToolRoundtrips {
                    let stream = resolved.provider.streamChat(
                        turns: workingTurns,
                        options: ChatTransportOptions(
                            model: resolved.model,
                            systemPrompt: systemPrompt,
                            tools: toolSpecs
                        )
                    )

                    // Batch tokens, accumulate tool-use events
                    var pendingContent = ""
                    var pendingUsage: AITokenUsage?
                    var toolUseOrder: [String] = []
                    var toolUseNames: [String: String] = [:]
                    var toolUseInputs: [String: String] = [:]
                    var lastFlushTime: ContinuousClock.Instant = .now
                    let assistantIDForRound = currentAssistantID

                    for try await event in stream {
                        guard !Task.isCancelled else { break }
                        switch event {
                        case .textDelta(let token):
                            pendingContent += token
                        case .usage(let usage):
                            pendingUsage = usage
                        case .toolUseStart(let id, let name):
                            if toolUseInputs[id] == nil {
                                toolUseOrder.append(id)
                                toolUseInputs[id] = ""
                            }
                            toolUseNames[id] = name
                        case .toolUseDelta(let id, let inputJSONDelta):
                            toolUseInputs[id, default: ""] += inputJSONDelta
                        case .toolUseEnd:
                            break
                        case .toolInvocationRequest(let block, let replyToken):
                            await self.dispatchCopilotInvocation(
                                block: block, replyToken: replyToken,
                                assistantID: assistantIDForRound, mode: chatMode
                            )
                        }

                        if ContinuousClock.now - lastFlushTime >= flushInterval {
                            await self.flushPending(
                                content: pendingContent,
                                usage: pendingUsage,
                                into: assistantIDForRound
                            )
                            pendingContent = ""
                            pendingUsage = nil
                            lastFlushTime = .now
                        }
                    }

                    if !Task.isCancelled, !pendingContent.isEmpty || pendingUsage != nil {
                        await self.flushPending(
                            content: pendingContent,
                            usage: pendingUsage,
                            into: assistantIDForRound
                        )
                    }

                    guard !Task.isCancelled else { return }

                    if toolUseOrder.isEmpty { break }


                    if roundtrip == Self.maxToolRoundtrips - 1 {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.errorMessage = String(
                                localized: "AI made too many tool calls in one response. Try simplifying the request."
                            )
                            if let idx = self.messages.firstIndex(where: { $0.id == currentAssistantID }),
                               self.messages[idx].plainText.isEmpty {
                                self.messages.remove(at: idx)
                            }
                            self.lastMessageFailed = true
                        }
                        break
                    }

                    let assembledBlocks = Self.assembleToolUseBlocks(
                        order: toolUseOrder,
                        names: toolUseNames,
                        inputs: toolUseInputs
                    )
                    let context = await MainActor.run {
                        ChatToolContext(
                            connectionId: self.connection?.id,
                            bridge: ChatToolBootstrap.bridge,
                            authPolicy: ChatToolBootstrap.authPolicy
                        )
                    }
                    let toolUseBlocks = await self.resolveAndAwaitApprovals(
                        assembledBlocks: assembledBlocks,
                        assistantID: assistantIDForRound
                    )
                    guard !Task.isCancelled else { return }

                    let approvedBlocks = toolUseBlocks.filter {
                        if case .approved = $0.approvalState { return true }
                        return false
                    }
                    let executedResults = await Self.executeToolUses(
                        approvedBlocks, mode: chatMode, context: context
                    )
                    guard !Task.isCancelled else { return }

                    let toolResultBlocks = Self.synthesizeResults(
                        for: toolUseBlocks,
                        executed: executedResults
                    )

                    let continuation = await self.completeToolRoundtrip(
                        assistantIDForRound: assistantIDForRound,
                        toolUseBlocks: toolUseBlocks,
                        toolResultBlocks: toolResultBlocks,
                        resolved: resolved
                    )
                    currentAssistantID = continuation.nextAssistantID
                    workingTurns.append(continuation.assistantTurn)
                    workingTurns.append(continuation.userTurn)
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
                        self.lastError = error as? AIProviderError

                        // Remove empty assistant message on error
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }),
                           self.messages[idx].plainText.isEmpty {
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

    nonisolated private static func buildSystemPrompt(_ promptContext: PromptContext?, mode: AIChatMode) -> String? {
        let schemaPrompt = promptContext.map {
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
                queryLanguageName: $0.queryLanguageName,
                connectionRules: $0.connectionRules
            )
        }
        let modeNote = mode.systemPromptNote
        guard let schemaPrompt, !schemaPrompt.isEmpty else { return modeNote }
        return "\(schemaPrompt)\n\n\(modeNote)"
    }

    private struct ToolRoundtripContinuation {
        let nextAssistantID: UUID
        let assistantTurn: ChatTurn
        let userTurn: ChatTurn
    }

    private func completeToolRoundtrip(
        assistantIDForRound: UUID,
        toolUseBlocks: [ToolUseBlock],
        toolResultBlocks: [ToolResultBlock],
        resolved: AIProviderFactory.ResolvedProvider
    ) async -> ToolRoundtripContinuation {
        await MainActor.run { [weak self] () -> ToolRoundtripContinuation in
            let assistantText: String = {
                guard let self,
                      let idx = self.messages.firstIndex(where: { $0.id == assistantIDForRound })
                else { return "" }
                return self.messages[idx].plainText
            }()
            var assistantBlocks: [ChatContentBlock] = []
            if !assistantText.isEmpty { assistantBlocks.append(.text(assistantText)) }
            assistantBlocks.append(contentsOf: toolUseBlocks.map { .toolUse($0) })
            let assistantTurn = ChatTurn(
                id: assistantIDForRound,
                role: .assistant,
                blocks: assistantBlocks,
                modelId: resolved.model,
                providerId: resolved.config.id.uuidString
            )
            let userTurn = ChatTurn(
                role: .user,
                blocks: toolResultBlocks.map { .toolResult($0) }
            )
            let nextAssistant = ChatTurn(
                role: .assistant,
                blocks: [],
                modelId: resolved.model,
                providerId: resolved.config.id.uuidString
            )
            self?.messages.append(userTurn)
            self?.messages.append(nextAssistant)
            self?.streamingAssistantID = nextAssistant.id
            return ToolRoundtripContinuation(
                nextAssistantID: nextAssistant.id,
                assistantTurn: assistantTurn,
                userTurn: userTurn
            )
        }
    }

    private func flushPending(content: String, usage: AITokenUsage?, into assistantID: UUID) async {
        guard !content.isEmpty || usage != nil else { return }
        await MainActor.run { [weak self] in
            guard let self,
                  let idx = self.messages.firstIndex(where: { $0.id == assistantID })
            else { return }
            if !content.isEmpty {
                self.messages[idx].appendText(content)
            }
            if let usage {
                self.messages[idx].usage = usage
            }
        }
    }

    private func preflightCheck(systemPrompt: String?, turns: [ChatTurn], assistantID: UUID) async -> Bool {
        let totalSize = ((systemPrompt ?? "") as NSString).length
            + turns.reduce(0) { $0 + ($1.plainText as NSString).length }
        guard totalSize > 100_000 else { return true }
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
        return false
    }

    nonisolated static func assembleToolUseBlocks(
        order: [String],
        names: [String: String],
        inputs: [String: String]
    ) -> [ToolUseBlock] {
        order.compactMap { id -> ToolUseBlock? in
            guard let name = names[id] else { return nil }
            let inputString = inputs[id] ?? "{}"
            let inputValue: JSONValue
            if inputString.isEmpty {
                inputValue = .object([:])
            } else if let data = inputString.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                inputValue = decoded
            } else {
                inputValue = .object([:])
            }
            return ToolUseBlock(id: id, name: name, input: inputValue)
        }
    }

    /// Execute the given tool-use blocks in parallel via a `withTaskGroup`,
    /// returning result blocks in the same order. The `registry` parameter
    /// defaults to the shared singleton; tests inject a fresh instance to
    /// avoid polluting global state.
    nonisolated static func executeToolUses(
        _ blocks: [ToolUseBlock],
        mode: AIChatMode,
        context: ChatToolContext,
        registry: ChatToolRegistry? = nil
    ) async -> [ToolResultBlock] {
        await withTaskGroup(of: (Int, ToolResultBlock).self) { group in
            for (index, block) in blocks.enumerated() {
                group.addTask {
                    (index, await runToolUse(block, mode: mode, context: context, registry: registry))
                }
            }
            var indexed: [(Int, ToolResultBlock)] = []
            for await pair in group { indexed.append(pair) }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    nonisolated private static func runToolUse(
        _ block: ToolUseBlock,
        mode: AIChatMode,
        context: ChatToolContext,
        registry: ChatToolRegistry?
    ) async -> ToolResultBlock {
        if Task.isCancelled {
            return ToolResultBlock(toolUseId: block.id, content: "Cancelled", isError: true)
        }
        guard ChatToolRegistry.isToolAllowed(name: block.name, in: mode) else {
            Self.logger.warning(
                "Tool '\(block.name, privacy: .public)' blocked in \(mode.rawValue, privacy: .public) mode"
            )
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available in \(mode.displayName) mode",
                isError: true
            )
        }
        let tool = await MainActor.run {
            (registry ?? ChatToolRegistry.shared).tool(named: block.name, in: mode)
        }
        guard let tool else {
            Self.logger.warning("Tool '\(block.name, privacy: .public)' not registered; returning error")
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available",
                isError: true
            )
        }
        do {
            let result = try await tool.execute(input: block.input, context: context)
            return ToolResultBlock(
                toolUseId: block.id,
                content: result.content,
                isError: result.isError
            )
        } catch {
            Self.logger.warning(
                "Tool \(block.name, privacy: .public) execution failed: \(error.localizedDescription, privacy: .public)"
            )
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Error: \(error.localizedDescription)",
                isError: true
            )
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
        let connectionRules: String?
    }

    private func capturePromptContext(settings: AISettings) -> PromptContext? {
        guard let connection else { return nil }
        return PromptContext(
            databaseType: connection.type,
            databaseName: DatabaseManager.shared.activeDatabaseName(for: connection),
            tables: tables,
            columnsByTable: columnsByTable,
            foreignKeys: foreignKeysByTable,
            currentQuery: settings.includeCurrentQuery ? currentQuery : nil,
            queryResults: settings.includeQueryResults ? queryResults : nil,
            settings: settings,
            identifierQuote: PluginManager.shared.sqlDialect(for: connection.type)?.identifierQuote ?? "\"",
            editorLanguage: PluginManager.shared.editorLanguage(for: connection.type),
            queryLanguageName: PluginManager.shared.queryLanguageName(for: connection.type),
            connectionRules: connection.aiRules
        )
    }
}
