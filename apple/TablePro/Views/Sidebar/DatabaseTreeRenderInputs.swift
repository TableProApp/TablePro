//
//  DatabaseTreeRenderInputs.swift
//  TablePro
//

import Foundation

// `==` on these models follows identity, so a row with a new comment or definition still equals the old one.
protocol DatabaseTreeDrawnRow {
    func drawsSame(as other: Self) -> Bool
}

extension DatabaseTreeDrawnRow where Self: Equatable {
    func drawsSame(as other: Self) -> Bool {
        self == other
    }
}

extension String: DatabaseTreeDrawnRow {}
extension DatabaseMetadata: DatabaseTreeDrawnRow {}
extension PartitionInfo: DatabaseTreeDrawnRow {}
extension TriggerInfo: DatabaseTreeDrawnRow {}

extension TableInfo: DatabaseTreeDrawnRow {
    func drawsSame(as other: TableInfo) -> Bool {
        self == other && rowCount == other.rowCount && comment == other.comment
            && partitionCount == other.partitionCount && isSystemVersioned == other.isSystemVersioned
            && ownedByTable == other.ownedByTable && ownedByColumn == other.ownedByColumn
    }
}

extension RoutineInfo: DatabaseTreeDrawnRow {
    func drawsSame(as other: RoutineInfo) -> Bool {
        name == other.name && schema == other.schema && kind == other.kind
            && argumentSignature == other.argumentSignature && returnType == other.returnType
            && language == other.language && identity == other.identity
            && definition == other.definition && attributes == other.attributes
    }
}

extension UserDefinedTypeInfo: DatabaseTreeDrawnRow {
    func drawsSame(as other: UserDefinedTypeInfo) -> Bool {
        name == other.name && kind == other.kind && schema == other.schema && identity == other.identity
            && enumLabels == other.enumLabels && fields == other.fields && baseType == other.baseType
            && columnTypeSpelling == other.columnTypeSpelling && definition == other.definition
            && attributes == other.attributes && comment == other.comment && defaultValue == other.defaultValue
            && isNotNull == other.isNotNull && constraints == other.constraints
    }
}

extension ServerObjectInfo: DatabaseTreeDrawnRow {
    func drawsSame(as other: ServerObjectInfo) -> Bool {
        kindId == other.kindId && name == other.name && schema == other.schema && identity == other.identity
            && detail == other.detail && isEnabled == other.isEnabled && definition == other.definition
            && attributes == other.attributes
    }
}

// Two reads of one catalog are different buffers holding the same rows.
struct DrawnRows<Element: DatabaseTreeDrawnRow>: Equatable {
    let rows: [Element]

    static func == (lhs: DrawnRows, rhs: DrawnRows) -> Bool {
        guard lhs.rows.count == rhs.rows.count else { return false }
        if SameRows(rows: lhs.rows) == SameRows(rows: rhs.rows) { return true }
        return zip(lhs.rows, rhs.rows).allSatisfy { $0.drawsSame(as: $1) }
    }
}

// What one connection's outline draws from the services it observes. Those services publish for every
// connection and every property, so a wake rebuilds the outline only when this value moved.
struct DatabaseTreeRenderInputs: Equatable {
    typealias DatabaseKey = DatabaseTreeMetadataService.DatabaseKey
    typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey
    typealias ServerObjectsKey = DatabaseTreeMetadataService.ServerObjectsKey

    struct Rows<Element: DatabaseTreeDrawnRow & Sendable>: Equatable {
        let phase: MetadataLoadPhase
        let rows: DrawnRows<Element>

        init(_ state: MetadataLoadState<[Element]>) {
            self.phase = state.erased
            self.rows = DrawnRows(rows: state.value ?? [])
        }

        init(_ state: SchemaState) where Element == TableInfo {
            switch state {
            case .idle: phase = .idle
            case .loading: phase = .loading
            case .loaded: phase = .loaded
            case .failed(let message): phase = .failed(message)
            }
            if case .loaded(let tables) = state {
                rows = DrawnRows(rows: tables)
            } else {
                rows = DrawnRows(rows: [])
            }
        }
    }

