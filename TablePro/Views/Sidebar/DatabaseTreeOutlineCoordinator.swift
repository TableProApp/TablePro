//
//  DatabaseTreeOutlineCoordinator.swift
//  TablePro
//

import AppKit
import Observation
import TableProPluginKit

@MainActor
final class DatabaseTreeOutlineCoordinator: NSObject {
    private weak var outlineView: NSOutlineView?
    private let service = DatabaseTreeMetadataService.shared
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("DatabaseTreeCell")

    private var connectionId = UUID()
    private var databaseType: DatabaseType = .mysql
    private weak var mainCoordinator: MainContentCoordinator?
    private var windowState: WindowSidebarState?
    private var sidebarState: SharedSidebarState?
    private weak var viewModel: SidebarViewModel?
    private var searchText = ""
    private var connectionToken = ""
    private var activeDatabase: String?
    private var activeSchema: String?
    private var pendingTruncates: Set<String> = []
    private var pendingDeletes: Set<String> = []

    private var nodeCache: [String: DatabaseTreeNode] = [:]
    private var childrenCache: [String: [DatabaseTreeNode]] = [:]
    private var lastSelection: Set<DatabaseTreeTableRef> = []
    private var pendingSingleClickWork: DispatchWorkItem?
    private var isApplyingExpansion = false
    private var isSyncingSelection = false
    private var isReloading = false
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var observationGeneration = 0

    private var supportsSchemaLevel: Bool {
        PluginManager.shared.databaseGroupingStrategy(for: databaseType) == .bySchema
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    // MARK: - Attach / input

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
    }

