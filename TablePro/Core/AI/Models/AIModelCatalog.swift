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

    init() {}

    func store(providerID: UUID, models: [AIModelInfo]) {
        guard !models.isEmpty else { return }
        var byID: [String: AIModelInfo] = [:]
        for model in models {
            byID[model.id] = model
        }
        lock.lock()
        defer { lock.unlock() }
        fetched[providerID] = byID
    }

    func remove(providerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        fetched.removeValue(forKey: providerID)
    }

    func fetchedInfo(providerID: UUID?, modelID: String) -> AIModelInfo? {
        guard let providerID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fetched[providerID]?[modelID]
    }
}
