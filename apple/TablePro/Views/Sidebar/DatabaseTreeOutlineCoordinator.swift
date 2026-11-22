import AppKit
import Combine
import Observation
import os
import SwiftUI
import TableProPluginKit
import TableProSQLGrammar

@MainActor
final class DatabaseTreeOutlineCoordinator: NSObject, NSTextFieldDelegate {
    internal weak var outlineView: NSOutlineView?
    internal let service = DatabaseTreeMetadataService.shared
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("DatabaseTreeCell")
    private static let nodeSweepInterval = 8
    private let favoriteTablesStorage: FavoriteTablesStorage
    internal let favoriteDatabasesStorage: FavoriteDatabasesStorage
    internal let tableFolderStorage: TableFolderStorage

    internal var connectionId = UUID()
    internal var databaseType: DatabaseType = .mysql
    internal weak var mainCoordinator: MainContentCoordinator?
    internal var windowState: WindowSidebarState?
    internal var sidebarState: SharedSidebarState?
    internal weak var viewModel: SidebarViewModel?
    internal var searchText = "" {
        didSet { if searchText.isEmpty { schemasOpenedDuringSearch.removeAll() } }
    }
    internal var schemasOpenedDuringSearch: Set<DatabaseSchemaKey> = []
    private var isConnected = false
    internal var activeDatabase: String?
    internal var activeSchema: String?
    private var pendingTruncates: Set<DatabaseTreeTableRef> = []
    private var pendingDeletes: Set<DatabaseTreeTableRef> = []
    internal var showRecentTables = true
    internal var showSystemContainers = false
    internal var showsPartitions = true
    private var rowSize: SidebarRowSize = .medium

    internal var nodeCache: DatabaseTreeNodeCache = [:]
    internal var rebuildPass = 0
    // Keyed by the parent row's id bytes, which hold its names: two schemas Swift's String equates are two parents.
    internal var childrenCache: [CatalogName: [DatabaseTreeNode]] = [:]
    internal var objectBucketsCache: [DatabaseTreeContainerKey: DatabaseTreeObjectBuckets] = [:]
    internal var listingMatchesCache: [DatabaseTreeContainerKey: DatabaseTreeFilter.SchemaListingMatches] = [:]
    internal var bucketMemo = DatabaseTreeBucketMemo<DatabaseTreeContainerSlot>()
    internal var loadedContentMemo = DatabaseTreeBucketMemo<CatalogName>()
    internal var tableRowMemo: [CatalogName: DatabaseTreeTableRows] = [:]
    // Decided where the section is built: whether a routine shows its signature depends on its siblings.
    internal var routineDisplayLabels: [String: String] = [:]
    // Built once per refresh: the container, its folders and its kind sections all read the same plan.
    internal var flatFolderPlan: TableFolderPlan?
    internal var containerFolderPlans: [DatabaseTreeContainerKey: TableFolderPlan] = [:]
    // The folder being renamed, which a search must not hide out from under the field.
    internal var revealedFolderId: UUID?
    // A reload ends a drag and drops a rename field, so one asked for during either waits for it to finish.
    internal var isDragging = false
    internal var isReloadDeferred = false
    // Resolved once when the drag starts; nil for a drag from another window.
    internal var draggedFolderItems: [TableFolderDragItem]?

    internal var renameSession: DatabaseTreeRenameSession?
    private var cachedRowContext: DatabaseTreeRowContext?
    private var cachedRowActions: DatabaseTreeRowActions?
    private var lastSelection: Set<DatabaseTreeTableRef> = []
    private var lastSelectedNodeIds: [String] = []
    private var publishedTables: Set<DatabaseTreeTableRef> = []
    private var publishedSelectionDatabase: String?
    private var isModelSelectionAdoptionPending = false
    private var openSelectionDepth = 0
    private var pendingOpenWork: DispatchWorkItem?
    private var openWork: Task<Void, Never>?
    internal var isApplyingExpansion = false
    private var isSelectionSyncScheduled = false
    private var isCollapsingItem = false
    private var isSyncingSelection = false
    private var isReloading = false
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var isReconcileForced = false
    private var renderedInputs: DatabaseTreeRenderInputs?
    private var observationGeneration = 0
    private var appearanceObservation: AnyCancellable?
    private var treeObservations: [AnyCancellable] = []

