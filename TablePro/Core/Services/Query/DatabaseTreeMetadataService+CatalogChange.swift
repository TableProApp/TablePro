//
//  DatabaseTreeMetadataService+CatalogChange.swift
//  TablePro
//

import Foundation

/// Which of the tree's loaded lists a catalog change reaches. Only lists something already loaded
/// are named: a database nobody expanded has nothing on screen to go stale, and it loads fresh when
/// it is expanded.
struct CatalogTreeRefreshPlan: Equatable, Sendable {
    var refreshesDatabaseList = false
    var schemaLists: Set<DatabaseTreeMetadataService.DatabaseKey> = []
    var tables: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    /// Loaded partition lists, which are keyed per table and do not follow their parent's list. A
    /// flat or hierarchical tree takes its tables from `SchemaService`, so a loaded partition list
    /// can exist with no `tablesState` entry beside it, and planning from the table keys alone left
    /// an expanded partitioned table showing its partitions from before the DDL forever.
    var partitions: Set<DatabaseTreeMetadataService.PartitionsKey> = []
    var routines: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    var triggers: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    var types: Set<DatabaseTreeMetadataService.ObjectsKey> = []
    /// Marked stale rather than refetched, for the reason `loadAllSchemaTables` gives.
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
        let databaseType = DatabaseManager.shared.session(for: change.connectionId)?.connection.type
        await withTaskGroup(of: Void.self) { group in
            if plan.refreshesDatabaseList, let databaseType {
                group.addTask { await self.refreshDatabases(connectionId: change.connectionId, databaseType: databaseType) }
            }
            for key in plan.schemaLists {
                group.addTask { await self.refreshSchemas(connectionId: key.connectionId, database: key.database) }
            }
            for key in plan.tables {
                group.addTask {
                    await self.refreshTableObjects(connectionId: key.connectionId, database: key.database, schema: key.schema)
                }
            }
            for key in plan.partitions {
                group.addTask { await self.refreshPartitions(key) }
            }
            for key in plan.routines {
                group.addTask {
                    await self.refreshRoutineObjects(connectionId: key.connectionId, database: key.database, schema: key.schema)
                }
            }
            for key in plan.triggers {
                group.addTask {
                    await self.refreshTriggerObjects(connectionId: key.connectionId, database: key.database, schema: key.schema)
                }
            }
            for key in plan.types {
                group.addTask {
                    await self.refreshUserDefinedTypeObjects(
                        connectionId: key.connectionId, database: key.database, schema: key.schema
                    )
                }
            }
        }
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
        /// A partition list is reached by its own database alone. Matching its schema too would
        /// miss a PostgreSQL partition that lives in another schema than the table it belongs to,
        /// which is exactly the cross-schema case the tree draws under its parent.
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
