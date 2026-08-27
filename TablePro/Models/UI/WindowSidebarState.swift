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

    var selectedTables: Set<DatabaseTreeTableRef> = []

    /// How many rows are selected, which is not the same as how many tables. A table selected
    /// alongside a schema is an extension of a selection, not a pick, and the set of tables alone
    /// cannot say so: it looks identical to having selected that one table.
    ///
    /// Only the object tree can select a row that is not a table, so every other writer goes
    /// through `selectTables(_:)` and the two stay consistent by construction.
    private(set) var selectedRowCount = 0

    func selectTables(_ tables: Set<DatabaseTreeTableRef>) {
        select(tables: tables, rowCount: tables.count)
    }

    func select(tables: Set<DatabaseTreeTableRef>, rowCount: Int) {
        selectedRowCount = rowCount
        guard selectedTables != tables else { return }
        selectedTables = tables
    }

    /// Whether a background reload of the object list may re-assert the object the selected tab is
    /// showing. Only while nothing at all is selected.
    ///
    /// Anything selected is a pick the user is in the middle of, and it need not be a row they
    /// opened: extending a selection and then narrowing it back to one row navigates nowhere, so a
    /// single table can be selected while another is the tab in front. Re-asserting over it moves
    /// the highlight and changes what the Table menu would act on, without the user touching
    /// anything.
    var acceptsObjectMarkRefresh: Bool {
        selectedTables.isEmpty && selectedRowCount == 0
    }
    var expandedTreeSchemas: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabases: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabaseSchemas: Set<DatabaseSchemaKey> = [] { didSet { persistExpansion() } }
    var expandedTreeTables: Set<DatabaseTableKey> = [] { didSet { persistExpansion() } }
    private(set) var treeObjectGroupExpansion: [DatabaseTreeObjectGroup: Bool] = [:] {
        didSet { persistExpansion() }
    }

    func isTreeObjectGroupExpanded(_ group: DatabaseTreeObjectGroup) -> Bool {
        treeObjectGroupExpansion[group] ?? group.kind.isExpandedByDefault
    }

    func setTreeObjectGroup(_ group: DatabaseTreeObjectGroup, expanded: Bool) {
        if expanded == group.kind.isExpandedByDefault {
            treeObjectGroupExpansion.removeValue(forKey: group)
        } else {
            treeObjectGroupExpansion[group] = expanded
        }
    }

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

    /// The kind rides as its raw string. Decoding it as `SidebarObjectKind` throws on a value this
    /// build does not know, and one throw inside this blob discards every other expansion set.
    private struct PersistedObjectGroup: Codable {
        let database: String
        let schema: String?
        let kind: String
        let expanded: Bool
    }

    private struct PersistedExpansion: Codable {
        var schemas: [String]
        var databases: [String]
        var databaseSchemas: [DatabaseSchemaKey]
        var tables: [DatabaseTableKey]?
        var objectGroups: [PersistedObjectGroup]?
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
        treeObjectGroupExpansion = Self.objectGroupExpansion(from: decoded.objectGroups ?? [])
        didSeedExpansion = decoded.seeded ?? true
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty,
           expandedTreeDatabaseSchemas.isEmpty, expandedTreeTables.isEmpty,
           treeObjectGroupExpansion.isEmpty,
           !didSeedExpansion {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas),
            tables: Array(expandedTreeTables),
            objectGroups: Self.persistedObjectGroups(from: treeObjectGroupExpansion),
            seeded: didSeedExpansion
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func objectGroupExpansion(
        from persisted: [PersistedObjectGroup]
    ) -> [DatabaseTreeObjectGroup: Bool] {
        persisted.reduce(into: [:]) { result, entry in
            guard let kind = SidebarObjectKind(rawValue: entry.kind) else { return }
            let group = DatabaseTreeObjectGroup(database: entry.database, schema: entry.schema, kind: kind)
            result[group] = entry.expanded
        }
    }

    private static func persistedObjectGroups(
        from expansion: [DatabaseTreeObjectGroup: Bool]
    ) -> [PersistedObjectGroup] {
        expansion.map { group, expanded in
            PersistedObjectGroup(
                database: group.database,
                schema: group.schema,
                kind: group.kind.rawValue,
                expanded: expanded
            )
        }
    }
}