    internal let schemaService = SchemaService.shared
    internal let temporaryTables: TemporaryTableStore
    private var favoriteTables: Set<FavoriteTablesStorage.FavoriteEntry> = []
    private var favoriteDatabases: Set<FavoriteDatabaseEntry> = []
    private let favoritesObservers = OSAllocatedUnfairLock<[any NSObjectProtocol]>(uncheckedState: [])
    private var observedAppearance = DatabaseTreeOutlineCoordinator.objectListAppearance()

    init(
        favoriteTablesStorage: FavoriteTablesStorage = .shared,
        favoriteDatabasesStorage: FavoriteDatabasesStorage = .shared,
        tableFolderStorage: TableFolderStorage = .shared,
        temporaryTables: TemporaryTableStore? = nil
    ) {
        self.favoriteTablesStorage = favoriteTablesStorage
        self.favoriteDatabasesStorage = favoriteDatabasesStorage
        self.tableFolderStorage = tableFolderStorage
        self.temporaryTables = temporaryTables ?? .shared
        super.init()
    }

    internal var pendingTableOperations: Set<DatabaseTreeTableRef> {
        pendingTruncates.union(pendingDeletes)
    }

    internal var supportsSchemaLevel: Bool {
        PluginManager.shared.databaseGroupingStrategy(for: databaseType) == .bySchema
    }

