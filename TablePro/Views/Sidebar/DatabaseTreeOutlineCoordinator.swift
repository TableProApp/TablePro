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
    private var showRecentTables = true

    private var nodeCache: [String: DatabaseTreeNode] = [:]
    private var childrenCache: [String: [DatabaseTreeNode]] = [:]
    private var lastSelection: Set<DatabaseTreeTableRef> = []
    private var lastSelectedNodeIds: [String] = []
    private var publishedTables: Set<TableInfo> = []
    private var pendingOpenWork: DispatchWorkItem?
    private var isApplyingExpansion = false
    private var isSyncingSelection = false
    private var isReloading = false
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var observationGeneration = 0

    private let schemaService = SchemaService.shared
    private var favoriteTables: Set<FavoriteTablesStorage.FavoriteEntry> = []
    private var favoritesObserver: (any NSObjectProtocol)?

    private var supportsSchemaLevel: Bool {
        PluginManager.shared.databaseGroupingStrategy(for: databaseType) == .bySchema
    }

    private var systemSchemas: Set<String> {
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
        let changed = searchText != view.searchText
            || connectionToken != view.connectionToken
            || activeChanged
            || pendingTruncates != view.pendingTruncates
            || pendingDeletes != view.pendingDeletes
            || showRecentTables != view.showRecentTables

        searchText = view.searchText
        connectionToken = view.connectionToken
        activeDatabase = view.activeDatabase
        activeSchema = view.activeSchema
        pendingTruncates = view.pendingTruncates
        pendingDeletes = view.pendingDeletes
        showRecentTables = view.showRecentTables

        if !hasRenderedOnce || activeChanged {
            persistActiveExpansion()
        }

        if !hasRenderedOnce {
            hasRenderedOnce = true
            refresh()
        } else if changed {
            refresh()
        } else {
            syncSelectionToModel()
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
        _ = sidebarState?.recentTables
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
        let context = rowContext()
        let actions = rowActions()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? DatabaseTreeNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DatabaseTreeCellView
            else { continue }
            cell.configure(node: node, context: context, actions: actions)
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
        case .recentSection:
            return recentTableRefs().map {
                self.node(id: DatabaseTreeNode.recentTableId($0), kind: .recentTable($0))
            }
        case .database(let metadata):
            return supportsSchemaLevel
                ? schemaNodes(database: metadata.name)
                : objectNodes(database: metadata.name, schema: nil)
        case .schema(let database, let schema):
            return objectNodes(database: database, schema: schema)
        case .table(let ref):
            return ref.table.type == .partitionedTable ? partitionNodes(of: ref) : []
        case .objectKindSection(let kind):
            return flatObjectNodes(for: kind)
        case .hierarchicalSchemaSection(let schema):
            return hierarchicalTableNodes(schema: schema)
        case .redisKeysSection:
            return redisChildren(of: nil)
        case .redisNode(let redisNode):
            return redisChildren(of: redisNode)
        case .recentTable, .routine, .status:
            return []
        }
    }

    private func partitionNodes(of ref: DatabaseTreeTableRef) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.tableId(ref)
        let state = service.partitionsLoadState(
            connectionId: connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
        )
        switch state {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let partitions):
            if partitions.isEmpty { return [statusNode(parentId: parentId, status: .empty)] }
            return partitions.map { partition in
                let childRef = DatabaseTreeTableRef(database: ref.database, schema: ref.schema, table: partition)
                return node(id: DatabaseTreeNode.tableId(childRef), kind: .table(childRef))
            }
        }
    }

    /// Which shape the root takes. The three sidebar modes used to be three views; they are one
    /// outline now and this is the only thing that still differs between them.
    private var rootShape: SidebarRootShape {
        SidebarRootShapeResolver.resolve(
            groupingStrategy: PluginManager.shared.databaseGroupingStrategy(for: databaseType),
            sidebarLayout: sidebarState?.sidebarLayout ?? .flat,
            supportsDatabaseTree: PluginManager.shared.supportsDatabaseTree(for: databaseType)
        )
    }

    private func rootNodes() -> [DatabaseTreeNode] {
        switch rootShape {
        case .databaseTree: return databaseTreeRootNodes()
        case .flat: return flatRootNodes()
        case .hierarchicalSchema: return hierarchicalRootNodes()
        }
    }

    private func databaseTreeRootNodes() -> [DatabaseTreeNode] {
        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs().isEmpty {
            nodes.append(node(id: DatabaseTreeNode.recentSectionId, kind: .recentSection))
        }
        let visible = DatabaseTreeVisibility.visible(
            databases: service.databases(for: connectionId),
            selected: sidebarState?.databaseFilterSelected ?? [],
            activeDatabase: mainCoordinator?.browseDatabaseName ?? activeDatabase
        )
        let matched = searchText.isEmpty ? visible : visible.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        nodes += matched
            .filter { seen.insert($0.id).inserted }
            .map { node(id: DatabaseTreeNode.databaseId($0.name), kind: .database($0)) }
        return nodes
    }

    private var browsingDatabase: String? {
        let name = mainCoordinator?.browseDatabaseName ?? activeDatabase ?? ""
        return name.isEmpty ? nil : name
    }

    private func flatRootNodes() -> [DatabaseTreeNode] {
        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs().isEmpty {
            nodes.append(node(id: DatabaseTreeNode.recentSectionId, kind: .recentSection))
        }
        nodes += visibleObjectKinds().map {
            node(id: DatabaseTreeNode.objectKindSectionId($0), kind: .objectKindSection($0))
        }
        if sidebarState?.redisKeyTreeViewModel != nil {
            nodes.append(node(id: DatabaseTreeNode.redisKeysSectionId, kind: .redisKeysSection))
        }
        return nodes
    }

    /// The section list is the same rule the flat list used, so a kind that was hidden before stays
    /// hidden: Tables always shows, anything else needs both the capability and something in it.
    private func visibleObjectKinds() -> [SidebarObjectKind] {
        guard let viewModel else { return [] }
        let capabilities = viewModel.capabilities(for: connectionId)
        return SidebarObjectKind.allCases.filter { kind in
            viewModel.sectionShouldRender(
                kind: kind,
                itemCount: flatItemCount(for: kind),
                capabilities: capabilities
            )
        }
    }

    private func flatItemCount(for kind: SidebarObjectKind) -> Int {
        guard let viewModel else { return 0 }
        if kind.isRoutine {
            return viewModel.filteredRoutines(of: kind, from: schemaService.routines(for: connectionId)).count
        }
        return viewModel.filteredTables(of: kind, from: schemaService.tables(for: connectionId)).count
    }

    private func flatObjectNodes(for kind: SidebarObjectKind) -> [DatabaseTreeNode] {
        guard let viewModel else { return [] }
        let database = browsingDatabase ?? ""
        if kind.isRoutine {
            return viewModel.filteredRoutines(of: kind, from: schemaService.routines(for: connectionId))
                .map { routine in
                    let ref = DatabaseTreeRoutineRef(database: database, schema: routine.schema, routine: routine)
                    return node(id: DatabaseTreeNode.routineId(ref), kind: .routine(ref))
                }
        }
        return viewModel.filteredTables(of: kind, from: schemaService.tables(for: connectionId))
            .map { table in
                let ref = DatabaseTreeTableRef(database: database, schema: table.schema, table: table)
                return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
            }
    }

    private func hierarchicalRootNodes() -> [DatabaseTreeNode] {
        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs().isEmpty {
            nodes.append(node(id: DatabaseTreeNode.recentSectionId, kind: .recentSection))
        }
        let hidden = systemSchemas
        nodes += schemaService.schemas(for: connectionId)
            .filter { !hidden.contains($0) }
            .filter { searchText.isEmpty || hierarchicalSchemaMatches($0) }
            .map {
                node(id: DatabaseTreeNode.hierarchicalSchemaSectionId($0), kind: .hierarchicalSchemaSection(schema: $0))
            }
        return nodes
    }

    private func hierarchicalSchemaMatches(_ schema: String) -> Bool {
        DatabaseTreeFilter.hierarchicalSchemaIsVisible(
            schema,
            searchText: searchText,
            isLoaded: isSchemaLoaded(schema),
            tables: schemaService.tables(for: connectionId, schema: schema)
        )
    }

    private func isSchemaLoaded(_ schema: String) -> Bool {
        if case .loaded = schemaService.schemaState(for: connectionId, schema: schema) { return true }
        return false
    }

    private func hierarchicalTableNodes(schema: String) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.hierarchicalSchemaSectionId(schema)
        switch schemaService.schemaState(for: connectionId, schema: schema) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded:
            let tables = DatabaseTreeFilter.hierarchicalTables(
                schemaService.tables(for: connectionId, schema: schema), schema: schema, searchText: searchText
            )
            guard !tables.isEmpty else { return [statusNode(parentId: parentId, status: .empty)] }
            let database = browsingDatabase ?? ""
            return tables.map { table in
                let ref = DatabaseTreeTableRef(database: database, schema: schema, table: table)
                return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
            }
        }
    }

    private func redisChildren(of parent: RedisKeyNode?) -> [DatabaseTreeNode] {
        guard let keyTree = sidebarState?.redisKeyTreeViewModel else { return [] }
        if let parent {
            guard case .namespace(_, _, let children, _) = parent else { return [] }
            return children.map { node(id: DatabaseTreeNode.redisNodeId($0), kind: .redisNode($0)) }
        }
        if keyTree.isLoading {
            return [statusNode(parentId: DatabaseTreeNode.redisKeysSectionId, status: .loading)]
        }
        let roots = keyTree.displayNodes(searchText: searchText)
        guard !roots.isEmpty else {
            return [statusNode(parentId: DatabaseTreeNode.redisKeysSectionId, status: .empty)]
        }
        var nodes = roots.map { node(id: DatabaseTreeNode.redisNodeId($0), kind: .redisNode($0)) }
        if keyTree.isTruncated {
            nodes.append(
                statusNode(
                    parentId: DatabaseTreeNode.redisKeysSectionId,
                    status: .truncated(RedisKeyTreeTruncation.message(limit: RedisKeyTreeViewModel.maxKeys))
                )
            )
        }
        return nodes
    }

    private func recentTableRefs() -> [DatabaseTreeTableRef] {
        guard let sidebarState, showRecentTables else { return [] }
        let database = mainCoordinator?.browseDatabaseName ?? activeDatabase ?? ""
        return sidebarState.recentEntries(inDatabase: database).compactMap { entry -> DatabaseTreeTableRef? in
            if !searchText.isEmpty, !DatabaseTreeFilter.matches(searchText, entry.name) { return nil }
            return DatabaseTreeTableRef(database: database, schema: entry.schema, table: entry.tableInfo)
        }
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
        for rootNode in resolvedChildren(of: nil) where rootNode.id == DatabaseTreeNode.recentSectionId {
            setExpanded(rootNode, searching || (viewModel?.isRecentsExpanded ?? true))
        }
        for sectionNode in resolvedChildren(of: nil) {
            switch sectionNode.kind {
            case .objectKindSection(let kind):
                let hasMatches = flatItemCount(for: kind) > 0
                setExpanded(sectionNode, viewModel?.effectiveExpanded(kind: kind, hasMatches: hasMatches) ?? true)
            case .redisKeysSection:
                setExpanded(sectionNode, searching || (viewModel?.isRedisKeysExpanded ?? true))
            case .hierarchicalSchemaSection(let schema):
                let want = searching
                    ? hierarchicalSchemaMatches(schema)
                    : windowState?.expandedTreeSchemas.contains(schema) ?? false
                setExpanded(sectionNode, want)
                if outlineView.isItemExpanded(sectionNode) { triggerLoad(for: sectionNode) }
            default:
                break
            }
        }
        for databaseNode in resolvedChildren(of: nil) {
            guard case .database(let metadata) = databaseNode.kind else { continue }
            let want = searching
                ? databaseMatchesSearch(metadata)
                : windowState?.expandedTreeDatabases.contains(metadata.name) ?? false
            setExpanded(databaseNode, want)
            guard outlineView.isItemExpanded(databaseNode) else { continue }
            triggerLoad(for: databaseNode)
            guard supportsSchemaLevel else {
                restorePartitionExpansion(under: databaseNode)
                continue
            }
            for schemaNode in resolvedChildren(of: databaseNode) {
                guard case .schema(let database, let schema) = schemaNode.kind else { continue }
                let wantSchema = searching
                    ? DatabaseTreeFilter.matches(searchText, schema) || schemaContentMatchesSearch(database: database, schema: schema)
                    : windowState?.expandedTreeDatabaseSchemas.contains(DatabaseSchemaKey(database: database, schema: schema)) ?? false
                setExpanded(schemaNode, wantSchema)
                if outlineView.isItemExpanded(schemaNode) {
                    triggerLoad(for: schemaNode)
                    restorePartitionExpansion(under: schemaNode)
                }
            }
        }
    }

    private func restorePartitionExpansion(under parent: DatabaseTreeNode) {
        guard searchText.isEmpty, let outlineView, let windowState else { return }
        for tableNode in resolvedChildren(of: parent) {
            guard case .table(let ref) = tableNode.kind, ref.table.type == .partitionedTable else { continue }
            let key = DatabaseTableKey(database: ref.database, schema: ref.schema, table: ref.table.name)
            guard windowState.expandedTreeTables.contains(key) else { continue }
            setExpanded(tableNode, true)
            guard outlineView.isItemExpanded(tableNode) else { continue }
            triggerLoad(for: tableNode)
            restorePartitionExpansion(under: tableNode)
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
        case .recentSection:
            viewModel?.isRecentsExpanded = expanded
        case .objectKindSection(let kind):
            viewModel?.expanded[kind] = expanded
        case .redisKeysSection:
            viewModel?.isRedisKeysExpanded = expanded
        case .hierarchicalSchemaSection(let schema):
            if expanded {
                windowState?.expandedTreeSchemas.insert(schema)
            } else {
                windowState?.expandedTreeSchemas.remove(schema)
            }
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
        case .table(let ref):
            let key = DatabaseTableKey(database: ref.database, schema: ref.schema, table: ref.table.name)
            if expanded {
                windowState?.expandedTreeTables.insert(key)
            } else {
                windowState?.expandedTreeTables.remove(key)
            }
        case .recentTable, .routine, .status, .redisNode:
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
                loadExternalSchemaNames(database: metadata.name)
            } else {
                loadObjects(database: metadata.name, schema: nil)
            }
        case .schema(let database, let schema):
            loadObjects(database: database, schema: schema)
        case .table(let ref):
            loadPartitions(ref)
        case .hierarchicalSchemaSection(let schema):
            loadHierarchicalSchemaTables(schema)
        case .recentSection, .recentTable, .routine, .status,
             .objectKindSection, .redisKeysSection, .redisNode:
            break
        }
    }

    private func loadHierarchicalSchemaTables(_ schema: String) {
        guard case .idle = schemaService.schemaState(for: connectionId, schema: schema),
              let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        let connectionId = connectionId
        Task { await schemaService.loadSchemaTables(connectionId: connectionId, schema: schema, driver: driver) }
    }

    private func loadExternalSchemaNames(database: String) {
        guard let session = DatabaseManager.shared.session(for: connectionId),
              DatabaseManager.shared.browseDatabaseName(for: session.connection) == database,
              let driver = DatabaseManager.shared.driver(for: connectionId)
        else { return }
        let connectionId = connectionId
        Task {
            await ExternalSchemaTracker.shared.load(
                connectionId: connectionId,
                database: database,
                driver: driver
            )
        }
    }

    private func loadPartitions(_ ref: DatabaseTreeTableRef) {
        guard ref.table.type == .partitionedTable else { return }
        let state = service.partitionsLoadState(
            connectionId: connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
        )
        guard isIdle(state) else { return }
        Task {
            await service.loadPartitions(
                connectionId: connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
            )
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

    private func open(_ ref: DatabaseTreeTableRef, activateGridFocus: Bool, forceNewTab: Bool = false) {
        Task { @MainActor in
            await activate(ref)
            mainCoordinator?.openTableTab(
                ref.table,
                schema: ref.schema,
                activateGridFocus: activateGridFocus,
                forceNewTab: forceNewTab
            )
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

    private func rowContext() -> DatabaseTreeRowContext {
        DatabaseTreeRowContext(
            databaseType: databaseType,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            systemSchemas: systemSchemas,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
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

    private func rowActions() -> DatabaseTreeRowActions {
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
        cell.configure(node: node, context: rowContext(), actions: rowActions())
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
        if !isApplyingExpansion { recordExpansion(node, expanded: true) }
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if !isApplyingExpansion { recordExpansion(node, expanded: false) }
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
        if let added = SelectionDelta.singleAddition(old: lastSelection, new: refs) {
            /// A held arrow key is one gesture, so the keyboard waits it out. A click is already
            /// the whole gesture and opens now.
            if isKeyboardDrivenSelection {
                scheduleOpen(added, after: NSEvent.keyRepeatInterval)
            } else {
                pendingOpenWork?.cancel()
                pendingOpenWork = nil
                open(added, activateGridFocus: false)
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

    private var isKeyboardDrivenSelection: Bool {
        guard let outlineView, outlineView.window?.firstResponder === outlineView else { return false }
        guard let event = NSApp.currentEvent else { return false }
        return DatabaseTreeTypeSelect.isArrowNavigation(event)
    }

    /// A held arrow key is one gesture, not one open per row it travels over, so a keyboard open
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
