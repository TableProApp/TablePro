//
//  WindowSidebarState.swift
//  TablePro
//

import Combine
import Foundation
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

extension DatabaseTableKey {
    init(_ ref: DatabaseTreeTableRef) {
        self.init(database: ref.database ?? "", schema: ref.schema, table: ref.table.name)
    }
}

/// One detail group under one table, as a window records it open.
struct DatabaseTableDetailGroupKey: Hashable, Sendable {
    let table: DatabaseTableKey
    let group: TableDetailGroupKind
}

struct PendingTableOperation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let operation: TableOperationType
    let tables: [DatabaseTreeTableRef]
}

@MainActor
internal final class WindowSidebarState: ObservableObject {
    private let connectionId: UUID?
    private let defaults: UserDefaults
    private var isLoaded = false

    @Published var selectedTables: Set<DatabaseTreeTableRef> = []

    /// How many rows are selected, which is not the same as how many tables. A table selected
    /// alongside a schema is an extension of a selection, not a pick, and the set of tables alone
    /// cannot say so: it looks identical to having selected that one table.
    ///
    /// Only the object tree can select a row that is not a table, so every other writer goes
    /// through `selectTables(_:)` and the two stay consistent by construction.
    @Published private(set) var selectedRowCount = 0

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

    // The connection's queues are shared by every window hosting it, but a Truncate or Drop prompt belongs to the window that asked.
    @Published private(set) var pendingTableOperation: PendingTableOperation?

    func requestTableOperation(_ operation: TableOperationType, on tables: [DatabaseTreeTableRef]) {
        pendingTableOperation = PendingTableOperation(operation: operation, tables: tables)
    }

    func resolveTableOperation(_ request: PendingTableOperation) {
        guard pendingTableOperation?.id == request.id else { return }
        pendingTableOperation = nil
    }

    @Published var expandedTreeSchemas: Set<String> = [] { didSet { persistExpansion() } }
    @Published var expandedTreeDatabases: Set<String> = [] { didSet { persistExpansion() } }
    @Published var expandedTreeDatabaseSchemas: Set<DatabaseSchemaKey> = [] { didSet { persistExpansion() } }
    @Published var expandedTreeTables: Set<DatabaseTableKey> = [] { didSet { persistExpansion() } }
    @Published var expandedTreeTableDetailGroups: Set<DatabaseTableDetailGroupKey> = [] { didSet { persistExpansion() } }
    /// Folders are open until the user closes one, so this records the closed ones: a table the
    /// open tab shows is only highlighted when its row is on screen.
    @Published var collapsedTableFolders: Set<UUID> = [] { didSet { persistExpansion() } }
    @Published private(set) var treeObjectGroupExpansion: [DatabaseTreeObjectGroup: Bool] = [:] {
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
    @Published private(set) var didSeedExpansion = false

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

    init(connectionId: UUID? = nil, defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.connectionId = connectionId
        self.defaults = defaults
        loadExpansion()
        isLoaded = true
    }

    // The kind rides as its persistence name, so a value this build does not know drops only that entry.
    private struct PersistedObjectGroup: Codable {
        let database: String
        let schema: String?
        let kind: String
        let expanded: Bool
    }

    /// The group rides as its raw string for the reason `PersistedObjectGroup` gives.
    private struct PersistedTableDetailGroup: Codable {
        let database: String
        let schema: String?
        let table: String
        let group: String
    }

    private struct PersistedExpansion: Codable {
        var schemas: [String]
        var databases: [String]
        var databaseSchemas: [DatabaseSchemaKey]
        var tables: [DatabaseTableKey]?
        var objectGroups: [PersistedObjectGroup]?
        var seeded: Bool?
        var collapsedFolders: [UUID]?
        var tableDetailGroups: [PersistedTableDetailGroup]?
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
        collapsedTableFolders = Set(decoded.collapsedFolders ?? [])
        expandedTreeTableDetailGroups = Self.tableDetailGroups(from: decoded.tableDetailGroups ?? [])
        didSeedExpansion = decoded.seeded ?? true
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty,
           expandedTreeDatabaseSchemas.isEmpty, expandedTreeTables.isEmpty,
           expandedTreeTableDetailGroups.isEmpty, treeObjectGroupExpansion.isEmpty,
           collapsedTableFolders.isEmpty, !didSeedExpansion {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas),
            tables: Array(expandedTreeTables),
            objectGroups: Self.persistedObjectGroups(from: treeObjectGroupExpansion),
            seeded: didSeedExpansion,
            collapsedFolders: Array(collapsedTableFolders),
            tableDetailGroups: Self.persistedTableDetailGroups(from: expandedTreeTableDetailGroups)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func objectGroupExpansion(
        from persisted: [PersistedObjectGroup]
    ) -> [DatabaseTreeObjectGroup: Bool] {
        persisted.reduce(into: [:]) { result, entry in
            guard let kind = SidebarObjectKind(persistenceName: entry.kind) else { return }
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
                kind: group.kind.persistenceName,
                expanded: expanded
            )
        }
    }

    private static func tableDetailGroups(
        from persisted: [PersistedTableDetailGroup]
    ) -> Set<DatabaseTableDetailGroupKey> {
        Set(persisted.compactMap { entry in
            guard let group = TableDetailGroupKind(rawValue: entry.group) else { return nil }
            return DatabaseTableDetailGroupKey(
                table: DatabaseTableKey(database: entry.database, schema: entry.schema, table: entry.table),
                group: group
            )
        })
    }

    private static func persistedTableDetailGroups(
        from keys: Set<DatabaseTableDetailGroupKey>
    ) -> [PersistedTableDetailGroup] {
        keys.map { key in
            PersistedTableDetailGroup(
                database: key.table.database,
                schema: key.table.schema,
                table: key.table.table,
                group: key.group.rawValue
            )
        }
    }
}
