//
//  AIModelCatalog.swift
//  TablePro
//

import Foundation

/// What each provider's own model list said about its models, one entry per provider configuration.
///
/// Keyed by configuration rather than by provider type: two custom providers are two servers, and
/// a list fetched from one used to replace what was known about the other.
final class AIModelCatalog: @unchecked Sendable {
    static let shared = AIModelCatalog()

    private let lock = NSLock()
    private var fetched: [UUID: [String: AIModelInfo]] = [:]
    private var refreshTokens: [UUID: UUID] = [:]
    private var revisions: [UUID: Int] = [:]

    init() {}

    func store(providerID: UUID, models: [AIModelInfo]) {
        guard !models.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        refreshTokens.removeValue(forKey: providerID)
        fetched[providerID] = Self.indexed(models)
        revisions[providerID, default: 0] += 1
    }

    func remove(providerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        refreshTokens.removeValue(forKey: providerID)
        fetched.removeValue(forKey: providerID)
        revisions[providerID, default: 0] += 1
    }

    func revision(providerID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return revisions[providerID, default: 0]
    }

    // For a reader such as the chat panel: it never overtakes a refresh a Save started, and its
    // answer is dropped once anything newer was written or begun since it read `revision`.
    func store(providerID: UUID, models: [AIModelInfo], ifUnchangedSince revision: Int) {
        guard !models.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard revisions[providerID, default: 0] == revision else { return }
        fetched[providerID] = Self.indexed(models)
        revisions[providerID, default: 0] += 1
    }

    /// Loads a provider's list again after Save dropped the one on record. Open chat windows read
    /// the catalog at send time and never refetch on their own, so without this they would run
    /// with no per-model limits until the next window.
    func refresh(config: AIProviderConfig, using transport: ChatTransport) async {
        let token = beginRefresh(providerID: config.id)
        let result = await Self.list(for: config, using: transport)
        finishRefresh(providerID: config.id, token: token, models: result.isLive ? result.models : [])
    }

    /// A refresh that a newer refresh, store or removal overtook is dropped when it lands, so a slow
    /// answer from the old server never describes the new one, and a deleted provider stays gone.
    func beginRefresh(providerID: UUID) -> UUID {
        let token = UUID()
        lock.lock()
        defer { lock.unlock() }
        refreshTokens[providerID] = token
        revisions[providerID, default: 0] += 1
        return token
    }

    func finishRefresh(providerID: UUID, token: UUID, models: [AIModelInfo]) {
        lock.lock()
        defer { lock.unlock() }
        guard refreshTokens[providerID] == token else { return }
        refreshTokens.removeValue(forKey: providerID)
        guard !models.isEmpty else { return }
        fetched[providerID] = Self.indexed(models)
        revisions[providerID, default: 0] += 1
    }

    private static func indexed(_ models: [AIModelInfo]) -> [String: AIModelInfo] {
        var byID: [String: AIModelInfo] = [:]
        for model in models {
            byID[model.id] = model
        }
        return byID
    }

    func fetchedInfo(providerID: UUID?, modelID: String) -> AIModelInfo? {
        guard let providerID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fetched[providerID]?[modelID]
    }

    // What a send knows about a model before any list loaded: the bundled or cached catalog, never the network.
    func info(
        providerID: UUID?,
        source: AIModelSource,
        modelID: String,
        reference: AIModelReference = .shared
    ) -> AIModelInfo? {
        fetchedInfo(providerID: providerID, modelID: modelID) ?? reference.info(source: source, modelID: modelID)
    }
}

struct AIModelListResult {
    let models: [AIModelInfo]
    // Set when the provider's own list could not be read; `models` then come from the catalog, marked offline.
    let error: Error?

    var isLive: Bool { error == nil }
}

extension AIModelCatalog {
    // The one way a provider's model list is read: the provider's answer merged with the catalog.
    static func list(
        for config: AIProviderConfig,
        using transport: ChatTransport,
        reference: AIModelReference = .shared
    ) async -> AIModelListResult {
        let source = AIModelSource(config: config)
        // The ChatGPT list is asked as the Codex release the catalog names, so a newer catalog goes first.
        // Every other list merges with the catalog on hand; a refresh serves the next one.
        if source.readsClientVersion {
            await reference.refresh()
        } else if source.key != nil {
            Task { await reference.refresh() }
        }
        let live: [AIModelInfo]?
        let failure: Error?
        do {
            live = try await transport.fetchAvailableModels()
            failure = nil
        } catch {
            live = nil
            failure = error
        }
        let unlisted = config.preset?.modelIDFilter(forEndpoint: config.endpoint) ?? .all
        let models = AIModelMerge.merge(live: live, reference: reference.provider(source.key), source: source)
            .filter { unlisted.lists($0.id) }
        return AIModelListResult(models: models, error: failure)
    }
}
