//
//  WindowSidebarState.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

struct DatabaseSchemaKey: Hashable, Sendable, Codable {
    let database: String
    let schema: String
}

@MainActor
@Observable
internal final class WindowSidebarState {
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoaded = false

    var selectedTables: Set<TableInfo> = []
    var expandedTreeSchemas: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabases: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabaseSchemas: Set<DatabaseSchemaKey> = [] { didSet { persistExpansion() } }

    init(connectionId: UUID? = nil, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.defaults = defaults
        loadExpansion()
        isLoaded = true
    }

    private struct PersistedExpansion: Codable {
        var schemas: [String]
        var databases: [String]
        var databaseSchemas: [DatabaseSchemaKey]
    }

    private var storageKey: String? {
        connectionId.map { "com.TablePro.sidebar.treeExpansion.\($0.uuidString)" }
    }

    private func loadExpansion() {
        guard let storageKey,
              let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersistedExpansion.self, from: data) else { return }
        expandedTreeSchemas = Set(decoded.schemas)
        expandedTreeDatabases = Set(decoded.databases)
        expandedTreeDatabaseSchemas = Set(decoded.databaseSchemas)
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty, expandedTreeDatabaseSchemas.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