    internal var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        let tableObserver = NotificationCenter.default.addObserver(
            forName: .favoriteTablesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadFavorites()
                self.refreshVisibleRows()
            }
        }
        favoritesObservers.withLockUnchecked { $0.append(tableObserver) }

        let databaseObserver = NotificationCenter.default.addObserver(
            forName: .favoriteDatabasesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadFavorites()
                self.refreshVisibleRows()
            }
        }
        favoritesObservers.withLockUnchecked { $0.append(databaseObserver) }

        let folderObserver = NotificationCenter.default.addObserver(
            forName: .tableFoldersDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changed = notification.userInfo?[TableFolderStorage.connectionIdUserInfoKey] as? UUID
            MainActor.assumeIsolated {
                guard let self, changed == self.connectionId else { return }
                self.scheduleReconcile(forcing: true)
            }
        }
        favoritesObservers.withLockUnchecked { $0.append(folderObserver) }
        observeObjectListAppearance()
    }

    // Follows the setting, not the command that wrote it, so the filter row, the empty-area menu and Settings all repaint.
    private func observeObjectListAppearance() {
        appearanceObservation = AppSettingsManager.shared.generalSlice.onMainActorChange { [weak self] in
            guard let self else { return }
            let appearance = Self.objectListAppearance()
            guard appearance != self.observedAppearance else { return }
            self.observedAppearance = appearance
            self.cachedRowContext = nil
            self.refreshVisibleRows()
        }
    }

    private static func objectListAppearance() -> ObjectListAppearance {
        let settings = AppSettingsManager.shared.general
        return ObjectListAppearance(
            showsIcons: settings.showObjectIcons,
            showsComments: settings.showObjectComments
        )
    }

    internal struct ObjectListAppearance: Equatable {
        internal let showsIcons: Bool
        internal let showsComments: Bool
    }

    deinit {
        favoritesObservers.withLockUnchecked { $0.forEach(NotificationCenter.default.removeObserver) }
    }

    func update(from view: DatabaseTreeOutlineView) {
        let connectionChanged = connectionId != view.connectionId
        connectionId = view.connectionId
        if connectionChanged { reloadFavorites() }
        databaseType = view.databaseType
        mainCoordinator = view.coordinator
        windowState = view.windowState
        sidebarState = view.sidebarState
        viewModel = view.viewModel

        let activeChanged = activeDatabase != view.activeDatabase || activeSchema != view.activeSchema
        let changed = connectionChanged
            || searchText != view.searchText
            || isConnected != view.isConnected
            || activeChanged
            || pendingTruncates != view.pendingTruncates
            || pendingDeletes != view.pendingDeletes
            || showRecentTables != view.showRecentTables
            || showSystemContainers != view.showSystemContainers
            || showsPartitions != view.showsPartitions
            || rowSize != view.resolvedRowSize

        searchText = view.searchText
        isConnected = view.isConnected
        activeDatabase = view.activeDatabase
        activeSchema = view.activeSchema
        pendingTruncates = view.pendingTruncates
        pendingDeletes = view.pendingDeletes
        showRecentTables = view.showRecentTables
        showSystemContainers = view.showSystemContainers
        showsPartitions = view.showsPartitions
        rowSize = view.resolvedRowSize

        if !hasRenderedOnce || activeChanged {
            persistActiveExpansion()
        }

        guard hasRenderedOnce, !changed else {
            hasRenderedOnce = true
            refresh()
            return
        }
        syncSelectionToModel()
    }

    private func persistActiveExpansion() {
        guard let active = activeDatabase, let windowState else { return }
        if !windowState.expandedTreeDatabases.contains(active) {
            windowState.expandedTreeDatabases.insert(active)
        }
        if let schema = activeSchema {
            let key = DatabaseSchemaKey(database: active, schema: schema)
            if !windowState.expandedTreeDatabaseSchemas.contains(key) {
                windowState.expandedTreeDatabaseSchemas.insert(key)
            }
        }
    }

    private func beginObserving() {
        observationGeneration += 1
        let generation = observationGeneration
        let wake: (Bool) -> Void = { [weak self] forcing in
            guard let self, generation == self.observationGeneration else { return }
            self.scheduleReconcile(forcing: forcing)
        }
        treeObservations = [
            service.onMainActorChange { wake(false) },
            schemaService.onMainActorChange { wake(false) },
            temporaryTables.onMainActorChange { wake(false) },
            ExternalSchemaTracker.shared.onMainActorChange { wake(false) },
            sidebarState?.onMainActorChange { wake(false) },
            // Its one published value is the key tree this outline draws.
            sidebarState?.redisKeyTreeViewModel?.onMainActorChange { wake(true) },
        ].compactMap { $0 }
    }

    private func scheduleReconcile(forcing: Bool = false) {
        isReconcileForced = isReconcileForced || forcing
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { @MainActor in
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    // A wake from a shared service rebuilds the outline only when something this connection draws moved.
    internal func reconcile() {
        let forced = isReconcileForced
        isReconcileForced = false
        let inputs = currentRenderInputs()
        guard forced || inputs != renderedInputs else {
            // The same rows in new buffers: the next comparison stops at the pointers.
            renderedInputs = inputs
            return
        }
        let keepsShape = renderedInputs.map { $0.sidebar?.layout == inputs.sidebar?.layout } ?? false
        rebuild(inputs: inputs, changingRowsOnly: !forced && keepsShape)
    }

    internal func currentRenderInputs() -> DatabaseTreeRenderInputs {
        DatabaseTreeRenderInputs(
            connectionId: connectionId,
            treeMetadata: service,
            schemaService: schemaService,
            temporaryTables: temporaryTables,
            sidebarState: sidebarState,
            rootShape: rootShape,
            searchText: searchText,
            browsedDatabase: browsingDatabase
        )
    }

    internal func refresh() {
        rebuild(inputs: nil, changingRowsOnly: false)
    }

    private func rebuild(inputs: DatabaseTreeRenderInputs?, changingRowsOnly: Bool) {
        guard let outlineView else { return }
        guard !isDragging, renameSession == nil else {
            isReloadDeferred = true
            return
        }
        isReloading = true
        rebuildPass &+= 1
        renderedInputs = inputs ?? currentRenderInputs()
        dropUnusedMemos()
        let drawnChildren = childrenCache
        childrenCache.removeAll()
        objectBucketsCache.removeAll()
        listingMatchesCache.removeAll()
        routineDisplayLabels.removeAll()
        flatFolderPlan = nil
        containerFolderPlans.removeAll()
        invalidateRowConfiguration()
        // One update for the reload and every disclosure: each expandItem on its own walks the rows and
        // builds the visible row views again, and a search opens two rows per matching schema.
        outlineView.beginUpdates()
        let appliedRowChanges = changingRowsOnly && applyRowChanges(from: drawnChildren, in: outlineView)
        if !appliedRowChanges { outlineView.reloadData() }
        applyDesiredExpansion()
        outlineView.endUpdates()
        if appliedRowChanges { refreshVisibleRows() }
        syncSelectionToModel()
        isReloading = false
        dropUnlistedNodes(in: outlineView)
        beginObserving()
        endSettledInteractionTraces()
    }

    // A row under a closed parent is not listed until it opens, so a pass that misses a row says nothing alone.
    private func dropUnlistedNodes(in outlineView: NSOutlineView) {
        guard rebuildPass % Self.nodeSweepInterval == 0 else { return }
        let oldestKept = rebuildPass - Self.nodeSweepInterval
        // The disclosure of a Redis namespace lives only in AppKit, on the node object.
        let keepsRedisNodes = sidebarState?.redisKeyTreeViewModel != nil
        nodeCache.removeNodes { node in
            guard node.lastBuiltPass < oldestKept else { return false }
            if keepsRedisNodes, case .redisNode = node.kind { return false }
            return outlineView.row(forItem: node) < 0
        }
    }

    // The memos outlive a reload, but only for the parents and containers built since the last one.
    private func dropUnusedMemos() {
        bucketMemo.dropUnused()
        loadedContentMemo.dropUnused()
        tableRowMemo = tableRowMemo.filter { childrenCache[$0.key] != nil }
    }

    // Coalesced: the edit that ended the hold usually posts a change that asks for a reload too.
    internal func applyDeferredReloadIfNeeded() {
        guard isReloadDeferred, !isDragging, renameSession == nil else { return }
        isReloadDeferred = false
        scheduleReconcile(forcing: true)
    }

    // Reconfigures in place: a reload would throw away every hosted SwiftUI view to repaint one glyph.
    internal func refreshVisibleRows() {
        guard let outlineView else { return }
        outlineView.enumerateAvailableRowViews { _, row in
            guard let node = outlineView.item(atRow: row) as? DatabaseTreeNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DatabaseTreeCellView
            else { return }
            cell.configure(
                node: node,
                isFavorite: favoriteState(for: node),
                context: rowContext,
                actions: rowActions
            )
        }
    }

    private func reloadFavorites() {
        favoriteTables = favoriteTablesStorage.favorites(for: connectionId)
        favoriteDatabases = favoriteDatabasesStorage.favorites(for: connectionId)
    }

    private func favoriteEntry(for ref: DatabaseTreeTableRef) -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId,
            database: ref.database,
            schema: ref.favoriteSchema,
            name: ref.table.name
        )
    }

    internal func isFavorite(_ ref: DatabaseTreeTableRef) -> Bool {
        favoriteTables.contains(favoriteEntry(for: ref))
    }

    private func favoriteState(for node: DatabaseTreeNode) -> Bool {
        switch node.kind {
        case .database(let metadata):
            return favoriteDatabases.contains { $0.database == metadata.name }
        default:
            guard let ref = DatabaseTreeSelection.tableRef(of: node) else { return false }
            return isFavorite(ref)
        }
    }

    internal func favoriteDatabaseEnvironments() -> [String: FavoriteDatabaseEnvironment] {
        Dictionary(favoriteDatabases.map { ($0.database, $0.environment) }) { first, _ in first }
    }

    internal func toggleFavoriteDatabase(_ database: String) {
        guard favoriteDatabases.contains(where: { $0.database == database }) else {
            favoriteDatabasesStorage.setFavorite(
                database: database,
                environment: .unassigned,
                connectionId: connectionId
            )
            return
        }
        favoriteDatabasesStorage.removeFavorite(database: database, connectionId: connectionId)
    }

    internal func toggleFavorite(_ ref: DatabaseTreeTableRef) {
        let entry = favoriteEntry(for: ref)
        favoriteTablesStorage.toggle(
            name: entry.name, schema: entry.schema, database: entry.database, connectionId: connectionId
        )
    }

    internal func selectedRefs() -> [DatabaseTreeTableRef] {
        DatabaseTreeSelection.tableRefs(of: selectedNodes())
    }

    internal func selectedContainerRefs() -> [DatabaseContainerRef] {
        let systemSchemaNames = systemSchemas
        return selectedNodes().compactMap { $0.containerRef(systemSchemas: systemSchemaNames) }
    }

    private func selectedNodes() -> [DatabaseTreeNode] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? DatabaseTreeNode
        }
    }

    internal func syncSelectionToModel() {
        guard let outlineView else { return }
        adoptModelSelection()
        let rows = lastSelectedNodeIds.compactMap { nodeId -> Int? in
            guard let node = nodeCache[nodeId] else { return nil }
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        }
        guard outlineView.selectedRowIndexes != IndexSet(rows) else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        isSyncingSelection = false
    }

    // Adopts only a table's section row, and never while a clicked open is still moving the browse database.
    private func adoptModelSelection() {
        guard let windowState, openSelectionDepth == 0 else { return }
        let selectedTables = windowState.selectedTables
        let selectionDatabase = modelSelectionDatabase
        guard selectedTables != publishedTables
            || selectionDatabase != publishedSelectionDatabase
            || isModelSelectionAdoptionPending
        else { return }
        publishedTables = selectedTables
        publishedSelectionDatabase = selectionDatabase

        // By object, not reference, so browsing another database moves the highlight to its copy of the table.
        let selectedObjects = Set(selectedTables.map(\.table))
        let nodes = nodeCache.nodes(drawing: selectedObjects).filter { node in
            selectionDatabase == nil || node.tableRef?.database == selectionDatabase
        }
        lastSelectedNodeIds = nodes.map(\.id)
        lastSelection = Set(DatabaseTreeSelection.tableRefs(of: nodes))
        // Pending while a selected table has no row yet in the browsed database; the next sync adopts it.
        isModelSelectionAdoptionPending = Set(lastSelection.map(\.table)) != selectedObjects
    }

    private var modelSelectionDatabase: String? {
        if let browseDatabase = mainCoordinator?.browseDatabaseName, !browseDatabase.isEmpty { return browseDatabase }
        guard let activeDatabase, !activeDatabase.isEmpty else { return nil }
        return activeDatabase
    }

    // Serialized: a double-click is two opens, and two reads of a stale `activeDatabase` would switch twice.
    private func open(
        _ ref: DatabaseTreeTableRef,
        activateGridFocus: Bool,
        forceNonPreview: Bool = false
    ) {
        let inFlight = openWork
        openSelectionDepth += 1
        openWork = Task { @MainActor in
            defer { openSelectionDepth -= 1 }
            await inFlight?.value
            guard await activate(ref) else { return }
            mainCoordinator?.openTableTab(
                ref.table,
                schema: ref.schema,
                forceNonPreview: forceNonPreview,
                activateGridFocus: activateGridFocus
            )
            if #available(macOS 14.0, *) {
                FeatureTipSignals.sidebarTableOpened()
            }
            publishSelection()
        }
    }

    // Published only once the tab is the clicked table, or the window's navigation observer opens it twice.
    private func publishSelection() {
        guard let windowState else { return }
        let nodes = selectedNodes()
        let tables = Set(DatabaseTreeSelection.tableRefs(of: nodes))
        publishedTables = tables
        publishedSelectionDatabase = modelSelectionDatabase
        isModelSelectionAdoptionPending = false
        // This list can select rows that are not tables, so one table beside a schema must not read as a pick.
        windowState.select(tables: tables, rowCount: nodes.count)
    }

    // False when the switch failed or was cancelled: the session is still on another database.
    internal func activate(_ ref: DatabaseTreeTableRef) async -> Bool {
        await mainCoordinator?.switchContainers(database: ref.database, schema: ref.schema) ?? true
    }

    internal func setActiveDatabase(_ database: String) {
        Task { await mainCoordinator?.switchContainers(database: database, schema: nil) }
    }

    internal func setActiveSchema(database: String?, schema: String) {
        Task { await mainCoordinator?.switchContainers(database: database, schema: schema) }
    }

    private func refreshDatabase(_ database: String) {
        if supportsSchemaLevel {
            let connectionId = connectionId
            Task {
                async let schemas: Void = service.refreshSchemas(connectionId: connectionId, database: database)
                async let serverObjects: Void = service.refreshServerObjects(
                    connectionId: connectionId, database: database, schema: nil
                )
                _ = await (schemas, serverObjects)
            }
        } else {
            Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: nil) }
        }
    }

    private func refreshObjects(database: String, schema: String?) {
        Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: schema) }
    }

    internal func refreshContainers(_ targets: [DatabaseContainerRef]) {
        for target in targets {
            switch target.kind {
            case .database: refreshDatabase(target.database ?? "")
            case .schema: refreshObjects(database: target.database ?? "", schema: target.schema)
            }
        }
    }

    // Built once per refresh, not per row: `viewFor` allocated fresh closures for every row it drew.
    private var rowContext: DatabaseTreeRowContext {
        if let cachedRowContext { return cachedRowContext }
        let context = makeRowContext()
        cachedRowContext = context
        return context
    }

    private var rowActions: DatabaseTreeRowActions {
        if let cachedRowActions { return cachedRowActions }
        let actions = makeRowActions()
        cachedRowActions = actions
        return actions
    }

    private func invalidateRowConfiguration() {
        cachedRowContext = nil
        cachedRowActions = nil
    }

    private func makeRowContext() -> DatabaseTreeRowContext {
        DatabaseTreeRowContext(
            databaseType: databaseType,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            systemSchemas: systemSchemas,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            rowSize: rowSize,
            isExternalSchema: { [connectionId] database, schema in
                ExternalSchemaTracker.shared.isExternal(
                    connectionId: connectionId,
                    database: database,
                    schema: schema
                )
            },
            objectKindTitle: { [databaseType] kind in
                kind.title(tableEntityName: PluginManager.shared.tableEntityName(for: databaseType))
            },
            routineDisplayLabel: { [weak self] ref in
                self?.routineDisplayLabels[ref.id] ?? ref.routine.name
            },
            showsPartitions: showsPartitions,
            listsAttachedSchemas: listsAttachedSchemas,
            showsObjectIcons: observedAppearance.showsIcons,
            showsObjectComments: observedAppearance.showsComments
        )
    }

    private func makeRowActions() -> DatabaseTreeRowActions {
        DatabaseTreeRowActions(
            toggleFavorite: { [weak self] ref in self?.toggleFavorite(ref) },
            toggleFavoriteDatabase: { [weak self] database in self?.toggleFavoriteDatabase(database) }
        )
    }

    // No double-click window: there is no preview tab to promote.
    private func openRedis(_ node: RedisKeyNode) {
        switch node {
        case .namespace(_, let fullPrefix, _, _):
            mainCoordinator?.browseRedisNamespace(fullPrefix)
        case .key(_, let fullKey, let keyType):
            mainCoordinator?.openRedisKey(fullKey, keyType: keyType)
        }
    }

    // A table kind refreshes as a catalog change, as Cmd+R does, so the partition lists under it go stale too.
    internal func refreshObjectKind(_ kind: SidebarObjectKind) {
        guard let mainCoordinator else { return }
        switch kind {
        case .procedure, .function: Task { await mainCoordinator.refreshRoutines() }
        case .trigger: Task { await mainCoordinator.refreshTriggers() }
        case .type: Task { await mainCoordinator.refreshUserDefinedTypes() }
        case .table, .view, .materializedView, .foreignTable, .sequence:
            CatalogChangeService.shared.record(.changed(CatalogChange(
                connectionId: connectionId,
                database: mainCoordinator.browseDatabaseName,
                kinds: .tables
            )))
        case .server(let serverKind):
            let connectionId = connectionId
            let manager = DatabaseManager.shared
            let scope = manager.browseScope(for: connectionId)
            let kindId = serverKind.id
            Task { [schemaService] in
                try? await manager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                    _ = await schemaService.reloadServerObjects(
                        connectionId: connectionId, driver: driver, scope: scope, kindId: kindId
                    )
                }
            }
        }
    }

    internal func refreshContainerObjectKind(_ group: DatabaseTreeObjectGroup) {
        if rootShape == .hierarchicalSchema, let schema = group.schema {
            reloadHierarchicalSchemaObjects(schema)
            return
        }
        let connectionId = connectionId
        Task {
            switch group.kind.category {
            case .table:
                await service.refreshTableObjects(
                    connectionId: connectionId,
                    database: group.database,
                    schema: group.schema
                )
            case .routine:
                await service.refreshRoutineObjects(
                    connectionId: connectionId,
                    database: group.database,
                    schema: group.schema
                )
            case .trigger:
                await service.refreshTriggerObjects(
                    connectionId: connectionId,
                    database: group.database,
                    schema: group.schema
                )
            case .type:
                await service.refreshUserDefinedTypeObjects(
                    connectionId: connectionId,
                    database: group.database,
                    schema: group.schema
                )
            case .server:
                await service.refreshServerObjects(
                    connectionId: connectionId,
                    database: group.database,
                    schema: group.schema,
                    kindId: group.kind.serverKind?.id
                )
            }
        }
    }

    internal func reloadHierarchicalSchemaObjects(_ schema: String) {
        let connectionId = connectionId
        let database = browsingDatabase
        Task {
            await schemaService.reloadSchemaObjects(connectionId: connectionId, schema: schema, database: database)
        }
    }

    @objc
    func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode
        else { return }
        perform(DatabaseTreeDoubleClickResolver.resolve(node: node), on: node, in: outlineView)
    }

    // Return keeps the row the way a double-click does; `NSOutlineView` routes neither on its own.
    internal func performPrimaryAction() {
        // An extended selection is a batch; opening one of its rows would move the database out from under it.
        guard let outlineView, outlineView.numberOfSelectedRows == 1,
              outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode
        else { return }
        perform(DatabaseTreeDoubleClickResolver.resolve(node: node), on: node, in: outlineView)
    }

    private func perform(
        _ intent: DatabaseTreeDoubleClickIntent,
        on node: DatabaseTreeNode,
        in outlineView: NSOutlineView
    ) {
        switch intent {
        case .openPermanently(let ref):
            if #available(macOS 14.0, *) {
                FeatureTipSignals.tableKeptOpen()
            }
            pendingOpenWork?.cancel()
            pendingOpenWork = nil
            open(ref, activateGridFocus: true, forceNonPreview: true)
        case .openObjectSource(let objectRef):
            mainCoordinator?.showObjectSource(objectRef)
        case .toggleDisclosure:
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        case .ignore:
            return
        }
    }
}