    // One schema of the catalog on screen. `needsFetch` is here because an expanded row reads a schema again on the
    // pass after a change overtakes it.
    struct SchemaObjects: Equatable {
        let tables: Rows<TableInfo>
        let routines: Rows<RoutineInfo>
        let triggers: Rows<TriggerInfo>
        let types: Rows<UserDefinedTypeInfo>
        let serverObjects: [String: Rows<ServerObjectInfo>]
        let isCurrent: Bool
        let needsFetch: Bool

        init(_ shown: SchemaService.ShownSchema) {
            tables = Rows(shown.tables)
            routines = Rows(shown.side.routines)
            triggers = Rows(shown.side.triggers)
            types = Rows(shown.side.userDefinedTypes)
            serverObjects = shown.side.serverObjects.mapValues { Rows($0) }
            isCurrent = shown.isCurrent
            needsFetch = shown.needsFetch
        }
    }

    struct Currency: Equatable {
        let tables: Bool
        let routines: Bool
        let triggers: Bool
        let types: Bool
    }

    struct Listing: Equatable {
        // Every reader in the outline takes idle and loading alike, so a read starting draws nothing new.
        enum Outcome: Equatable {
            case pending
            case loaded
            case failed
        }

        let outcome: Outcome
        let tables: DrawnRows<TableInfo>
        let unlisted: Set<String>
        let covered: CatalogTableListing.SchemaSelection?

        init(_ state: MetadataLoadState<CatalogTableListing.Result>, covered: CatalogTableListing.SchemaSelection?) {
            switch state {
            case .idle, .loading: outcome = .pending
            case .loaded: outcome = .loaded
            case .failed: outcome = .failed
            }
            tables = DrawnRows(rows: state.value?.tables ?? [])
            unlisted = state.value?.unlistedSchemas ?? []
            self.covered = covered
        }

        // Draws the same as a database with no listing entry.
        var isUnread: Bool {
            outcome == .pending && covered == nil
        }
    }

    struct TemporaryTables: Equatable {
        let tables: DrawnRows<TableInfo>
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
    let serverObjects: [ServerObjectsKey: Rows<ServerObjectInfo>]
    let currency: [ObjectsKey: Currency]
    let serverObjectsCurrency: [ServerObjectsKey: Bool]
    let partitions: [DatabaseTreeMetadataService.PartitionsKey: Rows<PartitionInfo>]
    let listings: [DatabaseKey: Listing]
    let listsRevision: Int
    let browsedDatabase: String?
    let shownCatalog: SchemaService.CatalogKey
    let loadedScope: DatabaseScope?
    let catalogTables: Rows<TableInfo>
    let catalogSchemas: [String]
    let attachedSchemas: [String]
    let schemaObjects: [String: SchemaObjects]
    let externalSchemas: [String: Set<String>]
    let catalogRoutines: Rows<RoutineInfo>
    let catalogTriggers: Rows<TriggerInfo>
    let catalogTypes: Rows<UserDefinedTypeInfo>
    let catalogServerObjects: [String: Rows<ServerObjectInfo>]
    let temporaryTables: [TemporaryTableStore.Key: TemporaryTables]
    let sidebar: Sidebar?

    @MainActor
    init(
        connectionId: UUID,
        treeMetadata: DatabaseTreeMetadataService,
        schemaService: SchemaService,
        temporaryTables: TemporaryTableStore,
        sidebarState: SharedSidebarState?,
        rootShape: SidebarRootShape,
        searchText: String,
        browsedDatabase: String?
    ) {
        self.init(
            connectionId: connectionId,
            treeMetadata: treeMetadata,
            schemaService: schemaService,
            temporaryTables: temporaryTables,
            sidebarState: sidebarState,
            readsDatabaseList: rootShape == .databaseTree,
            readsListings: !searchText.isEmpty,
            browsedDatabase: browsedDatabase
        )
    }

    // Every list the connection holds, for the views around the outline, whatever shape or search is on screen.
    @MainActor
    static func wholeConnection(
        connectionId: UUID,
        treeMetadata: DatabaseTreeMetadataService,
        schemaService: SchemaService,
        temporaryTables: TemporaryTableStore,
        browsedDatabase: String?
    ) -> DatabaseTreeRenderInputs {
        DatabaseTreeRenderInputs(
            connectionId: connectionId,
            treeMetadata: treeMetadata,
            schemaService: schemaService,
            temporaryTables: temporaryTables,
            sidebarState: nil,
            readsDatabaseList: true,
            readsListings: true,
            browsedDatabase: browsedDatabase
        )
    }

