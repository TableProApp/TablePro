//
//  AIChatViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

@MainActor @Observable
final class AIChatViewModel {
    static let logger = Logger(subsystem: "com.TablePro", category: "AIChatViewModel")

    enum StreamingState {
        case idle
        case loading
        case streaming(assistantID: UUID)
        case awaitingApproval
        case failed(AIProviderError?)
    }

    var messages: [ChatTurn] = []
    var inputText: String = ""
    var streamingState: StreamingState = .idle
    var errorMessage: String?
    var conversations: [AIConversation] = []
    var activeConversationID: UUID?
    var showAIAccessConfirmation = false
    var selectedProviderId: UUID?
    var selectedModel: String?
    var availableModels: [UUID: [String]] = [:]
    var attachedContext: [ContextItem] = []
    var savedQueries: [SQLFavorite] = []

    var connection: DatabaseConnection?

    var tables: [TableInfo] {
        guard let id = connection?.id else { return [] }
        return services.schemaService.tables(for: id)
    }

    var columnsByTable: [String: [ColumnInfo]] = [:]
    var foreignKeysByTable: [String: [ForeignKeyInfo]] = [:]

    var currentQuery: String?
    var queryResults: String?

    var isStreaming: Bool {
        switch streamingState {
        case .loading, .streaming:
            return true
        case .idle, .awaitingApproval, .failed:
            return false
        }
    }

    var lastMessageFailed: Bool {
        if case .failed = streamingState { return true }
        return false
    }

    var lastError: AIProviderError? {
        if case .failed(let error) = streamingState { return error }
        return nil
    }

    var canRetryLastFailure: Bool {
        lastError?.isRetryable ?? true
    }

    @ObservationIgnored var inFlightColumnFetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var inFlightSchemaLoad: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var streamingTask: Task<Void, Never>?
    @ObservationIgnored var prepTask: Task<Void, Never>?

    @ObservationIgnored let services: AppServices
    var chatStorage: AIChatStorage { services.aiChatStorage }
    var sessionApprovedConnections: Set<UUID> = []
    @ObservationIgnored var cachedSavedQueries: [UUID: SQLFavorite] = [:]

    static let maxMessageCount = 200

    init(services: AppServices = .live) {
        self.services = services
        loadConversations()
    }

    deinit {
        streamingTask?.cancel()
    }

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
        clearError()

        startStreaming()
    }

    func sendWithContext(prompt: String) {
        let userMessage = ChatTurn(role: .user, blocks: [.text(prompt)])
        messages.append(userMessage)
        trimMessagesIfNeeded()
        clearError()
        startStreaming()
    }

    func attach(_ item: ContextItem) {
        guard !attachedContext.contains(where: { $0.stableKey == item.stableKey }) else { return }
        attachedContext.append(item)
        Task { await primeAttachmentData(for: item) }
    }

    func detach(_ item: ContextItem) {
        attachedContext.removeAll { $0.stableKey == item.stableKey }
    }

    func cancelStream() {
        prepTask?.cancel()
        prepTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        ToolApprovalCenter.shared.cancelAll()

        if case .streaming(let assistantID) = streamingState,
           let idx = messages.firstIndex(where: { $0.id == assistantID }),
           messages[idx].plainText.isEmpty {
            messages.remove(at: idx)
        }
        streamingState = .idle
        persistCurrentConversation()
    }

    func retry() {
        guard lastMessageFailed else { return }

        if let lastMessage = messages.last, lastMessage.role == .assistant {
            messages.removeLast()
        }

        guard messages.last?.role == .user else { return }

        streamingState = .idle
        errorMessage = nil
        startStreaming()
    }

    func regenerate() {
        guard !isStreaming,
              let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant })
        else { return }

        AIProviderFactory.copilotDeleteLastTurn()
        messages.remove(at: lastAssistantIndex)
        clearError()
        startStreaming()
    }

    func clearError() {
        errorMessage = nil
        if case .failed = streamingState {
            streamingState = .idle
        }
    }

    func startNewConversation() {
        cancelStream()
        persistCurrentConversation()
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func switchConversation(to id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        AIProviderFactory.resetCopilotConversation()
        cancelStream()
        persistCurrentConversation()
        messages = conversation.messages
        activeConversationID = conversation.id
        clearError()
    }

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
        activeConversationID = nil
        sessionApprovedConnections = []
        streamingState = .idle
    }

    func handleFixError(query: String, error: String) {
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.fixError(query: query, error: error, databaseType: databaseType)
        sendWithContext(prompt: prompt)
    }

    func loadAvailableModels() async {
        let settings = services.appSettings.ai
        let pending = settings.providers.filter { availableModels[$0.id] == nil }
        guard !pending.isEmpty else { return }

        let results = await withTaskGroup(of: (UUID, [String]?).self) { group in
            for config in pending {
                let apiKey: String?
                switch config.type.authStyle {
                case .apiKey:
                    apiKey = services.aiKeyStorage.loadAPIKey(for: config.id)
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

    func loadSavedQueries() async {
        guard let connectionId = connection?.id else {
            savedQueries = []
            return
        }
        let favorites = await services.sqlFavoriteManager.fetchFavorites(connectionId: connectionId)
        savedQueries = favorites
        for favorite in favorites {
            cachedSavedQueries[favorite.id] = favorite
        }
    }

    func trimMessagesIfNeeded() {
        if messages.count > Self.maxMessageCount {
            messages.removeFirst(messages.count - Self.maxMessageCount)
        }
        while messages.first?.role == .assistant {
            messages.removeFirst()
        }
    }
}
