//
//  DatabaseTreeMetadataService+CatalogChange.swift
//  TablePro
//

import Foundation

/// Which loaded lists a change overtakes. They are marked stale and read again by the next reader
/// on screen; only the database list is read now.
struct CatalogTreeRefreshPlan: Equatable, Sendable {
    var refreshesDatabaseList = false
    var schemaLists: Set<DatabaseTreeMetadataService.DatabaseKey> = []
    var tables: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    /// Planned from their own keys: a flat or hierarchical tree takes its tables from `SchemaService`,
    /// so a loaded partition list can have no table list beside it.
    var partitions: Set<DatabaseTreeMetadataService.PartitionsKey> = []
    var routines: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    var triggers: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    var types: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    var allSchemaTables: Set<DatabaseTreeMetadataService.DatabaseKey> = []

    var isEmpty: Bool {
        !refreshesDatabaseList && schemaLists.isEmpty && tables.isEmpty && partitions.isEmpty
            && routines.isEmpty && triggers.isEmpty && types.isEmpty && allSchemaTables.isEmpty
    }
}

extension DatabaseTreeMetadataService {
    func refreshesBeforeOtherTargets(for change: CatalogChange) -> Bool {
        change.kinds.contains(.databases)
    }

    /// The database list is read now: one statement, never on a COMMIT, and its readers have no
    /// way to ask for it again.
    func refreshCatalog(for change: CatalogChange) async {
        let plan = Self.catalogRefreshPlan(
            for: change,
            hasDatabaseList: databaseList[change.connectionId] != nil,
            schemaListKeys: schemaList.keys,
            tableKeys: tablesState.keys,
            partitionKeys: partitionsState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            allSchemaTableKeys: allSchemaTablesState.keys
        )
        guard !plan.isEmpty else { return }
        markAllSchemaTablesChanged(plan.allSchemaTables)
        markStale(plan, connectionId: change.connectionId)
        guard plan.refreshesDatabaseList,
              let databaseType = DatabaseManager.shared.session(for: change.connectionId)?.connection.type
        else { return }
        await refreshDatabases(connectionId: change.connectionId, databaseType: databaseType)
    }

    /// Every list the connection holds, or one database's, including the all-schema listing.
    func markListsStale(connectionId: UUID, database: String? = nil) {
        let plan = Self.catalogRefreshPlan(
            for: CatalogChange(connectionId: connectionId, database: database, kinds: [.objects, .schemas]),
            hasDatabaseList: false,
            schemaListKeys: schemaList.keys,
            tableKeys: tablesState.keys,
            partitionKeys: partitionsState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            allSchemaTableKeys: allSchemaTablesState.keys
        )
        markAllSchemaTablesChanged(plan.allSchemaTables)
        markStale(plan, connectionId: connectionId)
    }

    nonisolated static func catalogRefreshPlan(
        for change: CatalogChange,
        hasDatabaseList: Bool,
        schemaListKeys: some Sequence<DatabaseKey>,
        tableKeys: some Sequence<ObjectsKey>,
        partitionKeys: some Sequence<PartitionsKey> = EmptyCollection(),
        routineKeys: some Sequence<ObjectsKey>,
        triggerKeys: some Sequence<ObjectsKey>,
        typeKeys: some Sequence<ObjectsKey>,
        allSchemaTableKeys: some Sequence<DatabaseKey> = EmptyCollection()
    ) -> CatalogTreeRefreshPlan {
        func reached(_ key: ObjectsKey) -> Bool {
            key.connectionId == change.connectionId && change.reaches(database: key.database, schema: key.schema)
        }
        func objectKeys(_ keys: some Sequence<ObjectsKey>, for kind: CatalogObjectKinds) -> Set<ObjectsKey> {
            guard change.kinds.contains(kind) else { return [] }
            return Set(keys.filter(reached))
        }

        var plan = CatalogTreeRefreshPlan()
        plan.refreshesDatabaseList = change.kinds.contains(.databases) && hasDatabaseList
        if change.kinds.contains(.schemas) {
            plan.schemaLists = Set(schemaListKeys.filter { key in
                key.connectionId == change.connectionId && change.reaches(database: key.database)
            })
        }
        plan.tables = objectKeys(tableKeys, for: .tables)
        // By database alone: a PostgreSQL partition can live in another schema than its table,
        // which is the cross-schema case the tree draws under the parent.
        if change.kinds.contains(.tables) {
            plan.partitions = Set(partitionKeys.filter { key in
                key.connectionId == change.connectionId && change.reaches(database: key.database)
            })
        }
        plan.routines = objectKeys(routineKeys, for: .routines)
        plan.triggers = objectKeys(triggerKeys, for: .triggers)
        plan.types = objectKeys(typeKeys, for: .types)
        if !change.kinds.isDisjoint(with: [.tables, .schemas]) {
            plan.allSchemaTables = Set(allSchemaTableKeys.filter { key in
                key.connectionId == change.connectionId && change.reaches(database: key.database)
            })
        }
        return plan
    }
}
