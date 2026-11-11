//
//  AIChatViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
final class AIChatViewModel: ObservableObject {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "AIChatViewModel")

    enum StreamingState {
        case idle
        case loading
        case streaming(assistantID: UUID)
        case awaitingApproval
        case pausedAtToolLimit(count: Int)
        case failed(AIProviderError?)
    }

    @Published var messages: [ChatTurn] = []
    let composerDraft = ChatComposerDraft()
    @Published var streamingState: StreamingState = .idle
    @Published var errorMessage: String?
    @Published var conversations: [AIConversation] = []
    @Published var activeConversationID: UUID?
    @Published var showAIAccessConfirmation = false
    @Published var selectedProviderId: UUID?
    @Published var selectedModel: String?
    @Published var availableModels: [UUID: [String]] = [:]
    @Published private(set) var providerSettingsRevision = 0
    private var modelListSources: [UUID: AIModelListSource] = [:]
    private var staleModelLists: Set<UUID> = []
    private var modelListGenerations: [UUID: Int] = [:]
    @Published var attachedContext: [ContextItem] = []
    @Published var attachedImages: [ChatImageInput] = []
    @Published var savedQueries: [SQLFavorite] = []

    @Published var connection: DatabaseConnection?

    var streamFlushClock: StreamFlushClock = ContinuousStreamFlushClock()
    var streamFlushInterval: Duration = .milliseconds(50)

    var tables: [TableInfo] {
        guard let id = connection?.id else { return [] }
        return services.schemaService.tables(for: id)
    }

    @Published var columnsByTable: [String: [ColumnInfo]] = [:]
    @Published var foreignKeysByTable: [String: [ForeignKeyInfo]] = [:]

    @Published var currentQuery: String?
    @Published var queryResults: String?
    var editorTarget: AssistantEditorTarget?

    /// The composer's text. It lives on `composerDraft`, which publishes it apart from the conversation.
    var inputText: String {
        get { composerDraft.text }
        set { composerDraft.text = newValue }
    }

    var isStreaming: Bool {
        switch streamingState {
        case .loading, .streaming:
            return true
        case .idle, .awaitingApproval, .pausedAtToolLimit, .failed:
            return false
        }
    }

    var isBusy: Bool {
        switch streamingState {
        case .loading, .streaming, .awaitingApproval:
            return true
        case .idle, .pausedAtToolLimit, .failed:
            return prepTask != nil
                || heldTurnAwaitsConnection
                || ToolApprovalCenter.shared.hasPending(sessionId: sessionId)
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

    var pendingWalkthroughBeforeSQL: String?
    var pendingWalkthroughSource: QueryEditorAnchor?
    var onDeviceModel: any OnDeviceLanguageModel = SystemOnDeviceLanguageModel()
    var onDeviceTurnID: UUID?
    @Published var onDeviceRefusal: OnDeviceRefusal?
    var queryContextMetadata: any ScopedMetadataProviding
    var inFlightColumnFetches: [String: Task<Void, Never>] = [:]
    var inFlightSchemaLoad: Task<Void, Never>?
    var relevantTableNames: [String] = []
    var schemaRanker: @Sendable (AISchemaRankingInput) -> [String] = AISchemaContext.relevantTableNames(for:)
    @Published var tableMentions = TableMentionIndex.empty
    var tableMentionSource: [TableInfo] = []
    var tableMentionBuild: Task<Void, Never>?
    var tableMentionObservation: AnyCancellable?
    var bulkColumnReadTableCount: Int?
    var schemaCacheScope: String?
    // A custom command's message carries the schema it rendered, so its tables are ranked by the
    // user's own words instead.
    var schemaQuestionOverride: (turnID: UUID, text: String)?
    nonisolated(unsafe) var streamingTask: Task<Void, Never>?
    var prepTask: Task<Void, Never>?

    let services: AppServices
    var chatStorage: AIChatStorage { services.aiChatStorage }
    var cachedSavedQueries: [UUID: SQLFavorite] = [:]
    private var savedQueryCancellables: Set<AnyCancellable> = []
    private var aiSettingsCancellables: Set<AnyCancellable> = []

    static let maxMessageCount = 200

    /// The session this engine belongs to.
    ///
    /// Injected rather than minted here, because a restored session has to be the same session:
    /// identity derived inside the engine cannot round-trip, so every guarantee keyed on it
    /// (reopening by id, the rail's selection, per-session provider state) silently degraded to
    /// "make another one".
    let sessionId: UUID

    /// The conversation to pull in when this engine is first looked at, if it is resuming one.
    ///
    /// Restore is lazy on purpose: reading every stored conversation at launch is quadratic in the
    /// number of sessions, and `init` used to call `loadConversations()`, so opening any connection
    /// window read the whole chat history off disk even with the assistant never revealed.
    private var conversationToRestore: UUID?
    private var didRestoreConversation = false

    var pendingConversationToRestore: UUID? { conversationToRestore }
    var hasRestoredConversation: Bool { didRestoreConversation }

    /// Whether the connection this session names is still being opened.
    ///
    /// Agent mode draws its composer over a connect on purpose, so a turn can be submitted before
    /// there is a session to run its tools against. Every such turn used to open a stream anyway,
    /// which reached the tools with no connection behind them and answered the user's first
    /// question with a row of failures. The turn is appended to the transcript as usual and the
    /// stream is held until the connect lands, which is what a live composer during a connect
    /// promises.
    var isAwaitingConnection = false {
        didSet {
            guard oldValue, !isAwaitingConnection else { return }
            releaseHeldTurn()
        }
    }

    /// A turn that was submitted during a connect and has not been streamed yet.
    var heldTurnAwaitsConnection = false

    private func releaseHeldTurn() {
        guard heldTurnAwaitsConnection else { return }
        heldTurnAwaitsConnection = false
        startStreaming()
    }

    func markConversationRestored() {
        didRestoreConversation = true
    }

    init(
        services: AppServices = .live,
        sessionId: UUID = UUID(),
        restoringConversation conversationId: UUID? = nil
    ) {
        self.services = services
        self.sessionId = sessionId
        self.conversationToRestore = conversationId
        self.queryContextMetadata = services.databaseManager
        observeSavedQueryUpdates()
        observeAISettingsChanges()
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
              let config = settings.providers.first(where: { $0.id == configID })
        else { return false }
        return Self.acceptsImages(config: config, model: selectedModel ?? config.model, catalog: .shared)
    }

    /// The provider type sets the envelope, and the provider's own model list narrows it: a
    /// router lists text-only models beside vision ones, and an image sent to one of those fails.
    nonisolated static func acceptsImages(config: AIProviderConfig, model: String, catalog: AIModelCatalog) -> Bool {
        guard let descriptor = AIProviderRegistry.shared.descriptor(for: config.type.rawValue) else { return false }
        return descriptor.supportsImages(fetched: catalog.fetchedInfo(providerID: config.id, modelID: model))
    }

    func sendWithContext(prompt: String, schemaQuestion: String? = nil) {
        let userMessage = ChatTurn(role: .user, blocks: [.text(prompt)])
        schemaQuestionOverride = schemaQuestion.map { (userMessage.id, $0) }
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

    func turn(withID id: UUID) -> ChatTurn? {
        messages.first { $0.id == id }
    }

    func cancelStream() {
        clearPendingWalkthrough()
        prepTask?.cancel()
        prepTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        ToolApprovalCenter.shared.cancelAll(sessionId: sessionId)
        settlePendingToolApprovals()

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

        let answeredOnDevice = messages[lastAssistantIndex].providerId == AppleIntelligenceAvailability.providerID
        if !answeredOnDevice {
            AIProviderFactory.copilotDeleteLastTurn(sessionId: sessionId)
        }
        let wasLast = lastAssistantIndex == messages.count - 1
        messages.remove(at: lastAssistantIndex)
        if wasLast, answeredOnDevice, let asked = messages.last, asked.role == .user {
            onDeviceTurnID = asked.id
        }
        clearError()
        startStreaming()
    }

    func clearError() {
        errorMessage = nil
        onDeviceRefusal = nil
        if case .failed = streamingState {
            streamingState = .idle
        }
    }

    func startNewConversation() {
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        cancelStream()
        persistCurrentConversation()
        messages.removeAll()
        activeConversationID = nil
        clearError()
    }

    func switchConversation(to id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        cancelStream()
        persistCurrentConversation()
        messages = ChatToolCallRepair.settlingPendingApprovals(conversation.messages).map { ChatTurn(wire: $0) }
        activeConversationID = conversation.id
        clearError()
    }

    /// Releases everything this conversation holds, keeping what the user typed.
    ///
    /// Window close, disconnect and a lost session all reach here, and none of them is the user
    /// throwing a conversation away. It used to empty `messages` with nothing written to disk while
    /// `cancelStream()` next door persisted first, so the three ordinary ways a window goes away
    /// each dropped a reply that was still arriving.
    ///
    /// Cancelling the task is also not enough on its own to release a turn parked on an approval
    /// card: a `CheckedContinuation` is not resumed by cancellation, so the suspended turn held the
    /// provider and its open stream for the life of the process.
    func clearSessionData() {
        ToolApprovalCenter.shared.cancelAll(sessionId: sessionId)
        persistCurrentConversation()
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
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
        relevantTableNames = []
        tableMentionBuild?.cancel()
        tableMentionBuild = nil
        tableMentionSource = []
        tableMentions = .empty
        bulkColumnReadTableCount = nil
        schemaCacheScope = nil
        schemaQuestionOverride = nil
        currentQuery = nil
        queryResults = nil
        editorTarget = nil
        clearPendingWalkthrough()
        messages = []
        errorMessage = nil
        activeConversationID = nil
        streamingState = .idle
        for image in attachedImages {
            if case .cacheFile(let filename, _) = image.source {
                AIImageCache.shared.delete(filename: filename)
            }
        }
        attachedImages = []
    }

    func clearPendingWalkthrough() {
        pendingWalkthroughBeforeSQL = nil
        pendingWalkthroughSource = nil
    }

    private func observeAISettingsChanges() {
        services.appEvents.aiSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.dropSelectionOfRemovedProvider() }
            .store(in: &aiSettingsCancellables)
        services.appEvents.aiProviderSaved
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.providerWasSaved(id) }
            .store(in: &aiSettingsCancellables)
    }

    private func dropSelectionOfRemovedProvider() {
        guard let selectedProviderId,
              !services.appSettings.ai.providers.contains(where: { $0.id == selectedProviderId })
        else { return }
        self.selectedProviderId = nil
        selectedModel = nil
    }

    // A save can bring a new key, which nothing in the provider list shows.
    private func providerWasSaved(_ id: UUID) {
        staleModelLists.insert(id)
        modelListGenerations[id, default: 0] += 1
        providerSettingsRevision += 1
    }

    func modelListIsStale(for config: AIProviderConfig) -> Bool {
        modelListSources[config.id] != AIModelListSource(config: config) || staleModelLists.contains(config.id)
    }

    private enum ModelListOutcome: Sendable {
        case listed([String])
        case failed
        case notReady
    }

    private struct PendingModelList {
        let config: AIProviderConfig
        let apiKey: String?
        let source: AIModelListSource
        let generation: Int
        let catalogRevision: Int
    }

    func loadAvailableModels() async {
        let settings = services.appSettings.ai
        let providerIDs = Set(settings.providers.map(\.id))
        if availableModels.keys.contains(where: { !providerIDs.contains($0) }) {
            availableModels = availableModels.filter { providerIDs.contains($0.key) }
        }
        modelListSources = modelListSources.filter { providerIDs.contains($0.key) }

        let pending = settings.providers.compactMap { config -> PendingModelList? in
            guard modelListIsStale(for: config) else { return nil }
            return PendingModelList(
                config: config,
                apiKey: config.authStyle.usesAPIKey ? services.aiKeyStorage.loadAPIKey(for: config.id) : nil,
                source: AIModelListSource(config: config),
                generation: modelListGenerations[config.id, default: 0],
                catalogRevision: AIModelCatalog.shared.revision(providerID: config.id)
            )
        }
        guard !pending.isEmpty else { return }

        let results = await withTaskGroup(of: (UUID, ModelListOutcome).self) { group in
            for entry in pending {
                let config = entry.config
                let apiKey = entry.apiKey
                let catalogRevision = entry.catalogRevision
                group.addTask {
                    let transport = await AIProviderFactory.createProvider(for: config, apiKey: apiKey)
                    do {
                        let models = try await transport.fetchAvailableModels()
                        AIModelCatalog.shared.store(providerID: config.id, models: models, ifUnchangedSince: catalogRevision)
                        return (config.id, .listed(models.map(\.id)))
                    } catch is CancellationError {
                        return (config.id, .notReady)
                    } catch CopilotError.serverNotRunning {
                        return (config.id, .notReady)
                    } catch {
                        return (config.id, .failed)
                    }
                }
            }

            var collected: [(UUID, ModelListOutcome)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        guard !Task.isCancelled else { return }

        for (id, outcome) in results {
            // A save while this fetch was out may have brought a new key: its own fetch decides.
            guard let entry = pending.first(where: { $0.config.id == id }),
                  modelListGenerations[id, default: 0] == entry.generation
            else { continue }
            switch outcome {
            case .notReady:
                continue
            case .listed(let models) where !models.isEmpty:
                availableModels[id] = models
                modelListSources[id] = entry.source
            case .failed where modelListSources[id] == entry.source && availableModels[id]?.isEmpty == false:
                break
            case .listed, .failed:
                // Empty, so the menu shows the saved model as it stands; recorded, so a dead server is
                // asked again only after a change or a save.
                availableModels[id] = []
                modelListSources[id] = entry.source
            }
            staleModelLists.remove(id)
        }
    }

    /// The list is read once per connection and then kept current from the app-wide favorites
    /// event, the same signal the sidebar, the Quick Switcher and the editor's keyword expansion
    /// already follow. Without it a query saved from the editor during a session was offered by
    /// every one of those and by nothing in the assistant, for as long as the window stayed open.
    ///
    /// A nil payload means a global record moved, which is every connection's business.
    internal func observeSavedQueryUpdates() {
        AppEvents.shared.sqlFavoritesDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || payload == self.connection?.id else { return }
                Task { await self.loadSavedQueries() }
            }
            .store(in: &savedQueryCancellables)
    }

    func loadSavedQueries() async {
        guard let connectionId = connection?.id else {
            savedQueries = []
            return
        }
        let favorites = await services.sqlFavoriteManager.fetchFavorites(connectionId: connectionId)
        /// The connection can be switched while the read is in flight, and the list belongs to the
        /// connection that is on screen now, not the one that asked.
        guard connection?.id == connectionId else { return }
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

// A change to any of these means another server, so the list on hand no longer describes it.
struct AIModelListSource: Equatable, Sendable {
    let id: UUID
    let type: AIProviderType
    let presetID: String?
    let endpoint: String

    init(config: AIProviderConfig) {
        id = config.id
        type = config.type
        presetID = config.presetID
        endpoint = config.endpoint
    }
}