    func update(from view: DatabaseTreeOutlineView) {
        connectionId = view.connectionId
        databaseType = view.databaseType
        mainCoordinator = view.coordinator
        windowState = view.windowState
        sidebarState = view.sidebarState
        viewModel = view.viewModel

        let activeChanged = activeDatabase != view.activeDatabase || activeSchema != view.activeSchema
        let changed = searchText != view.searchText
            || connectionToken != view.connectionToken
            || activeChanged
            || pendingTruncates != view.pendingTruncates
            || pendingDeletes != view.pendingDeletes

        searchText = view.searchText
        connectionToken = view.connectionToken
        activeDatabase = view.activeDatabase
        activeSchema = view.activeSchema
        pendingTruncates = view.pendingTruncates
        pendingDeletes = view.pendingDeletes

        if !hasRenderedOnce || activeChanged {
            persistActiveExpansion()
        }

        if !hasRenderedOnce {
            hasRenderedOnce = true
            refresh()
        } else if changed {
            refresh()
        }
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
        for node in nodeCache.values {
            switch node.kind {
            case .database(let metadata):
                _ = service.schemaListState(connectionId: connectionId, database: metadata.name)
                _ = service.tablesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
                _ = service.routinesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
            case .schema(let database, let schema):
                _ = service.tablesLoadState(connectionId: connectionId, database: database, schema: schema)
                _ = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)
            case .table, .routine, .status:
                break
            }
        }
    }

    private func refresh() {
        guard let outlineView else { return }
        isReloading = true
        childrenCache.removeAll()
        outlineView.reloadData()
        applyDesiredExpansion()
        syncSelectionToModel()
        isReloading = false
        beginObserving()
    }

    // MARK: - Node building

    private func node(id: String, kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        if let existing = nodeCache[id] {
            existing.kind = kind
            return existing
        }
        let created = DatabaseTreeNode(id: id, kind: kind)
        nodeCache[id] = created
        return created
    }

    private func resolvedChildren(of item: Any?) -> [DatabaseTreeNode] {
        let key = (item as? DatabaseTreeNode)?.id ?? ""
        if let cached = childrenCache[key] { return cached }
        let built = buildChildren(of: item as? DatabaseTreeNode)
        childrenCache[key] = built
        return built
    }

    private func buildChildren(of node: DatabaseTreeNode?) -> [DatabaseTreeNode] {
        guard let node else { return rootNodes() }
        switch node.kind {
        case .database(let metadata):
            return supportsSchemaLevel
                ? schemaNodes(database: metadata.name)
                : objectNodes(database: metadata.name, schema: nil)
        case .schema(let database, let schema):
            return objectNodes(database: database, schema: schema)
        case .table, .routine, .status:
            return []
        }
    }

    private func rootNodes() -> [DatabaseTreeNode] {
        let visible = DatabaseTreeVisibility.visible(
            databases: service.databases(for: connectionId),
            selected: sidebarState?.databaseFilterSelected ?? []
        )
        let matched = searchText.isEmpty ? visible : visible.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        return matched
            .filter { seen.insert($0.id).inserted }
            .map { node(id: DatabaseTreeNode.databaseId($0.name), kind: .database($0)) }
    }

    private func schemaNodes(database: String) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.databaseId(database)
        switch service.schemaListState(connectionId: connectionId, database: database) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let schemas):
            let visible = DatabaseTreeFilter.visibleSchemas(
                schemas,
                systemSchemas: systemSchemas,
                searchText: searchText,
                contentMatches: { schemaContentMatchesSearch(database: database, schema: $0) }
            )
            if visible.isEmpty { return [statusNode(parentId: parentId, status: .empty)] }
            return visible.map {
                node(id: DatabaseTreeNode.schemaId(database: database, schema: $0), kind: .schema(database: database, schema: $0))
            }
        }
    }

    private func objectNodes(database: String, schema: String?) -> [DatabaseTreeNode] {
        let parentId = schema.map { DatabaseTreeNode.schemaId(database: database, schema: $0) }
            ?? DatabaseTreeNode.databaseId(database)
        switch service.tablesLoadState(connectionId: connectionId, database: database, schema: schema) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded:
            return loadedObjectNodes(database: database, schema: schema, parentId: parentId)
        }
    }

    private func loadedObjectNodes(database: String, schema: String?, parentId: String) -> [DatabaseTreeNode] {
        let tables = DatabaseTreeFilter.filteredTables(
            service.tables(connectionId: connectionId, database: database, schema: schema), searchText: searchText
        )
        let routines = DatabaseTreeFilter.filteredRoutines(
            service.routines(connectionId: connectionId, database: database, schema: schema), searchText: searchText
        )
        let routinesState = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)

        guard !tables.isEmpty || !routines.isEmpty else {
            switch routinesState {
            case .failed(let message): return [statusNode(parentId: parentId, status: .error(message))]
            case .loaded: return [statusNode(parentId: parentId, status: .empty)]
            case .idle, .loading: return [statusNode(parentId: parentId, status: .loading)]
            }
        }

        var nodes: [DatabaseTreeNode] = tables.map { table in
            let ref = DatabaseTreeTableRef(database: database, schema: schema, table: table)
            return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
        }
        nodes += routines.map { routine in
            let ref = DatabaseTreeRoutineRef(database: database, schema: schema, routine: routine)
            return node(id: DatabaseTreeNode.routineId(ref), kind: .routine(ref))
        }
        if case .failed(let message) = routinesState {
            nodes.append(statusNode(parentId: parentId, status: .error(message)))
        }
        return nodes
    }

    private func statusNode(parentId: String, status: DatabaseTreeNode.Status) -> DatabaseTreeNode {
        node(id: DatabaseTreeNode.statusId(parentId: parentId, status: status), kind: .status(status))
    }

    // MARK: - Search

    private func databaseMatchesSearch(_ metadata: DatabaseMetadata) -> Bool {
        if DatabaseTreeFilter.matches(searchText, metadata.name) { return true }
        if case .loaded(let schemas) = service.schemaListState(connectionId: connectionId, database: metadata.name) {
            if schemas.contains(where: { DatabaseTreeFilter.matches(searchText, $0) }) { return true }
            for schema in schemas where schemaContentMatchesSearch(database: metadata.name, schema: schema) {
                return true
            }
        }
        return schemaContentMatchesSearch(database: metadata.name, schema: nil)
    }

    private func schemaContentMatchesSearch(database: String, schema: String?) -> Bool {
        if let schema, DatabaseTreeFilter.matches(searchText, schema) { return true }
        let tables = service.tables(connectionId: connectionId, database: database, schema: schema)
        if tables.contains(where: { DatabaseTreeFilter.matches(searchText, $0.name) }) { return true }
        let routines = service.routines(connectionId: connectionId, database: database, schema: schema)
        return routines.contains { DatabaseTreeFilter.matches(searchText, $0.name) }
    }

    // MARK: - Expansion

    private func applyDesiredExpansion() {
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        let searching = !searchText.isEmpty
        for databaseNode in resolvedChildren(of: nil) {
            guard case .database(let metadata) = databaseNode.kind else { continue }
            let want = searching
                ? databaseMatchesSearch(metadata)
                : windowState?.expandedTreeDatabases.contains(metadata.name) ?? false
            setExpanded(databaseNode, want)
            guard outlineView.isItemExpanded(databaseNode) else { continue }
            triggerLoad(for: databaseNode)
            guard supportsSchemaLevel else { continue }
            for schemaNode in resolvedChildren(of: databaseNode) {
                guard case .schema(let database, let schema) = schemaNode.kind else { continue }
                let wantSchema = searching
                    ? DatabaseTreeFilter.matches(searchText, schema) || schemaContentMatchesSearch(database: database, schema: schema)
                    : windowState?.expandedTreeDatabaseSchemas.contains(DatabaseSchemaKey(database: database, schema: schema)) ?? false
                setExpanded(schemaNode, wantSchema)
                if outlineView.isItemExpanded(schemaNode) {
                    triggerLoad(for: schemaNode)
                }
            }
        }
    }

    private func setExpanded(_ node: DatabaseTreeNode, _ expanded: Bool) {
        guard let outlineView else { return }
        if expanded, !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        } else if !expanded, outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        }
    }

    private func recordExpansion(_ node: DatabaseTreeNode, expanded: Bool) {
        switch node.kind {
        case .database(let metadata):
            if expanded {
                windowState?.expandedTreeDatabases.insert(metadata.name)
            } else {
                windowState?.expandedTreeDatabases.remove(metadata.name)
            }
        case .schema(let database, let schema):
            let key = DatabaseSchemaKey(database: database, schema: schema)
            if expanded {
                windowState?.expandedTreeDatabaseSchemas.insert(key)
            } else {
                windowState?.expandedTreeDatabaseSchemas.remove(key)
            }
        case .table, .routine, .status:
            break
        }
    }

    private func triggerLoad(for node: DatabaseTreeNode) {
        switch node.kind {
        case .database(let metadata):
            if supportsSchemaLevel {
                if isIdle(service.schemaListState(connectionId: connectionId, database: metadata.name)) {
                    Task { await service.loadSchemas(connectionId: connectionId, database: metadata.name) }
                }
            } else {
                loadObjects(database: metadata.name, schema: nil)
            }
        case .schema(let database, let schema):
            loadObjects(database: database, schema: schema)
        case .table, .routine, .status:
            break
        }
    }

    private func loadObjects(database: String, schema: String?) {
        if isIdle(service.tablesLoadState(connectionId: connectionId, database: database, schema: schema)) {
            Task { await service.loadTables(connectionId: connectionId, database: database, schema: schema) }
        }
        if isIdle(service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)) {
            Task { await service.loadRoutines(connectionId: connectionId, database: database, schema: schema) }
        }
    }

    private func isIdle<Value>(_ state: MetadataLoadState<Value>) -> Bool {
        if case .idle = state { return true }
        return false
    }

    // MARK: - Selection / open

    private func selectedRefs() -> [DatabaseTreeTableRef] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? DatabaseTreeNode)?.tableRef
        }
    }

    private func syncSelectionToModel() {
        guard let outlineView else { return }
        let rows = lastSelection.compactMap { ref -> Int? in
            guard let node = nodeCache[DatabaseTreeNode.tableId(ref)] else { return nil }
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        }
        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        isSyncingSelection = false
    }

    private func open(_ ref: DatabaseTreeTableRef, activateGridFocus: Bool, forceNewWindowTab: Bool = false) {
        Task { @MainActor in
            await activate(ref)
            mainCoordinator?.openTableTab(ref.table, activateGridFocus: activateGridFocus, forceNewWindowTab: forceNewWindowTab)
        }
    }

    private func activate(_ ref: DatabaseTreeTableRef) async {
        if ref.database != activeDatabase {
            await mainCoordinator?.switchDatabase(to: ref.database)
        }
        if let schema = ref.schema,
           schema != mainCoordinator?.toolbarState.currentSchema,
           PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
            await mainCoordinator?.switchSchema(to: schema)
        }
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
            if schema != mainCoordinator?.toolbarState.currentSchema {
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

    private func rowContext() -> DatabaseTreeRowContext {
        DatabaseTreeRowContext(
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            systemSchemas: systemSchemas,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes
        )
    }

    private func rowActions() -> DatabaseTreeRowActions {
        DatabaseTreeRowActions(
            coordinator: mainCoordinator,
            isReadOnly: mainCoordinator?.safeModeLevel.blocksAllWrites ?? false,
            selectedTables: { [weak self] in Set((self?.selectedRefs() ?? []).map(\.table)) },
            activate: { [weak self] ref in await self?.activate(ref) },
            setActiveDatabase: { [weak self] in self?.setActiveDatabase($0) },
            setActiveSchema: { [weak self] database, schema in self?.setActiveSchema(database: database, schema: schema) },
            refreshDatabase: { [weak self] in self?.refreshDatabase($0) },
            refreshObjects: { [weak self] database, schema in self?.refreshObjects(database: database, schema: schema) },
            showRoutineDDL: { [weak self] routine in self?.mainCoordinator?.showRoutineDDL(routine) },
            batchToggleTruncate: { [weak self] in self?.viewModel?.batchToggleTruncate(tableNames: $0) },
            batchToggleDelete: { [weak self] in self?.viewModel?.batchToggleDelete(tableNames: $0) }
        )
    }

    @objc
    func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode else { return }
        if let ref = node.tableRef {
            pendingSingleClickWork?.cancel()
            pendingSingleClickWork = nil
            open(ref, activateGridFocus: true, forceNewWindowTab: true)
            return
        }
        guard node.isExpandable else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
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
        cell.configure(node: node, context: rowContext(), actions: rowActions())
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.tableRef != nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        triggerLoad(for: node)
        if !isApplyingExpansion { recordExpansion(node, expanded: true) }
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if !isApplyingExpansion { recordExpansion(node, expanded: false) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading else { return }
        let refs = Set(selectedRefs())
        if let added = SelectionDelta.singleAddition(old: lastSelection, new: refs) {
            if isKeyboardDrivenSelection {
                pendingSingleClickWork?.cancel()
                pendingSingleClickWork = nil
                open(added, activateGridFocus: false)
            } else {
                scheduleSingleClickOpen(added)
            }
        }
        lastSelection = refs
    }

    private var isKeyboardDrivenSelection: Bool {
        guard let outlineView, outlineView.window?.firstResponder === outlineView else { return false }
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp:
            return true
        default:
            return false
        }
    }

    private func scheduleSingleClickOpen(_ ref: DatabaseTreeTableRef) {
        pendingSingleClickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.open(ref, activateGridFocus: false)
        }
        pendingSingleClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    private func makeCell() -> DatabaseTreeCellView {
        let cell = DatabaseTreeCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}