extension DatabaseTreeOutlineCoordinator: DatabaseTreeSelectionClearing {
    // The delegate path publishes the empty selection, so the Table menu agrees without a second write.
    func clearSelection() {
        guard let outlineView, !outlineView.selectedRowIndexes.isEmpty else { return }
        outlineView.deselectAll(nil)
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        resolvedChildren(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        resolvedChildren(of: item)[index]
    }

    // `isExpandable` cannot read settings, so the hide-partitions gate is applied here too.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DatabaseTreeNode, node.isExpandable else { return false }
        switch node.kind {
        case .table(let ref) where ref.table.type == .partitionedTable:
            return showsPartitions
        case .partition:
            return showsPartitions
        default:
            return true
        }
    }
}

extension DatabaseTreeOutlineCoordinator {
    // Here, not in the rename extension: an extension cannot supply `@objc` requirements for the conformance.
    internal func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        renameSession?.pendingName = field.stringValue
    }

    // Click-away commits, as Finder and the Xcode navigator do.
    internal func controlTextDidEndEditing(_ obj: Notification) {
        guard renameSession != nil else { return }
        endRename(commit: true)
    }

    internal func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            // `abortEditing` posts no `controlTextDidEndEditing`, so the cancel is not read back as a commit.
            (control as? NSTextField)?.abortEditing()
            endRename(commit: false)
            return true
        }
        return false
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DatabaseTreeCellView
            ?? makeCell()
        cell.configure(
            node: node,
            isFavorite: favoriteState(for: node),
            context: rowContext,
            actions: rowActions
        )
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? DatabaseTreeNode else { return false }
        return DatabaseTreeSelection.isSelectable(node.kind)
    }

    // A source list lays a group's children at the group's depth, so a table under Tables lines up with a database.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.isGroupRow ?? false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        return DatabaseTreeTypeSelect.matchString(
            for: node.kind,
            tableEntityName: PluginManager.shared.tableEntityName(for: databaseType)
        )
    }

    // Loads in `will`, before AppKit asks for children; the disclosure is recorded in `did`, once the state flipped.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        beginExpansionTrace(for: node)
        triggerLoad(for: node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if isRecordingExpansion {
            recordExpansion(node, expanded: true)
            restoreDescendantExpansion(afterExpanding: node)
        } else if !isApplyingExpansion, case .schema(let database, let schema) = node.kind {
            schemasOpenedDuringSearch.insert(DatabaseSchemaKey(database: database, schema: schema))
        } else if !isApplyingExpansion, case .hierarchicalSchemaSection(let schema) = node.kind {
            schemasOpenedDuringSearch.insert(Self.hierarchicalSearchKey(schema))
        }
        scheduleSelectionSync()
        endSettledInteractionTraces()
    }

    private func scheduleSelectionSync(force: Bool = false) {
        guard force || !isApplyingExpansion, !isSelectionSyncScheduled else { return }
        isSelectionSyncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSelectionSyncScheduled = false
            self.isCollapsingItem = false
            self.syncSelectionToModel()
        }
    }

    // AppKit rewrites the selection a collapse hides, outside the will/did pair; that is not a pick, so publishing waits a hop.
    func outlineViewItemWillCollapse(_ notification: Notification) {
        isCollapsingItem = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        isCollapsingItem = true
        if let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode {
            if isRecordingExpansion {
                recordExpansion(node, expanded: false)
            } else if case .schema(let database, let schema) = node.kind {
                schemasOpenedDuringSearch.remove(DatabaseSchemaKey(database: database, schema: schema))
            } else if case .hierarchicalSchemaSection(let schema) = node.kind {
                schemasOpenedDuringSearch.remove(Self.hierarchicalSearchKey(schema))
            }
        }
        scheduleSelectionSync(force: true)
    }

    // While filtering, disclosure belongs to the search, so gestures stay out of the saved state.
    private var isRecordingExpansion: Bool {
        !isApplyingExpansion && searchText.isEmpty
    }

    // Selection drives the content, not `action`, which arrives on mouse up; a single added table is published by its open.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading, !isCollapsingItem else { return }
        let nodes = selectedNodes()
        lastSelectedNodeIds = nodes.map(\.id)
        let refs = Set(DatabaseTreeSelection.openableRefs(of: nodes))
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: nodes, previousRefs: lastSelection, newRefs: refs
        )
        if let target {
            // Only a repeating key is a burst to wait out; a discrete press opens now.
            if isAutorepeatingSelection {
                scheduleOpen(target, after: NSEvent.keyRepeatInterval)
            } else {
                pendingOpenWork?.cancel()
                pendingOpenWork = nil
                open(target, activateGridFocus: false)
            }
        } else if let redisNode = singleSelectedRedisNode(in: nodes) {
            openRedis(redisNode)
        } else {
            publishSelection()
        }
        lastSelection = refs
    }

    private func singleSelectedRedisNode(in nodes: [DatabaseTreeNode]) -> RedisKeyNode? {
        guard nodes.count == 1, case .redisNode(let redisNode) = nodes[0].kind else { return nil }
        return redisNode
    }

    private var isAutorepeatingSelection: Bool {
        guard let outlineView, outlineView.window?.firstResponder === outlineView else { return false }
        guard let event = NSApp.currentEvent else { return false }
        return DatabaseTreeTypeSelect.isAutorepeatingArrowNavigation(event)
    }

    // A held arrow key is one gesture: each repeat cancels the pending open, so only the row it stops on opens.
    private func scheduleOpen(_ ref: DatabaseTreeTableRef, after delay: TimeInterval) {
        pendingOpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.open(ref, activateGridFocus: false)
        }
        pendingOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makeCell() -> DatabaseTreeCellView {
        let cell = DatabaseTreeCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}
