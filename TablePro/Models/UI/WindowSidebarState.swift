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

    /// An all-empty expansion set means "the user collapsed everything" just as much as it
    /// means "the user has never opened this tree", and seeding on the former would reopen
    /// nodes they deliberately closed. This records that the seed already happened.
    private(set) var didSeedExpansion = false

    /// Opens the tree on the connection's current location the first time it is shown, so a
    /// database whose objects all sit under one schema is not a row of closed triangles.
    /// The tree renders before the connection resolves, so a call with nothing to seed
    /// must not consume the one shot: it would leave the tree closed forever.
    func seedExpansionIfNeeded(database: String?, schema: String?) {
        guard !didSeedExpansion else { return }
        let database = database?.nilIfEmpty
        let schema = schema?.nilIfEmpty
        guard database != nil || schema != nil else { return }

        didSeedExpansion = true
        if let schema { expandedTreeSchemas.insert(schema) }
        if let database {
            expandedTreeDatabases.insert(database)
            if let schema {
                expandedTreeDatabaseSchemas.insert(DatabaseSchemaKey(database: database, schema: schema))
            }
        }
        persistExpansion()
    }

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
        var seeded: Bool?
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
        didSeedExpansion = decoded.seeded ?? true
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty,
           expandedTreeDatabaseSchemas.isEmpty, expandedTreeTables.isEmpty,
           !didSeedExpansion {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas),
            tables: Array(expandedTreeTables),
            seeded: didSeedExpansion
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
