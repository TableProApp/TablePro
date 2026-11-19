//
//  ConnectionCatalogSnapshot.swift
//  TablePro
//

import Combine
import Foundation

// The services key every list by connection, so observing them re-rendered every window on any connection's load.
@MainActor
final class ConnectionCatalogSnapshot: ObservableObject {
    @Published private(set) var tables: [TableInfo]
    @Published private(set) var schemas: [String]
    @Published private(set) var isRefreshing: Bool
    @Published private(set) var databases: [DatabaseMetadata]

    let connectionId: UUID
    private let schemaService: SchemaService
    private let treeService: DatabaseTreeMetadataService
    private var observations: [AnyCancellable] = []

    init(connectionId: UUID, schemaService: SchemaService, treeService: DatabaseTreeMetadataService) {
        self.connectionId = connectionId
        self.schemaService = schemaService
        self.treeService = treeService
        tables = schemaService.tables(for: connectionId)
        schemas = schemaService.schemas(for: connectionId)
        isRefreshing = schemaService.isRefreshing(connectionId: connectionId)
        databases = treeService.databases(for: connectionId)
        observations = [
            schemaService.onMainActorChange { [weak self] in self?.readSchemaService() },
            treeService.onMainActorChange { [weak self] in self?.readTreeService() }
        ]
    }

    // Each write is guarded: an unguarded @Published write publishes an equal value too.
    private func readSchemaService() {
        let tables = schemaService.tables(for: connectionId)
        if tables != self.tables { self.tables = tables }
        let schemas = schemaService.schemas(for: connectionId)
        if schemas != self.schemas { self.schemas = schemas }
        let isRefreshing = schemaService.isRefreshing(connectionId: connectionId)
        if isRefreshing != self.isRefreshing { self.isRefreshing = isRefreshing }
    }

    private func readTreeService() {
        let databases = treeService.databases(for: connectionId)
        if databases != self.databases { self.databases = databases }
    }
}

// What the sidebar's views read from the services, scoped to one connection. They read the services directly and
// redraw when this moves, so anything a body reads and this omits stops updating.
@MainActor
final class ConnectionSidebarCatalog: ObservableObject {
    struct Drawn: Equatable {
        let lists: DatabaseTreeRenderInputs
        let listingPhases: [DatabaseTreeMetadataService.DatabaseKey: MetadataLoadPhase]
        let tablesNeedingFetch: Set<DatabaseTreeMetadataService.ObjectsKey>
        let temporaryTables: DrawnRows<TableInfo>
        let isRefreshing: Bool
        let isCatalogCurrent: Bool
        let status: ConnectionStatus?
        let driver: ObjectIdentifier?
        let browseScope: DatabaseScope?
        let toolbarSchema: String?
    }

    @Published private(set) var drawn: Drawn

    private let connectionId: UUID
    private let toolbarState: ConnectionToolbarState?
    private let schemaService: SchemaService
    private let treeMetadata: DatabaseTreeMetadataService
    private let temporaryTables: TemporaryTableStore
    private let databaseManager: DatabaseManager
    private var isReadScheduled = false
    private var observations: [AnyCancellable] = []

    init(
        connectionId: UUID,
        toolbarState: ConnectionToolbarState?,
        schemaService: SchemaService = .shared,
        treeMetadata: DatabaseTreeMetadataService = .shared,
        temporaryTables: TemporaryTableStore = .shared,
        databaseManager: DatabaseManager = .shared
    ) {
        self.connectionId = connectionId
        self.toolbarState = toolbarState
        self.schemaService = schemaService
        self.treeMetadata = treeMetadata
        self.temporaryTables = temporaryTables
        self.databaseManager = databaseManager
        drawn = Self.read(
            connectionId: connectionId,
            toolbarState: toolbarState,
            schemaService: schemaService,
            treeMetadata: treeMetadata,
            temporaryTables: temporaryTables,
            databaseManager: databaseManager
        )
        let wake: () -> Void = { [weak self] in self?.scheduleRead() }
        observations = [
            schemaService.onMainActorChange(wake),
            treeMetadata.onMainActorChange(wake),
            temporaryTables.onMainActorChange(wake),
            databaseManager.onMainActorChange(wake),
            ExternalSchemaTracker.shared.onMainActorChange(wake),
            toolbarState?.onMainActorChange(wake),
            // A session's status and browse position change without `DatabaseManager` publishing.
            AppEvents.shared.connectionStatusChanged
                .filter { $0.connectionId == connectionId }
                .map { _ in () }
                .merge(with: AppEvents.shared.browseContainerChanged.filter { $0 == connectionId }.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { _ in wake() }
        ].compactMap { $0 }
    }

    private func scheduleRead() {
        guard !isReadScheduled else { return }
        isReadScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReadScheduled = false
            let drawn = Self.read(
                connectionId: self.connectionId,
                toolbarState: self.toolbarState,
                schemaService: self.schemaService,
                treeMetadata: self.treeMetadata,
                temporaryTables: self.temporaryTables,
                databaseManager: self.databaseManager
            )
            if drawn != self.drawn { self.drawn = drawn }
        }
    }

    private static func read(
        connectionId: UUID,
        toolbarState: ConnectionToolbarState?,
        schemaService: SchemaService,
        treeMetadata: DatabaseTreeMetadataService,
        temporaryTables: TemporaryTableStore,
        databaseManager: DatabaseManager
    ) -> Drawn {
        let browseScope = databaseManager.browseScope(for: connectionId)
        var listingPhases: [DatabaseTreeMetadataService.DatabaseKey: MetadataLoadPhase] = [:]
        for (key, state) in treeMetadata.allSchemaTablesState where key.connectionId == connectionId {
            listingPhases[key] = state.erased
        }
        let tablesNeedingFetch = treeMetadata.tablesState.keys.filter { key in
            key.connectionId == connectionId
                && treeMetadata.tablesNeedFetch(connectionId: connectionId, database: key.database, schema: key.schema)
        }
        return Drawn(
            lists: .wholeConnection(
                connectionId: connectionId,
                treeMetadata: treeMetadata,
                schemaService: schemaService,
                temporaryTables: temporaryTables,
                browsedDatabase: browseScope?.database
            ),
            listingPhases: listingPhases,
            tablesNeedingFetch: Set(tablesNeedingFetch),
            temporaryTables: DrawnRows(
                rows: temporaryTables.tables(connectionId: connectionId, database: browseScope?.database ?? "")
            ),
            isRefreshing: schemaService.isRefreshing(connectionId: connectionId),
            isCatalogCurrent: schemaService.isCatalogCurrent(for: connectionId),
            status: databaseManager.session(for: connectionId)?.reportedStatus,
            driver: databaseManager.driver(for: connectionId).map { ObjectIdentifier($0) },
            browseScope: browseScope,
            toolbarSchema: toolbarState?.currentSchema
        )
    }
}
