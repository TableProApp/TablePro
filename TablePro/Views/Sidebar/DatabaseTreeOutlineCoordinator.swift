//
//  DatabaseTreeOutlineCoordinator.swift
//  TablePro
//

import AppKit
import Observation
import SwiftUI
import TableProPluginKit

@MainActor
final class DatabaseTreeOutlineCoordinator: NSObject {
    internal weak var outlineView: NSOutlineView?
    internal let service = DatabaseTreeMetadataService.shared
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("DatabaseTreeCell")

    internal var connectionId = UUID()
    internal var databaseType: DatabaseType = .mysql
    internal weak var mainCoordinator: MainContentCoordinator?
    internal var windowState: WindowSidebarState?
    internal var sidebarState: SharedSidebarState?
    internal weak var viewModel: SidebarViewModel?
    internal var searchText = ""
    private var isConnected = false
    internal var activeDatabase: String?
    private var activeSchema: String?
    private var pendingTruncates: Set<String> = []
    private var pendingDeletes: Set<String> = []
    internal var showRecentTables = true
    private var rowSize: SidebarRowSize = .medium

    internal var nodeCache: [String: DatabaseTreeNode] = [:]
    internal var childrenCache: [String: [DatabaseTreeNode]] = [:]
    private var cachedRowContext: DatabaseTreeRowContext?
    private var cachedRowActions: DatabaseTreeRowActions?
    private var lastSelection: Set<DatabaseTreeTableRef> = []
    private var lastSelectedNodeIds: [String] = []
    private var publishedTables: Set<TableInfo> = []
    private var pendingOpenWork: DispatchWorkItem?
    internal var isApplyingExpansion = false
    private var isSyncingSelection = false
    private var isReloading = false
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var observationGeneration = 0

    internal let schemaService = SchemaService.shared
    private var favoriteTables: Set<FavoriteTablesStorage.FavoriteEntry> = []
    private var favoritesObserver: (any NSObjectProtocol)?

    internal var supportsSchemaLevel: Bool {
        PluginManager.shared.databaseGroupingStrategy(for: databaseType) == .bySchema
    }

