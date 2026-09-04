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
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "AIChatViewModel")

    enum StreamingState {
        case idle
        case loading
        case streaming(assistantID: UUID)
        case awaitingApproval
        case pausedAtToolLimit(count: Int)
        case failed(AIProviderError?)
    }

    var messages: [ChatTurn] = []
    var inputText: String = ""
    var streamingState: StreamingState = .idle {
        didSet { session?.refreshFromEngine() }
    }
    var errorMessage: String?
    var conversations: [AIConversation] = []
    var activeConversationID: UUID?
    var showAIAccessConfirmation = false
    var selectedProviderId: UUID?
    var selectedModel: String?
    var availableModels: [UUID: [String]] = [:]
    var attachedContext: [ContextItem] = []
    var attachedImages: [ChatImageInput] = []
    var savedQueries: [SQLFavorite] = []

    var connection: DatabaseConnection?

    /// Why this session is not streaming yet, when another session holds the provider it needs.
    /// The composer shows it and the session rail reads it as the `queued` status's detail line, so
    /// a queued session reads as waiting rather than as a hang.
    var providerWaitReason: String? {
        didSet { session?.refreshFromEngine() }
    }

    /// The registry entry this engine belongs to, if it has one. Weak, and the session owns the
    /// engine: a strong reference here would keep every session the user ever stopped alive.
    ///
    /// Nil for an engine nobody registered, which is what the tests build and what the inspector
    /// chat used to be. Every status update goes through here, so a nil session simply means nothing
    /// is listening.
    @ObservationIgnored internal weak var session: AgentSession?

    /// This session's tool mode. Seeded from the app setting, which stays the default for sessions
    /// created later, so two sessions can hold different modes at once.
    var chatMode: AIChatMode

    /// Which surface each connection is on, for the Assistant mode Safe Mode floor. Injectable for
    /// the same reason `streamFlushClock` is: the alternative is a test that writes the app's real
    /// UserDefaults to arrange a floor.
    @ObservationIgnored var contentModeStore: WorkspaceContentModeStore = .shared

    @ObservationIgnored var streamFlushClock: StreamFlushClock = ContinuousStreamFlushClock()
    @ObservationIgnored var streamFlushInterval: Duration = .milliseconds(50)

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
        case .idle, .awaitingApproval, .pausedAtToolLimit, .failed:
            return false
        }
    }

    var lastMessageFailed: Bool {
        if case .failed = streamingState { return true }
        return false
    }

    var toolLimitPauseCount: Int? {
        if case .pausedAtToolLimit(let count) = streamingState { return count }
        return nil
    }

    var isPausedAtToolLimit: Bool { toolLimitPauseCount != nil }

    var lastError: AIProviderError? {
        if case .failed(let error) = streamingState { return error }
        return nil
    }

    var canRetryLastFailure: Bool {
        lastError?.isRetryable ?? true
    }

    @ObservationIgnored var pendingWalkthroughBeforeSQL: String?
    @ObservationIgnored var inFlightColumnFetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var inFlightSchemaLoad: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var streamingTask: Task<Void, Never>?
    @ObservationIgnored var prepTask: Task<Void, Never>?

    /// This session's identity, for anything that must not reach another session: its pending
    /// approvals above all, which used to be keyed by the provider's own tool-use string and so
    /// could be resolved by a decision made somewhere else entirely.
    @ObservationIgnored let sessionId = UUID()

    @ObservationIgnored let services: AppServices
    var chatStorage: AIChatStorage { services.aiChatStorage }
    var sessionApprovedConnections: Set<UUID> = []
    @ObservationIgnored var cachedSavedQueries: [UUID: SQLFavorite] = [:]

    static let maxMessageCount = 200

    init(services: AppServices = .live, connection: DatabaseConnection? = nil) {
        self.services = services
        self.connection = connection
        chatMode = services.appSettings.ai.chatMode
    }

    deinit {
        streamingTask?.cancel()
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        if let parsed = SlashCommand.parse(text) {
            runSlashCommand(parsed.command, body: parsed.body)
            return
        }

        var blocks: [ChatContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        blocks.append(contentsOf: attachedContext.map { .attachment($0) })
        blocks.append(contentsOf: attachedImages.map { .image($0) })

        messages.append(ChatTurn(role: .user, blocks: blocks))
        trimMessagesIfNeeded()
        inputText = ""
        attachedContext = []
        attachedImages = []
        clearError()

        startStreaming()
    }

    func attachImage(_ image: ChatImageInput) {
        attachedImages.append(image)
    }

    func reportImageAttachmentFailure(_ message: String) {
        errorMessage = message
    }

    func detachImage(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        if case .cacheFile(let filename, _) = attachedImages[index].source {
            AIImageCache.shared.delete(filename: filename)
        }
        attachedImages.remove(at: index)
    }

    var activeProviderSupportsImages: Bool {
        let settings = services.appSettings.ai
        let configID = selectedProviderId ?? settings.activeProviderID
        guard let configID,
              let config = settings.providers.first(where: { $0.id == configID }),
              let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue)
        else { return false }
        return descriptor.supportsImages
    }

    func sendWithContext(prompt: String) {
        let userMessage = ChatTurn(role: .user, blocks: [.text(prompt)])
        messages.append(userMessage)
        trimMessagesIfNeeded()
        clearError()
        startStreaming()
    }

    func sendWithWalkthroughContext(prompt: String, beforeSQL: String) {
        pendingWalkthroughBeforeSQL = beforeSQL
        sendWithContext(prompt: prompt)
    }

    func attach(_ item: ContextItem) {
        guard !attachedContext.contains(where: { $0.stableKey == item.stableKey }) else { return }
        attachedContext.append(item)
        Task { await primeAttachmentData(for: item) }
    }

    func detach(_ item: ContextItem) {
        attachedContext.removeAll { $0.stableKey == item.stableKey }
    }

    func turn(withID id: UUID) -> ChatTurn? {
        messages.first { $0.id == id }
    }

    /// The first tool call still waiting for a decision, in transcript order. Only that row's Run
    /// takes `Return`; several rows carrying the default action at once meant `Return` fired
    /// whichever button AppKit reached first.
    var firstPendingToolUseId: String? {
        for turn in messages {
            for block in turn.blocks {
                guard case .toolUse(let use) = block.kind, case .pending = use.approvalState else { continue }
                return use.id
            }
        }
        return nil
    }

    func cancelStream() {
        pendingWalkthroughBeforeSQL = nil
        prepTask?.cancel()
        prepTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        ToolApprovalCenter.shared.cancelAll(sessionId: sessionId)
        ProviderStreamLease.shared.releaseAll(sessionId: sessionId)
        providerWaitReason = nil

        if case .streaming(let assistantID) = streamingState,
           let idx = messages.firstIndex(where: { $0.id == assistantID }) {
            let turn = messages[idx]
            turn.finishStreamingTextBlock()
            if turn.blocks.isEmpty {
                messages.remove(at: idx)
            }
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

        deleteLastProviderTurn()
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
        resetProviderConversation()
        cancelStream()
        persistCurrentConversation()
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func switchConversation(to id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        resetProviderConversation()
        cancelStream()
        persistCurrentConversation()
        messages = conversation.messages.map { ChatTurn(wire: $0) }
        activeConversationID = conversation.id
        clearError()
    }

    /// Drops the derived context a stopped session no longer needs, and keeps everything it would
    /// need to carry on: the transcript, the conversation id, and the connection.
    ///
    /// This replaces a `clearSessionData()` that emptied `messages`, `connection` and
    /// `activeConversationID` as well. It ran on window close, disconnect and session loss, so a
    /// transcript the user never asked to lose was gone from three ordinary paths. What is released
    /// here is only what a reopened session rebuilds on its own: the schema maps, the tab's current
    /// query and result text, and any fetch still in flight.
    func releaseDerivedContext() {
        prepTask?.cancel()
        prepTask = nil
        columnsByTable = [:]
        foreignKeysByTable = [:]
        inFlightColumnFetches.values.forEach { $0.cancel() }
        inFlightColumnFetches.removeAll()
        inFlightSchemaLoad?.cancel()
        inFlightSchemaLoad = nil
        currentQuery = nil
        queryResults = nil
        pendingWalkthroughBeforeSQL = nil
        sessionApprovedConnections = []
    }

    /// Deletes the cache files behind images that were attached but never sent. Only a session being
    /// removed reaches this: a stopped session can be reopened, and its composer is still holding
    /// those attachments.
    func releaseUnsentAttachments() {
        for image in attachedImages {
            if case .cacheFile(let filename, _) = image.source {
                AIImageCache.shared.delete(filename: filename)
            }
        }
        attachedImages = []
        attachedContext = []
    }

    func handleFixError(query: String, error: String) {
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.fixError(query: query, error: error, databaseType: databaseType)
        sendWithWalkthroughContext(prompt: prompt, beforeSQL: query)
    }

    func loadAvailableModels() async {
        let settings = services.appSettings.ai
        let pending = settings.providers.filter { availableModels[$0.id] == nil }
        guard !pending.isEmpty else { return }

        let results = await withTaskGroup(of: (UUID, [String]?).self) { group in
            for config in pending {
                let apiKey: String?
                switch config.type.authStyle {
                case .apiKey, .optionalApiKey:
                    apiKey = services.aiKeyStorage.loadAPIKey(for: config.id)
                case .oauth, .none:
                    apiKey = nil
                }
                group.addTask {
                    let transport = await AIProviderFactory.createProvider(for: config, apiKey: apiKey)
                    do {
                        let models = try await transport.fetchAvailableModels()
                        AIModelCatalog.shared.store(providerTypeID: config.type.rawValue, models: models)
                        return (config.id, models.map(\.id))
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

    /// The provider configuration this session streams on. Resolved the same way the stream itself
    /// resolves it, because a stale `selectedProviderId` naming a deleted provider falls back to the
    /// active one: recomputing the choice here instead would reset a configuration nobody is using
    /// and leave the real conversation running.
    var activeProviderConfigId: UUID? {
        AIProviderFactory.resolveConfig(
            settings: services.appSettings.ai,
            overrideProviderId: selectedProviderId
        )?.id
    }

    /// Detaches this session from its provider-side conversation, waiting for any other session
    /// streaming on the same configuration rather than skipping. Skipping was silent, and a reset
    /// that does not happen leaves the next turn appended to the conversation the user just left.
    func resetProviderConversation() {
        guard let configId = activeProviderConfigId else { return }
        let session = sessionId
        Task { @MainActor in
            await ProviderStreamLease.shared.withLease(configId: configId, sessionId: session) {
                AIProviderFactory.resetCopilotConversation(configId: configId, sessionId: session)
            }
        }
    }

    func deleteLastProviderTurn() {
        guard let configId = activeProviderConfigId else { return }
        let session = sessionId
        Task { @MainActor in
            await ProviderStreamLease.shared.withLease(configId: configId, sessionId: session) {
                AIProviderFactory.copilotDeleteLastTurn(configId: configId, sessionId: session)
            }
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