    @MainActor
    private init(
        connectionId: UUID,
        treeMetadata: DatabaseTreeMetadataService,
        schemaService: SchemaService,
        temporaryTables: TemporaryTableStore,
        sidebarState: SharedSidebarState?,
        readsDatabaseList: Bool,
        readsListings: Bool,
        browsedDatabase: String?
    ) {
        let ownsObjects = { (key: ObjectsKey) in key.connectionId == connectionId }
        let tables = Self.slice(treeMetadata.tablesState, where: ownsObjects) { Rows($0) }
        let routines = Self.slice(treeMetadata.routinesState, where: ownsObjects) { Rows($0) }
        let triggers = Self.slice(treeMetadata.triggersState, where: ownsObjects) { Rows($0) }
        let types = Self.slice(treeMetadata.typesState, where: ownsObjects) { Rows($0) }
        let serverObjects = Self.slice(treeMetadata.serverObjectsState, where: { $0.connectionId == connectionId }) {
            Rows($0)
        }
        var serverObjectsCurrency: [ServerObjectsKey: Bool] = [:]
        for key in serverObjects.keys {
            serverObjectsCurrency[key] = treeMetadata.isServerObjectsCurrent(
                connectionId: connectionId, database: key.database, schema: key.schema, kindId: key.kindId
            )
        }
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
        // The outline reads the listing only under a search, and Open Quickly loads it with none: landing
        // then reloaded every row. A search starting refreshes the outline anyway.
        for (key, state) in treeMetadata.allSchemaTablesState where key.connectionId == connectionId && readsListings {
            let listing = Listing(
                state, covered: treeMetadata.allSchemaTablesSelection(connectionId: connectionId, database: key.database)
            )
            // A first read adds its key as it starts, which must not count as a change either.
            if !listing.isUnread { listings[key] = listing }
        }
        // Only the database tree draws the server's database list; the other shapes reloaded every row as it loaded.
        self.databases = Rows(readsDatabaseList ? treeMetadata.databaseListState(for: connectionId) : .idle)
        self.schemaLists = Self.slice(treeMetadata.schemaList, where: { $0.connectionId == connectionId }) { Rows($0) }
        self.tables = tables
        self.routines = routines
        self.triggers = triggers
        self.types = types
        self.serverObjects = serverObjects
        self.currency = currency
        self.serverObjectsCurrency = serverObjectsCurrency
        self.partitions = Self.slice(treeMetadata.partitionsState, where: { $0.connectionId == connectionId }) { Rows($0) }
        self.listings = listings
        self.listsRevision = treeMetadata.listsRevision(for: connectionId)
        self.browsedDatabase = browsedDatabase
        self.shownCatalog = schemaService.shownKey(connectionId)
        self.loadedScope = schemaService.loadedScope(for: connectionId)
        self.catalogTables = Rows(schemaService.state(for: connectionId))
        self.catalogSchemas = schemaService.schemas(for: connectionId)
        self.attachedSchemas = schemaService.attachedSchemas(for: connectionId)
        self.schemaObjects = schemaService.shownSchemas(for: connectionId).mapValues { SchemaObjects($0) }
        self.externalSchemas = ExternalSchemaTracker.shared.names(connectionId: connectionId)
        self.catalogRoutines = Rows(schemaService.routinesLoadState(for: connectionId))
        self.catalogTriggers = Rows(schemaService.triggersLoadState(for: connectionId))
        self.catalogTypes = Rows(schemaService.userDefinedTypesLoadState(for: connectionId))
        self.catalogServerObjects = schemaService.serverObjectStates(for: connectionId).mapValues { Rows($0) }
        self.temporaryTables = Self.slice(temporaryTables.listings, where: { $0.connectionId == connectionId }) {
            TemporaryTables(tables: DrawnRows(rows: $0.tables), session: $0.session)
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
