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

    init() {}

    func store(providerID: UUID, models: [AIModelInfo]) {
        guard !models.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        refreshTokens.removeValue(forKey: providerID)
        fetched[providerID] = Self.indexed(models)
    }

    func remove(providerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        refreshTokens.removeValue(forKey: providerID)
        fetched.removeValue(forKey: providerID)
    }

    /// Loads a provider's list again after Save dropped the one on record. Open chat windows read
    /// the catalog at send time and never refetch on their own, so without this they would run
    /// with no per-model limits until the next window.
    func refresh(providerID: UUID, using transport: ChatTransport) async {
        let token = beginRefresh(providerID: providerID)
        let models = (try? await transport.fetchAvailableModels()) ?? []
        finishRefresh(providerID: providerID, token: token, models: models)
    }

    /// A refresh that a newer refresh, store or removal overtook is dropped when it lands, so a slow
    /// answer from the old server never describes the new one, and a deleted provider stays gone.
    func beginRefresh(providerID: UUID) -> UUID {
        let token = UUID()
        lock.lock()
        defer { lock.unlock() }
        refreshTokens[providerID] = token
        return token
    }

    func finishRefresh(providerID: UUID, token: UUID, models: [AIModelInfo]) {
        lock.lock()
        defer { lock.unlock() }
        guard refreshTokens[providerID] == token else { return }
        refreshTokens.removeValue(forKey: providerID)
        guard !models.isEmpty else { return }
        fetched[providerID] = Self.indexed(models)
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
}
