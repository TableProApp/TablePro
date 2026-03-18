//
//  SchemaProviderRegistry.swift
//  TablePro
//
//  Manages shared SQLSchemaProvider instances across connections.
//  Ref-counted with grace period removal to avoid redundant schema loads.
//

import Foundation
import os

@MainActor
final class SchemaProviderRegistry {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaProviderRegistry")

    static let shared = SchemaProviderRegistry()

    private var providers: [UUID: SQLSchemaProvider] = [:]
    private var refCounts: [UUID: Int] = [:]
    private var removalTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    func provider(for connectionId: UUID) -> SQLSchemaProvider? {
        providers[connectionId]
    }

    func getOrCreate(for connectionId: UUID) -> SQLSchemaProvider {
        if let existing = providers[connectionId] {
            return existing
        }
        let provider = SQLSchemaProvider()
        providers[connectionId] = provider
        return provider
    }

    func retain(for connectionId: UUID) {
        removalTasks[connectionId]?.cancel()
        removalTasks.removeValue(forKey: connectionId)
        refCounts[connectionId, default: 0] += 1
    }

    func release(for connectionId: UUID) {
        guard var count = refCounts[connectionId] else { return }
        count -= 1
        if count <= 0 {
            refCounts.removeValue(forKey: connectionId)
            removalTasks[connectionId] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self.providers.removeValue(forKey: connectionId)
                self.removalTasks.removeValue(forKey: connectionId)
            }
        } else {
            refCounts[connectionId] = count
        }
    }

    func clear(for connectionId: UUID) {
        providers.removeValue(forKey: connectionId)
        refCounts.removeValue(forKey: connectionId)
        removalTasks[connectionId]?.cancel()
        removalTasks.removeValue(forKey: connectionId)
    }

    func purgeUnused() {
        let orphanedIds = providers.keys.filter { connectionId in
            let count = refCounts[connectionId] ?? 0
            let hasPendingRemoval = removalTasks[connectionId] != nil
            return count <= 0 && !hasPendingRemoval
        }
        for connectionId in orphanedIds {
            Self.logger.info("Purging orphaned schema provider for connection \(connectionId)")
            providers.removeValue(forKey: connectionId)
            refCounts.removeValue(forKey: connectionId)
        }
    }
}
