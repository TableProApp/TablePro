//
//  DatabaseTreeOutlineCoordinator+Nodes.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// Turning the connection's metadata into the rows the outline draws. The three sidebar shapes
/// differ only in what this builds at the root; everything below the root is shared.
extension DatabaseTreeOutlineCoordinator {
    private func node(id: String, kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        if let existing = nodeCache[id] {
            existing.kind = kind
            return existing
        }
        let created = DatabaseTreeNode(id: id, kind: kind)
        nodeCache[id] = created
        return created
    }

    internal func resolvedChildren(of item: Any?) -> [DatabaseTreeNode] {
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
        case .containerObjectKindSection(let group):
            return containerObjectNodes(for: group)
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

    /// The same rule a tree container uses, so toggling the layout never changes which object kinds
    /// are on screen. Tables is the one section that survives an empty count, because the flat root
    /// has no container status row to say so instead.
    ///
    /// A torn-down sidebar has no view model and lists nothing at all, Tables included. Counting its
    /// way to an empty root would put a lone Tables section in a pane that is on its way out.
    private func visibleObjectKinds() -> [SidebarObjectKind] {
        guard viewModel != nil else { return [] }
        let itemCounts = SidebarObjectKind.allCases.reduce(into: [SidebarObjectKind: Int]()) {
            $0[$1] = flatItemCount(for: $1)
        }
        return SidebarObjectKind.visible(itemCounts: itemCounts, includingEmptyTables: true)
    }

    internal func flatItemCount(for kind: SidebarObjectKind) -> Int {
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

    internal func hierarchicalSchemaMatches(_ schema: String) -> Bool {
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

    private func objectBuckets(database: String, schema: String?) -> DatabaseTreeObjectBuckets {
        let key = DatabaseTreeContainerKey(database: database, schema: schema, searchText: searchText)
        if let cached = objectBucketsCache[key] { return cached }
        let buckets = DatabaseTreeFilter.objectBuckets(
            tables: service.tables(connectionId: connectionId, database: database, schema: schema),
            routines: service.routines(connectionId: connectionId, database: database, schema: schema),
            searchText: searchText
        )
        objectBucketsCache[key] = buckets
        return buckets
    }

    private func loadedObjectNodes(database: String, schema: String?, parentId: String) -> [DatabaseTreeNode] {
        let buckets = objectBuckets(database: database, schema: schema)
        let routinesState = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)

        guard !buckets.isEmpty else {
            switch routinesState {
            case .failed(let message): return [statusNode(parentId: parentId, status: .error(message))]
            case .loaded: return [statusNode(parentId: parentId, status: .empty)]
            case .idle, .loading: return [statusNode(parentId: parentId, status: .loading)]
            }
        }

        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: database,
            schema: schema,
            itemCounts: buckets.itemCounts
        )
        var nodes = groups.map { group in
            node(
                id: DatabaseTreeNode.containerObjectKindSectionId(group),
                kind: .containerObjectKindSection(group)
            )
        }
        if case .failed(let message) = routinesState {
            nodes.append(statusNode(parentId: parentId, status: .error(message)))
        }
        return nodes
    }

    private func containerObjectNodes(for group: DatabaseTreeObjectGroup) -> [DatabaseTreeNode] {
        let buckets = objectBuckets(database: group.database, schema: group.schema)
        if group.kind.isRoutine {
            let routines = buckets.routines[group.kind] ?? []
            guard !routines.isEmpty else {
                return [statusNode(parentId: DatabaseTreeNode.containerObjectKindSectionId(group), status: .empty)]
            }
            return routines.map { routine in
                let ref = DatabaseTreeRoutineRef(
                    database: group.database, schema: group.schema, routine: routine
                )
                return node(id: DatabaseTreeNode.routineId(ref), kind: .routine(ref))
            }
        }

        let tables = buckets.tables[group.kind] ?? []
        guard !tables.isEmpty else {
            return [statusNode(parentId: DatabaseTreeNode.containerObjectKindSectionId(group), status: .empty)]
        }
        return tables.map { table in
            let ref = DatabaseTreeTableRef(database: group.database, schema: group.schema, table: table)
            return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
        }
    }

    private func statusNode(parentId: String, status: DatabaseTreeNode.Status) -> DatabaseTreeNode {
        node(id: DatabaseTreeNode.statusId(parentId: parentId, status: status), kind: .status(status))
    }

    // MARK: - Search

    internal func databaseMatchesSearch(_ metadata: DatabaseMetadata) -> Bool {
        if DatabaseTreeFilter.matches(searchText, metadata.name) { return true }
        if case .loaded(let schemas) = service.schemaListState(connectionId: connectionId, database: metadata.name) {
            if schemas.contains(where: { DatabaseTreeFilter.matches(searchText, $0) }) { return true }
            for schema in schemas where schemaContentMatchesSearch(database: metadata.name, schema: schema) {
                return true
            }
        }
        return schemaContentMatchesSearch(database: metadata.name, schema: nil)
    }

    internal func schemaContentMatchesSearch(database: String, schema: String?) -> Bool {
        if let schema, DatabaseTreeFilter.matches(searchText, schema) { return true }
        let tables = service.tables(connectionId: connectionId, database: database, schema: schema)
        if tables.contains(where: { DatabaseTreeFilter.matches(searchText, $0.name) }) { return true }
        let routines = service.routines(connectionId: connectionId, database: database, schema: schema)
        return routines.contains { DatabaseTreeFilter.matches(searchText, $0.name) }
    }
}
