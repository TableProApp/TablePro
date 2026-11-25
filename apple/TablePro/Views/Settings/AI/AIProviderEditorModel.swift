import Combine
import Foundation

enum AIModelSelection: Hashable {
    case model(String)
    case custom
}

// The provider's models as the merge ordered them: the default first, deprecated ones apart.
struct AIModelChoices: Equatable {
    let active: [AIModelInfo]
    let deprecated: [AIModelInfo]
    private let titles: [String: String]

    init(models: [AIModelInfo]) {
        active = models.filter { !$0.isDeprecated }
        deprecated = models.filter(\.isDeprecated)
        titles = AIModelInfo.titles(for: models)
    }

    func title(for model: AIModelInfo) -> String {
        let title = titles[model.id] ?? model.label
        guard model.isDeprecated else { return title }
        guard let retiresAt = model.retiresAt else {
            return String(format: String(localized: "%@ (deprecated)"), title)
        }
        let date = retiresAt.formatted(.dateTime.year().month(.abbreviated).day())
        return String(format: String(localized: "%@ (retires %@)"), title, date)
    }

    func contains(_ modelID: String) -> Bool {
        active.contains { $0.id == modelID } || deprecated.contains { $0.id == modelID }
    }

    func selection(for modelID: String, choseOther: Bool) -> AIModelSelection {
        if choseOther || !contains(modelID) { return .custom }
        return .model(modelID)
    }
}

// The rules the Edit Connection sheet saves by, kept pure so they can be tested.
enum AIProviderConnectionRules {
    enum KeyWrite: Equatable {
        case keep
        case save(String)
        case delete
    }

    // A key that failed to load or was never touched is never written over.
    static func keyWrite(edited: Bool, typed: String) -> KeyWrite {
        guard edited else { return .keep }
        return typed.isEmpty ? .delete : .save(typed)
    }

    static func canSave(isKeyLoaded: Bool, authStyle: AIProviderType.AuthStyle, apiKey: String) -> Bool {
        guard isKeyLoaded else { return false }
        guard authStyle == .apiKey else { return true }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Only the fields this sheet edits move; the model and the rest keep what the page committed meanwhile.
    static func merged(
        _ current: AIProviderConfig,
        with draft: AIProviderConfig,
        allowsName: Bool,
        allowsEndpoint: Bool
    ) -> AIProviderConfig {
        var merged = current
        if allowsName { merged.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if allowsEndpoint { merged.endpoint = draft.endpoint }
        return merged
    }

    static func connectionChanged(
        from current: AIProviderConfig,
        to merged: AIProviderConfig,
        keyWrite: KeyWrite,
        savedKey: String
    ) -> Bool {
        if current.endpoint != merged.endpoint { return true }
        switch keyWrite {
        case .keep: return false
        case .save(let key): return key != savedKey
        case .delete: return !savedKey.isEmpty
        }
    }
}

enum AIProviderKeychain {
    @concurrent
    static func key(for providerID: UUID) async -> String? {
        AIKeyStorage.shared.loadAPIKey(for: providerID)
    }

    @concurrent
    static func providersWithKey(_ providerIDs: [UUID]) async -> Set<UUID> {
        var found: Set<UUID> = []
        for id in providerIDs {
            if let key = AIKeyStorage.shared.loadAPIKey(for: id), !key.isEmpty {
                found.insert(id)
            }
        }
        return found
    }
}

// The draft behind the Add Provider and Edit Connection sheets. Nothing reaches settings or the Keychain before Save.
@MainActor
final class AIProviderEditorModel: ObservableObject {
    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    let loader: AIModelListLoader

    @Published var draft: AIProviderConfig
    @Published var maxOutputTokensText: String
    @Published var saveError: String?
    @Published private(set) var apiKey = ""
    @Published private(set) var keyEdited = false
    @Published private(set) var isKeyLoaded: Bool
    @Published private(set) var choseOtherModel = false
    @Published private(set) var isTesting = false
    @Published private(set) var testResult: TestResult?

    private let savedEndpoint: String
    private var savedAPIKey = ""
    private var lastFetch: AIModelListInputs?
    private var connectionRevision = 0
    private var testTask: Task<Void, Never>?

    init(provider: AIProviderConfig, isNew: Bool, loader: AIModelListLoader = AIModelListLoader()) {
        self.loader = loader
        self.draft = provider
        self.savedEndpoint = provider.endpoint
        self.maxOutputTokensText = provider.maxOutputTokens.map(String.init) ?? ""
        self.isKeyLoaded = isNew || !provider.authStyle.usesAPIKey
    }

    var descriptor: AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: draft.type.rawValue)
    }

