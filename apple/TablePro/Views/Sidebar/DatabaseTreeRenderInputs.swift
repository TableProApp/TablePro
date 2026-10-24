//
//  DatabaseTreeRenderInputs.swift
//  TablePro
//

import Foundation

// What one connection's outline draws from the services it observes. Those services publish for every
// connection and every property, so a wake rebuilds the outline only when this value moved.
struct DatabaseTreeRenderInputs: Equatable {
    typealias DatabaseKey = DatabaseTreeMetadataService.DatabaseKey
    typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey

    struct Rows<Element: Sendable>: Equatable {
        let phase: MetadataLoadPhase
        let rows: SameRows<Element>

        init(_ state: MetadataLoadState<[Element]>) {
            self.phase = state.erased
            self.rows = SameRows(rows: state.value ?? [])
        }
    }

    struct Currency: Equatable {
        let tables: Bool
        let routines: Bool
        let triggers: Bool
        let types: Bool
    }

    struct Listing: Equatable {
        let phase: MetadataLoadPhase
        let tables: SameRows<TableInfo>
        let unlisted: Set<String>
        let covered: CatalogTableListing.SchemaSelection?
    }

    struct TemporaryTables: Equatable {
        let tables: SameRows<TableInfo>
        let session: ObjectIdentifier
    }

    struct Sidebar: Equatable {
        let recentTables: [RecentTableEntry]
        let layout: SidebarLayout
        let databaseFilter: Set<String>
        let schemaFilter: [String: Set<String>]
        let redisKeyTree: ObjectIdentifier?
    }

    let databases: Rows<DatabaseMetadata>
    let schemaLists: [DatabaseKey: Rows<String>]
    let tables: [ObjectsKey: Rows<TableInfo>]
    let routines: [ObjectsKey: Rows<RoutineInfo>]
    let triggers: [ObjectsKey: Rows<TriggerInfo>]
    let types: [ObjectsKey: Rows<UserDefinedTypeInfo>]
    let currency: [ObjectsKey: Currency]
    let partitions: [DatabaseTreeMetadataService.PartitionsKey: Rows<PartitionInfo>]
    let listings: [DatabaseKey: Listing]
    let listsRevision: Int
    let catalogGeneration: Int
    let loadedScope: DatabaseScope?
    // `SchemaService.runLoad` settles these a suspension before it moves the generation.
    let catalogRoutines: Rows<RoutineInfo>
    let catalogTriggers: Rows<TriggerInfo>
    let catalogTypes: Rows<UserDefinedTypeInfo>
    let temporaryTables: [TemporaryTableStore.Key: TemporaryTables]
    let sidebar: Sidebar?

    @MainActor
    init(
        connectionId: UUID,
        treeMetadata: DatabaseTreeMetadataService,
        schemaService: SchemaService,
        temporaryTables: TemporaryTableStore,
        sidebarState: SharedSidebarState?
    ) {
        let ownsObjects = { (key: ObjectsKey) in key.connectionId == connectionId }
        let tables = Self.slice(treeMetadata.tablesState, where: ownsObjects) { Rows($0) }
        let routines = Self.slice(treeMetadata.routinesState, where: ownsObjects) { Rows($0) }
        let triggers = Self.slice(treeMetadata.triggersState, where: ownsObjects) { Rows($0) }
        let types = Self.slice(treeMetadata.typesState, where: ownsObjects) { Rows($0) }
        var currency: [ObjectsKey: Currency] = [:]
        for key in Set(tables.keys).union(routines.keys).union(triggers.keys).union(types.keys) {
            currency[key] = Currency(
                tables: treeMetadata.isTablesCurrent(connectionId: connectionId, database: key.database, schema: key.schema),
                routines: treeMetadata.isRoutinesCurrent(connectionId: connectionId, database: key.database, schema: key.schema),
                triggers: treeMetadata.isTriggersCurrent(connectionId: connectionId, database: key.database, schema: key.schema),
                types: treeMetadata.isTypesCurrent(connectionId: connectionId, database: key.database, schema: key.schema)
            )
        }
        var listings: [DatabaseKey: Listing] = [:]
        for (key, state) in treeMetadata.allSchemaTablesState where key.connectionId == connectionId {
            listings[key] = Listing(
                phase: state.erased,
                tables: SameRows(rows: state.value?.tables ?? []),
                unlisted: state.value?.unlistedSchemas ?? [],
                covered: treeMetadata.allSchemaTablesSelection(connectionId: connectionId, database: key.database)
            )
        }
        self.databases = Rows(treeMetadata.databaseListState(for: connectionId))
        self.schemaLists = Self.slice(treeMetadata.schemaList, where: { $0.connectionId == connectionId }) { Rows($0) }
        self.tables = tables
        self.routines = routines
        self.triggers = triggers
        self.types = types
        self.currency = currency
        self.partitions = Self.slice(treeMetadata.partitionsState, where: { $0.connectionId == connectionId }) { Rows($0) }
        self.listings = listings
        self.listsRevision = treeMetadata.listsRevision(for: connectionId)
        self.catalogGeneration = schemaService.generationToken(for: connectionId)
        self.loadedScope = schemaService.loadedScope(for: connectionId)
        self.catalogRoutines = Rows(schemaService.routinesLoadState(for: connectionId))
        self.catalogTriggers = Rows(schemaService.triggersLoadState(for: connectionId))
        self.catalogTypes = Rows(schemaService.userDefinedTypesLoadState(for: connectionId))
        self.temporaryTables = Self.slice(temporaryTables.listings, where: { $0.connectionId == connectionId }) {
            TemporaryTables(tables: SameRows(rows: $0.tables), session: $0.session)
        }
        self.sidebar = sidebarState.map { state in
            Sidebar(
                recentTables: state.recentTables,
                layout: state.sidebarLayout,
                databaseFilter: state.databaseFilterSelected,
                schemaFilter: state.schemaFilterSelected,
                redisKeyTree: state.redisKeyTreeViewModel.map { ObjectIdentifier($0) }
            )
        }
    }

    private static func slice<Key: Hashable, Value, Snapshot>(
        _ states: [Key: Value],
        where belongs: (Key) -> Bool,
        _ snapshot: (Value) -> Snapshot
    ) -> [Key: Snapshot] {
        var slice: [Key: Snapshot] = [:]
        for (key, value) in states where belongs(key) {
            slice[key] = snapshot(value)
        }
        return slice
    }
}