    internal var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    // MARK: - Attach / input

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .favoriteTablesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadFavorites()
                self.refreshVisibleRows()
            }
        }
    }

    deinit {
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
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
            || rowSize != view.resolvedRowSize

        searchText = view.searchText
        isConnected = view.isConnected
        activeDatabase = view.activeDatabase
        activeSchema = view.activeSchema
        pendingTruncates = view.pendingTruncates
        pendingDeletes = view.pendingDeletes
        showRecentTables = view.showRecentTables
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

    // MARK: - Observation

    private func beginObserving() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking { [weak self] in
            self?.snapshotDependencies()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.observationGeneration else { return }
                self.scheduleReconcile()
            }
        }
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { @MainActor in
            self.reconcileScheduled = false
            self.refresh()
        }
    }

    private func snapshotDependencies() {
        _ = service.databaseListState(for: connectionId)
        _ = sidebarState?.recentTables
        /// Both feed `rootNodes()`: the layout picks the root's shape and the filter picks which
        /// databases survive into it. Left unobserved, hiding a database in the filter popover
        /// changed nothing until some other edit happened to rebuild the tree.
        _ = sidebarState?.sidebarLayout
        _ = sidebarState?.databaseFilterSelected
        /// One token covers every table, routine and per-schema load for this connection, which is
        /// the whole reactive surface the flat and hierarchical shapes read.
        _ = schemaService.generationToken(for: connectionId)
        if let keyTree = sidebarState?.redisKeyTreeViewModel {
            _ = keyTree.isLoading
            _ = keyTree.isTruncated
            _ = keyTree.allKeys.count
        }
        for node in nodeCache.values {
            switch node.kind {
            case .database(let metadata):
                _ = service.schemaListState(connectionId: connectionId, database: metadata.name)
                _ = service.tablesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
                _ = service.routinesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
            case .schema(let database, let schema):
                _ = service.tablesLoadState(connectionId: connectionId, database: database, schema: schema)
                _ = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)
            case .hierarchicalSchemaSection(let schema):
                _ = schemaService.schemaState(for: connectionId, schema: schema)
            case .table(let ref) where ref.table.type == .partitionedTable:
                _ = service.partitionsLoadState(
                    connectionId: connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
                )
            case .recentSection, .recentTable, .table, .routine, .status,
                 .objectKindSection, .redisKeysSection, .redisNode:
                break
            }
        }
    }

    private func refresh() {
        guard let outlineView else { return }
        isReloading = true
        childrenCache.removeAll()
        invalidateRowConfiguration()
        outlineView.reloadData()
        applyDesiredExpansion()
        syncSelectionToModel()
        isReloading = false
        beginObserving()
    }

    /// A star toggling on or off changes no row and no ordering, so the rows are reconfigured in
    /// place. Reloading would throw away every hosted SwiftUI view to repaint one glyph.
    private func refreshVisibleRows() {
        guard let outlineView else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? DatabaseTreeNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DatabaseTreeCellView
            else { continue }
            cell.configure(node: node, context: rowContext, actions: rowActions)
        }
    }

    private func reloadFavorites() {
        favoriteTables = FavoriteTablesStorage.shared.favorites(for: connectionId)
    }

    private func favoriteEntry(for ref: DatabaseTreeTableRef) -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId,
            database: ref.database.isEmpty ? nil : ref.database,
            schema: ref.table.schema,
            name: ref.table.name
        )
    }

    private func toggleFavorite(_ ref: DatabaseTreeTableRef) {
        let entry = favoriteEntry(for: ref)
        FavoriteTablesStorage.shared.toggle(
            name: entry.name, schema: entry.schema, database: entry.database, connectionId: connectionId
        )
    }

    // MARK: - Selection / open

    private func selectedRefs() -> [DatabaseTreeTableRef] {
        DatabaseTreeSelection.tableRefs(of: selectedNodes())
    }

    private func selectedContainerRefs() -> [DatabaseContainerRef] {
        let systemSchemaNames = systemSchemas
        return selectedNodes().compactMap { $0.containerRef(systemSchemas: systemSchemaNames) }
    }

    private func selectedNodes() -> [DatabaseTreeNode] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? DatabaseTreeNode
        }
    }

    private func syncSelectionToModel() {
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

    /// The window writes `selectedTables` whenever the active editor tab moves, so the highlight has
    /// to follow it the way the `List(selection:)` binding this outline replaced did. Reading it back
    /// is also what keeps a click on the row that is still highlighted from being swallowed: AppKit
    /// posts no selection change when the selection already holds that row, so a highlight left
    /// behind on a table the user has since navigated away from becomes a dead row.
    ///
    /// A table can be drawn twice, once under Recent and once in its own section. Only the section
    /// row is adopted, because that is the row the model's `TableInfo` stands for.
    private func adoptModelSelection() {
        guard let windowState, windowState.selectedTables != publishedTables else { return }
        publishedTables = windowState.selectedTables
        let nodes = nodeCache.values.filter { node in
            guard case .table(let ref) = node.kind else { return false }
            return publishedTables.contains(ref.table)
        }
        lastSelectedNodeIds = nodes.map(\.id)
        lastSelection = Set(DatabaseTreeSelection.tableRefs(of: Array(nodes)))
    }

    private func open(_ ref: DatabaseTreeTableRef, activateGridFocus: Bool) {
        Task { @MainActor in
            await activate(ref)
            mainCoordinator?.openTableTab(ref.table, schema: ref.schema, activateGridFocus: activateGridFocus)
            publishSelection()
        }
    }

    /// The Table menu reads `windowState.selectedTables`, so the tree has to put its own selection
    /// there or every command that acts on a selection does nothing in tree layout.
    ///
    /// Timing is the whole trick. The shared navigation observer also watches this property, and it
    /// opens whatever single table appeared. Publishing before the tree's own open landed would race
    /// it into opening the table twice, so a selection that navigates publishes only once the tab is
    /// already the clicked table, which is exactly the case that observer resolves to skip.
    private func publishSelection() {
        guard let windowState else { return }
        let tables = DatabaseTreeSelection.tableInfos(of: selectedNodes())
        publishedTables = tables
        guard windowState.selectedTables != tables else { return }
        windowState.selectedTables = tables
    }

    private func activate(_ ref: DatabaseTreeTableRef) async {
        if ref.database != activeDatabase {
            await mainCoordinator?.switchDatabase(to: ref.database)
        }
        guard let schema = ref.schema,
              PluginManager.shared.supportsSchemaSwitching(for: databaseType),
              schema != sessionSchema else { return }
        await mainCoordinator?.switchSchema(to: schema)
    }

    /// The live session schema, not the window's toolbar mirror. A database switch
    /// moves the session schema without touching the toolbar, so comparing against
    /// the toolbar skips the switch exactly when the session needs it.
    private var sessionSchema: String? {
        DatabaseManager.shared.session(for: connectionId)?.browseSchema
    }

    private func setActiveDatabase(_ database: String) {
        guard database != activeDatabase else { return }
        Task { await mainCoordinator?.switchDatabase(to: database) }
    }

    private func setActiveSchema(database: String, schema: String) {
        Task { @MainActor in
            if database != activeDatabase {
                await mainCoordinator?.switchDatabase(to: database)
            }
            if schema != sessionSchema {
                await mainCoordinator?.switchSchema(to: schema)
            }
        }
    }

    private func refreshDatabase(_ database: String) {
        if supportsSchemaLevel {
            Task { await service.refreshSchemas(connectionId: connectionId, database: database) }
        } else {
            Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: nil) }
        }
    }

    private func refreshObjects(database: String, schema: String?) {
        Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: schema) }
    }

    private func refreshContainers(_ targets: [DatabaseContainerRef]) {
        for target in targets {
            switch target.kind {
            case .database: refreshDatabase(target.database)
            case .schema: refreshObjects(database: target.database, schema: target.schema)
            }
        }
    }

    /// Every visible row is handed the same context and the same action set, and both are pure
    /// functions of the inputs `update(from:)` already tracks, so they are built once per refresh
    /// instead of once per row. Rebuilding them in `viewFor` allocated a fresh set of closures for
    /// every row the outline drew, on every reload and every scroll.
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
                kind == .table
                    ? PluginManager.shared.tableEntityName(for: databaseType)
                    : kind.pluralDisplayName
            },
            isFavorite: { [weak self] ref in
                guard let self else { return false }
                return self.favoriteTables.contains(self.favoriteEntry(for: ref))
            }
        )
    }

    private func makeRowActions() -> DatabaseTreeRowActions {
        DatabaseTreeRowActions(
            coordinator: mainCoordinator,
            isReadOnly: mainCoordinator?.safeModeLevel.blocksAllWrites ?? false,
            selectedTables: { [weak self] in Set((self?.selectedRefs() ?? []).map(\.table)) },
            selectedContainers: { [weak self] in self?.selectedContainerRefs() ?? [] },
            activate: { [weak self] ref in await self?.activate(ref) },
            setActiveDatabase: { [weak self] in self?.setActiveDatabase($0) },
            setActiveSchema: { [weak self] database, schema in self?.setActiveSchema(database: database, schema: schema) },
            refreshContainers: { [weak self] in self?.refreshContainers($0) },
            exportContainers: { [weak self] in self?.mainCoordinator?.openExportDialog(containers: $0) },
            dropContainers: { [weak self] in self?.mainCoordinator?.requestContainerDrop($0) },
            showRoutineDDL: { [weak self] routine in self?.mainCoordinator?.showRoutineDDL(routine) },
            batchToggleTruncate: { [weak self] in self?.viewModel?.batchToggleTruncate(tableNames: $0) },
            batchToggleDelete: { [weak self] in self?.viewModel?.batchToggleDelete(tableNames: $0) },
            removeRecent: { [weak self] ref in
                self?.sidebarState?.removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
            },
            clearRecents: { [weak self] in
                self?.sidebarState?.clearRecentTables(inDatabase: self?.mainCoordinator?.browseDatabaseName)
            },
            showAllTablesMetadata: { [weak self] in self?.mainCoordinator?.showAllTablesMetadata() },
            refreshObjectKind: { [weak self] in self?.refreshObjectKind($0) },
            refreshHierarchicalSchema: { [weak self] in self?.reloadHierarchicalSchemaTables($0) },
            openRedisKey: { [weak self] key, keyType in self?.mainCoordinator?.openRedisKey(key, keyType: keyType) },
            toggleFavorite: { [weak self] ref in self?.toggleFavorite(ref) }
        )
    }

    /// A namespace rescopes the browse pattern and a key opens; neither goes through the
    /// double-click window a table open needs, because there is no preview tab to promote.
    private func openRedis(_ node: RedisKeyNode) {
        switch node {
        case .namespace(_, let fullPrefix, _, _):
            mainCoordinator?.browseRedisNamespace(fullPrefix)
        case .key(_, let fullKey, let keyType):
            mainCoordinator?.openRedisKey(fullKey, keyType: keyType)
        }
    }

    private func refreshObjectKind(_ kind: SidebarObjectKind) {
        guard let mainCoordinator else { return }
        switch kind {
        case .procedure: Task { await mainCoordinator.refreshProcedures() }
        case .function: Task { await mainCoordinator.refreshFunctions() }
        case .table, .view, .materializedView, .foreignTable: Task { await mainCoordinator.refreshTables() }
        }
    }

    private func reloadHierarchicalSchemaTables(_ schema: String) {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        let connectionId = connectionId
        Task { await schemaService.reloadSchemaTables(connectionId: connectionId, schema: schema, driver: driver) }
    }

    /// Selection already opened whatever was clicked, so the second click is only ever a
    /// disclosure gesture.
    @objc
    func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode,
              node.isExpandable else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }
}