    var allowsName: Bool { descriptor?.allowsNameConfiguration == true }
    var allowsEndpoint: Bool { descriptor?.allowsEndpointConfiguration == true }
    var usesAPIKey: Bool { draft.authStyle.usesAPIKey }
    var showsMaxOutputTokens: Bool { descriptor?.allowsMaxOutputTokens == true }
    var showsTelemetryToggle: Bool { descriptor?.showsTelemetryToggle == true }
    var fetchesModelList: Bool { descriptor?.fetchesModelList == true }

    var normalizedDraft: AIProviderConfig {
        var provider = draft
        provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.endpoint = AIProviderDraftRules.endpoint(draft.endpoint, defaultEndpoint: draft.defaultEndpoint)
        provider.maxOutputTokens = Self.maxOutputTokens(from: maxOutputTokensText)
        return provider
    }

    // Empty or below 1 means the provider's default.
    nonisolated static func maxOutputTokens(from text: String) -> Int? {
        guard let value = SettingsIntegerInput.parse(text), value > 0 else { return nil }
        return value
    }

    var resolvedEndpoint: AIEndpoint? {
        AIEndpoint(normalizedDraft.endpoint, style: draft.type.endpointStyle)
    }

    var resolvedChatURL: String? {
        resolvedEndpoint?.chatURL(model: draft.model, style: draft.type.endpointStyle)?.absoluteString
    }

