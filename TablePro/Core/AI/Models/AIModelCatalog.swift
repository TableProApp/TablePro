//
//  AIModelCatalog.swift
//  TablePro
//

import Foundation

final class AIModelCatalog: @unchecked Sendable {
    static let shared = AIModelCatalog()

    private let lock = NSLock()
    private var fetched: [String: [String: AIModelInfo]] = [:]

    init() {}

    func store(providerTypeID: String, models: [AIModelInfo]) {
        guard !models.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var byID: [String: AIModelInfo] = [:]
        for model in models {
            byID[model.id] = model
        }
        fetched[providerTypeID] = byID
    }

    func fetchedInfo(providerTypeID: String, modelID: String) -> AIModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        return fetched[providerTypeID]?[modelID]
    }

    func resolve(providerTypeID: String, modelID: String) -> AIModelInfo {
        let overlay = AIModelOverlay.info(providerTypeID: providerTypeID, modelID: modelID)
        if let live = fetchedInfo(providerTypeID: providerTypeID, modelID: modelID) {
            return live.merging(fallback: overlay)
        }
        return overlay ?? AIModelInfo(id: modelID)
    }

    func reasoning(providerTypeID: String, modelID: String) -> AIReasoningSupport? {
        resolve(providerTypeID: providerTypeID, modelID: modelID).reasoning
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        fetched.removeAll()
    }
}