extension DatabaseTreeOutlineCoordinator: DatabaseTreeSelectionClearing {
    /// Deselecting runs the normal delegate path, which publishes the now empty selection, so the
    /// Table menu and the outline agree without a second write.
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

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.isExpandable ?? false
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DatabaseTreeCellView
            ?? makeCell()
        cell.configure(node: node, context: rowContext, actions: rowActions)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? DatabaseTreeNode else { return false }
        return DatabaseTreeSelection.isSelectable(node.kind)
    }

    /// Hands the section headers to AppKit. In `.sourceList` a group row is drawn at its own
    /// height with its own background and collapse control, and its children are laid out at the
    /// depth the group itself sits at rather than one level in. That last part is what makes a
    /// table under "Tables" line up with a database, the way a package lines up with the project
    /// in Xcode's navigator.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.isSectionHeader ?? false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        return DatabaseTreeTypeSelect.matchString(for: node.kind)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        triggerLoad(for: node)
        if isRecordingExpansion { recordExpansion(node, expanded: true) }
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if isRecordingExpansion { recordExpansion(node, expanded: false) }
    }

    /// A filtered tree discloses whatever matches, so while the field has text the disclosure on
    /// screen is the search's, not the user's. A gesture against it is an edit of the search view
    /// and must stay out of the saved state: recording it made the row spring back open on the next
    /// keystroke and then, once the filter cleared, took the layout the user had built with it.
    private var isRecordingExpansion: Bool {
        !isApplyingExpansion && searchText.isEmpty
    }

    /// Selection drives the content, which is how a source list works: the navigator picks, the
    /// detail follows. Both the mouse and the keyboard land here, so there is one entry point.
    ///
    /// This deliberately does not use `NSTableView.action`. AppKit sends the action on mouse up,
    /// which is a whole gesture later than the selection the user already sees.
    ///
    /// Nothing is published when a single table was added, because the open publishes it once the
    /// tab is already that table. Publishing here would hand the same table to the window's
    /// navigation observer first and open it twice.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading else { return }
        let nodes = selectedNodes()
        lastSelectedNodeIds = nodes.map(\.id)
        let refs = Set(DatabaseTreeSelection.tableRefs(of: nodes))
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: nodes, previousRefs: lastSelection, newRefs: refs
        )
        if let target {
            /// Only a repeating key is a burst to wait out. A discrete press is the whole gesture
            /// and opens now, the way a click does.
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

    /// A held arrow key is one gesture, not one open per row it travels over, so a repeating key
    /// waits out `NSEvent.keyRepeatInterval` and each new selection cancels the pending one. The
    /// burst collapses to the row the user stopped on. Without it, arrowing down a schema ran a
    /// query and opened a tab for every row in between.
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