    // Keyless local servers send no authorization header, so the key is named only when one goes out.
    var cleartextCaution: String? {
        guard resolvedEndpoint?.isPlaintextToRemoteHost == true else { return nil }
        guard usesAPIKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Requests to this host are sent unencrypted over http.")
        }
        return String(localized: "Your API key is sent unencrypted over http to this host.")
    }

    var choices: AIModelChoices {
        AIModelChoices(models: loader.models)
    }

    var modelSelection: AIModelSelection {
        choices.selection(for: draft.model, choseOther: choseOtherModel)
    }

    var isCustomModel: Bool {
        modelSelection == .custom
    }

    func reasoning(forModelID id: String) -> AIReasoningSupport {
        let info = loader.models.first { $0.id == id }
            ?? AIModelReference.shared.info(source: AIModelSource(config: draft), modelID: id)
        return descriptor?.reasoning(for: info) ?? .unsupported
    }

    var reasoningForCurrentModel: AIReasoningSupport {
        reasoning(forModelID: draft.model)
    }

    var showsReasoningPicker: Bool {
        descriptor?.supportsReasoning == true
            && (!reasoningForCurrentModel.effortLevels.isEmpty || reasoningForCurrentModel.canTurnOff)
    }

    var needsModelChoice: Bool {
        AIProviderDraftRules.needsModelChoice(model: draft.model, fetched: loader.models)
    }

    // Until the list answers for the key and Base URL on screen there is nothing to start the model on.
    var modelListSettled: Bool {
        guard fetchesModelList,
              AIProviderDraftRules.modelListBlocker(descriptor: descriptor, draft: draft, apiKey: apiKey) == nil
        else { return true }
        return !loader.isLoading && loader.answeredFor == fetchInputs
    }

    // What the automatic fetch sends: the Base URL as typed, trimmed, never the default an empty field saves as.
    private var fetchInputs: AIModelListInputs {
        let endpoint = allowsEndpoint
            ? draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            : normalizedDraft.endpoint
        return AIModelListInputs(endpoint: endpoint, apiKey: apiKey)
    }

    var canAdd: Bool {
        guard modelListSettled, !needsModelChoice else { return false }
        guard draft.authStyle == .apiKey else { return true }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveConnection: Bool {
        AIProviderConnectionRules.canSave(isKeyLoaded: isKeyLoaded, authStyle: draft.authStyle, apiKey: apiKey)
    }

    var keyWrite: AIProviderConnectionRules.KeyWrite {
        AIProviderConnectionRules.keyWrite(edited: keyEdited, typed: apiKey)
    }

    func loadKey() async {
        guard !isKeyLoaded else { return }
        let key = await AIProviderKeychain.key(for: draft.id) ?? ""
        savedAPIKey = key
        if !keyEdited { apiKey = key }
        isKeyLoaded = true
    }

    func editKey(_ typed: String) {
        guard typed != apiKey else { return }
        apiKey = typed
        keyEdited = true
        connectionEdited()
    }

    func connectionEdited() {
        connectionRevision += 1
        testResult = nil
        loader.markStale()
    }

    func select(_ selection: AIModelSelection) {
        switch selection {
        case .model(let id):
            choseOtherModel = false
            selectModel(id, picked: true)
        case .custom:
            choseOtherModel = true
            if choices.contains(draft.model) {
                selectModel("", picked: false)
            }
        }
    }

    func typeModel(_ typed: String) {
        choseOtherModel = true
        selectModel(typed, picked: false)
    }

    // The model and the effort it allows change together, in one write.
    func selectModel(_ id: String, picked: Bool) {
        var next = draft
        next.model = id
        next.reasoningEffort = picked
            ? AIProviderDraftRules.effort(afterPicking: draft.reasoningEffort, reasoning: reasoning(forModelID: id))
            : AIProviderDraftRules.effort(keeping: draft.reasoningEffort, reasoning: reasoning(forModelID: id))
        draft = next
    }

    func selectInitialModel() {
        guard draft.model.isEmpty, !choseOtherModel,
              let initial = AIProviderDraftRules.initialModel(fetched: loader.models)
        else { return }
        selectModel(initial, picked: false)
    }

    // Before any fetch, so the effort fits a model already saved or typed.
    func prepare() {
        selectInitialModel()
        selectModel(draft.model, picked: false)
    }

    // The automatic fetch reads the Base URL as typed: resolving an empty field to the default would send the key elsewhere.
    func fetchModels(force: Bool = false) async {
        var config = normalizedDraft
        let inputs = fetchInputs
        config.endpoint = inputs.endpoint
        guard force || inputs != lastFetch else { return }
        lastFetch = inputs
        let revision = connectionRevision
        await loader.load(config: config, apiKey: apiKey)
        // An edit made while the list loaded leaves it describing the previous key or Base URL.
        if revision != connectionRevision {
            loader.markStale()
        }
        selectInitialModel()
    }

    func test() {
        if draft.authStyle == .apiKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            testResult = .failure(String(localized: "API key is required"))
            return
        }
        let transport = AIProviderFactory.makeUncachedProvider(for: normalizedDraft, apiKey: apiKey)
        isTesting = true
        testResult = nil
        testTask?.cancel()
        testTask = Task { [weak self] in
            let outcome: TestResult
            do {
                outcome = try await transport.testConnection()
                    ? .success
                    : .failure(String(localized: "Connection test failed"))
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            guard !Task.isCancelled, let self else { return }
            self.isTesting = false
            self.testResult = outcome
        }
    }

    func cancelTasks() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        loader.cancel()
    }

    // The sheet's list reaches the shared catalog only on Save, and only if it describes what was saved.
    func commitModelList() {
        let saved = normalizedDraft
        let update = AIProviderDraftRules.catalogUpdate(
            listIsCurrent: loader.isCurrent,
            listIsEmpty: loader.models.isEmpty,
            connectionChanged: saved.endpoint != savedEndpoint || apiKey != savedAPIKey
        )
        switch update {
        case .store:
            AIModelCatalog.shared.store(providerID: saved.id, models: loader.models)
        case .remove:
            AIModelCatalog.shared.remove(providerID: saved.id)
        case .refetch:
            AIModelCatalog.shared.remove(providerID: saved.id)
            guard fetchesModelList else { return }
            let transport = AIProviderFactory.makeUncachedProvider(for: saved, apiKey: apiKey)
            Task { await AIModelCatalog.shared.refresh(config: saved, using: transport) }
        case .keep:
            break
        }
    }

    // Returns the provider to store, or nil when the Keychain refused the key and the sheet stays open.
    func providerToAdd() -> AIProviderConfig? {
        let provider = normalizedDraft
        let key = apiKey
        if provider.authStyle.usesAPIKey, !key.isEmpty {
            guard AIKeyStorage.shared.saveAPIKey(key, for: provider.id) else {
                saveError = String(localized: "The API key could not be saved to the Keychain.")
                return nil
            }
        }
        cancelTasks()
        commitModelList()
        return provider
    }

    struct ConnectionSave: Equatable {
        let provider: AIProviderConfig
        let connectionChanged: Bool
        let hasKey: Bool
    }

    func connectionSave(current: AIProviderConfig) -> ConnectionSave? {
        let write = keyWrite
        switch write {
        case .keep:
            break
        case .save(let key):
            guard AIKeyStorage.shared.saveAPIKey(key, for: current.id) else {
                saveError = String(localized: "The API key could not be saved to the Keychain.")
                return nil
            }
        case .delete:
            AIKeyStorage.shared.deleteAPIKey(for: current.id)
        }
        cancelTasks()
        let merged = AIProviderConnectionRules.merged(
            current,
            with: normalizedDraft,
            allowsName: allowsName,
            allowsEndpoint: allowsEndpoint
        )
        let changed = AIProviderConnectionRules.connectionChanged(
            from: current,
            to: merged,
            keyWrite: write,
            savedKey: savedAPIKey
        )
        return ConnectionSave(
            provider: merged,
            connectionChanged: changed,
            hasKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
