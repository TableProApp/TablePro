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

struct DatabaseTableKey: Hashable, Sendable, Codable {
    let database: String
    let schema: String?
    let table: String
}

@MainActor
@Observable
internal final class WindowSidebarState {
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoaded = false

    var selectedTables: Set<TableInfo> = []

    /// How many rows are selected, which is not the same as how many tables. A table selected
    /// alongside a schema is an extension of a selection, not a pick, and the set of tables alone
    /// cannot say so: it looks identical to having selected that one table.
    ///
    /// Only the object tree can select a row that is not a table, so every other writer goes
    /// through `selectTables(_:)` and the two stay consistent by construction.
    private(set) var selectedRowCount = 0

    func selectTables(_ tables: Set<TableInfo>) {
        select(tables: tables, rowCount: tables.count)
    }

    func select(tables: Set<TableInfo>, rowCount: Int) {
        selectedRowCount = rowCount
        guard selectedTables != tables else { return }
        selectedTables = tables
    }
    var expandedTreeSchemas: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabases: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabaseSchemas: Set<DatabaseSchemaKey> = [] { didSet { persistExpansion() } }
    var expandedTreeTables: Set<DatabaseTableKey> = [] { didSet { persistExpansion() } }

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
        var tables: [DatabaseTableKey]?
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
        expandedTreeTables = Set(decoded.tables ?? [])
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty,
           expandedTreeDatabaseSchemas.isEmpty, expandedTreeTables.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas),
            tables: Array(expandedTreeTables)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
