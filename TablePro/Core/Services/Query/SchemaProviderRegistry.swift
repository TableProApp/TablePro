//
//  SchemaProviderRegistry.swift
//  TablePro
//
//  Manages shared SQLSchemaProvider instances across browse scopes.
//  Ref-counted with grace period removal to avoid redundant schema loads.
//

import Combine
import Foundation
import os

@MainActor
final class SchemaProviderRegistry {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaProviderRegistry")

    static let shared = SchemaProviderRegistry()

    private var providers: [DatabaseScope: SQLSchemaProvider] = [:]
    private var refCounts: [DatabaseScope: Int] = [:]
    private var removalTasks: [DatabaseScope: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    #if DEBUG
    /// Test-only init for `@testable` tests in DEBUG builds; release builds must use `.shared`.
    internal init() {
        subscribeToRefreshSignal()
    }
    #else
    private init() {
        subscribeToRefreshSignal()
    }
    #endif

    private func subscribeToRefreshSignal() {
        AppCommands.shared.refreshData
            .sink { [weak self] request in
                self?.invalidateColumnCache(for: request.connectionId)
            }
            .store(in: &cancellables)
    }

    /// Column metadata can change under any container of the connection, and dropping a
    /// cached column list only costs a refetch, so this is deliberately connection-wide.
    func invalidateColumnCache(for connectionId: UUID) {
        for (scope, provider) in providers where scope.connectionId == connectionId {
            Task { await provider.clearColumnCache() }
        }
    }

    func provider(for scope: DatabaseScope) -> SQLSchemaProvider? {
        providers[scope]
    }

    func getOrCreate(for scope: DatabaseScope) -> SQLSchemaProvider {
        if let removalTask = removalTasks[scope] {
            removalTask.cancel()
            removalTasks.removeValue(forKey: scope)
        }
        if let existing = providers[scope] {
            return existing
        }
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { table, schema in
                try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    if let schema {
                        return try await driver.fetchColumns(table: table, schema: schema)
                    }
                    return try await driver.fetchColumns(table: table)
                }
            },
            fetchAllColumns: {
                try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await driver.fetchAllColumns()
                }
            },
            fetchSchemaTables: { schema in
                try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchTables(schema: schema)
                }
            }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        providers[scope] = provider
        return provider
    }

    func retain(for scope: DatabaseScope) {
        removalTasks[scope]?.cancel()
        removalTasks.removeValue(forKey: scope)
        refCounts[scope, default: 0] += 1
    }

    func release(for scope: DatabaseScope) {
        guard var count = refCounts[scope] else { return }
        count -= 1
        if count <= 0 {
            refCounts.removeValue(forKey: scope)
            removalTasks[scope] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.providers.removeValue(forKey: scope)
                self.removalTasks.removeValue(forKey: scope)
            }
        } else {
            refCounts[scope] = count
        }
    }

    func clear(for scope: DatabaseScope) {
        providers.removeValue(forKey: scope)
        refCounts.removeValue(forKey: scope)
        removalTasks[scope]?.cancel()
        removalTasks.removeValue(forKey: scope)
    }

    /// Disconnect teardown. The driver every provider of this connection fetches through is
    /// gone, so all of them go, not just the one the last window happened to browse.
    func clear(connectionId: UUID) {
        for scope in providers.keys.filter({ $0.connectionId == connectionId }) {
            clear(for: scope)
        }
        for scope in refCounts.keys.filter({ $0.connectionId == connectionId }) {
            clear(for: scope)
        }
        for scope in removalTasks.keys.filter({ $0.connectionId == connectionId }) {
            clear(for: scope)
        }
    }

    func purgeUnused() {
        let orphanedScopes = providers.keys.filter { scope in
            let count = refCounts[scope] ?? 0
            let hasPendingRemoval = removalTasks[scope] != nil
            return count <= 0 && !hasPendingRemoval
        }
        for scope in orphanedScopes {
            Self.logger.info(
                "Purging orphaned schema provider connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public)"
            )
            providers.removeValue(forKey: scope)
            refCounts.removeValue(forKey: scope)
        }
    }
}
