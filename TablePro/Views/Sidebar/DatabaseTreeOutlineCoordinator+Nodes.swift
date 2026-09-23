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
            guard showsPartitions, ref.table.type == .partitionedTable else { return [] }
            return partitionNodes(of: ref)
        case .partition(let ref):
            guard showsPartitions, ref.partition.isSubpartitioned else { return [] }
            return subpartitionNodes(of: ref)
        case .objectKindSection(let kind):
            return flatObjectNodes(for: kind)
        case .containerObjectKindSection(let group):
            return containerObjectNodes(for: group)
        case .hierarchicalSchemaSection(let schema):
            return hierarchicalSchemaNodes(schema: schema)
        case .redisKeysSection:
            return redisChildren(of: nil)
        case .redisNode(let redisNode):
            return redisChildren(of: redisNode)
        case .recentTable, .routine, .trigger, .userType, .status:
            return []
        }
    }

    /// Only the top-level partitions. A subpartition names the partition it subdivides and is
    /// nested under that row instead, because an engine that has them reports both in one list.
    private func partitionNodes(of ref: DatabaseTreeTableRef) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.tableId(ref)
        let state = service.partitionsLoadState(
            connectionId: connectionId, database: ref.database ?? "", schema: ref.schema, table: ref.table.name
        )
        switch state {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let partitions):
            let top = partitions.filter { $0.parentPartitionName == nil }
            if top.isEmpty { return [statusNode(parentId: parentId, status: .empty)] }
            return top.map { partitionNode(parent: ref, partition: $0) }
        }
    }

    /// Where a subpartitioned partition's children come from differs by engine. A PostgreSQL
    /// partition is a relation, so its own partitions are a fetch against it, the same one its
    /// parent ran. A MySQL or Oracle partition is not, so its subpartitions arrived in the parent's
    /// own list carrying its name.
    private func subpartitionNodes(of ref: DatabaseTreePartitionRef) -> [DatabaseTreeNode] {
        if let relation = ref.tableRef {
            return partitionNodes(of: relation)
        }
        let parent = ref.parent
        let state = service.partitionsLoadState(
            connectionId: connectionId,
            database: parent.database ?? "",
            schema: parent.schema,
            table: parent.table.name
        )
        guard case .loaded(let partitions) = state else { return [] }
        return partitions
            .filter { $0.parentPartitionName == ref.partition.name }
            .map { partitionNode(parent: parent, partition: $0) }
    }

    private func partitionNode(parent: DatabaseTreeTableRef, partition: PartitionInfo) -> DatabaseTreeNode {
        let ref = DatabaseTreePartitionRef(parent: parent, partition: partition)
        return node(id: DatabaseTreeNode.partitionId(ref), kind: .partition(ref))
    }

    /// Which shape the root takes. The three sidebar modes used to be three views; they are one
    /// outline now and this is the only thing that still differs between them.
    internal var rootShape: SidebarRootShape {
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
            activeDatabase: mainCoordinator?.browseDatabaseName ?? activeDatabase,
            showsSystem: showSystemContainers
        )
        let matched = searchText.isEmpty ? visible : visible.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        nodes += matched
            .filter { seen.insert($0.id).inserted }
            .map { node(id: DatabaseTreeNode.databaseId($0.name), kind: .database($0)) }
        return nodes
    }

    internal var browsingDatabase: String? {
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
        if let database = browsingDatabase {
            nodes += flatOtherSchemaMatches(database: database).map {
                node(id: DatabaseTreeNode.schemaId(database: database, schema: $0), kind: .schema(database: database, schema: $0))
            }
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
        return SidebarObjectKind.visible(
            itemCounts: itemCounts,
            declaredKinds: declaredObjectKinds,
            includingEmptyTables: true
        )
    }

    /// What the engine says it has, so a database that genuinely holds no procedures still shows a
    /// Procedures section saying so, instead of looking like an engine that never implemented the
    /// fetch. It only ever adds a section; a kind with rows is listed whatever this returns.
    internal var declaredObjectKinds: Set<SidebarObjectKind> {
        databaseType.declaredObjectKinds
    }

    internal func flatItemCount(for kind: SidebarObjectKind) -> Int {
        guard let viewModel else { return 0 }
        switch kind.category {
        case .table:
            return viewModel.filteredTables(of: kind, from: schemaService.tables(for: connectionId)).count
        case .routine:
            return viewModel.filteredRoutines(of: kind, from: schemaService.routines(for: connectionId)).count
        case .trigger:
            return viewModel.filteredTriggers(from: schemaService.triggers(for: connectionId)).count
        case .type:
            return viewModel.filteredUserTypes(from: schemaService.userDefinedTypes(for: connectionId)).count
        }
    }

    /// A section with no rows says why, the way a tree container does: still loading, failed, or
    /// genuinely empty. Left bare, an empty Procedures section read the same as one whose fetch never
    /// came back. A search that matches nothing in a section is not a reason, so it stays bare.
    private func flatObjectNodes(for kind: SidebarObjectKind) -> [DatabaseTreeNode] {
        let rows = flatObjectRows(for: kind)
        guard rows.isEmpty, searchText.isEmpty, viewModel != nil else { return rows }
        return [
            statusNode(
                parentId: DatabaseTreeNode.objectKindSectionId(kind),
                status: .emptySection(flatLoadPhase(for: kind))
            )
        ]
    }

    private func flatLoadPhase(for kind: SidebarObjectKind) -> MetadataLoadPhase {
        switch kind.category {
        case .table: return .loaded
        case .routine: return schemaService.routinesLoadState(for: connectionId).erased
        case .trigger: return schemaService.triggersLoadState(for: connectionId).erased
        case .type: return schemaService.userDefinedTypesLoadState(for: connectionId).erased
        }
    }

    private func flatObjectRows(for kind: SidebarObjectKind) -> [DatabaseTreeNode] {
        guard let viewModel else { return [] }
        let database = browsingDatabase
        switch kind.category {
        case .table:
            return viewModel.filteredTables(of: kind, from: schemaService.tables(for: connectionId))
                .map { table in
                    let ref = DatabaseTreeTableRef(database: database, schema: table.schema, table: table)
                    return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
                }
        case .routine:
            let routines = viewModel.filteredRoutines(of: kind, from: schemaService.routines(for: connectionId))
            return routineNodes(routines, database: database, schema: { $0.schema })
        case .trigger:
            return viewModel.filteredTriggers(from: schemaService.triggers(for: connectionId))
                .map { trigger in
                    let ref = DatabaseTreeTriggerRef(database: database, schema: trigger.schema, trigger: trigger)
                    return node(id: DatabaseTreeNode.triggerId(ref), kind: .trigger(ref))
                }
        case .type:
            return viewModel.filteredUserTypes(from: schemaService.userDefinedTypes(for: connectionId))
                .map { type in
                    let ref = DatabaseTreeUserTypeRef(database: database, schema: type.schema, type: type)
                    return node(id: DatabaseTreeNode.userTypeId(ref), kind: .userType(ref))
                }
        }
    }

    private func hierarchicalRootNodes() -> [DatabaseTreeNode] {
        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs().isEmpty {
            nodes.append(node(id: DatabaseTreeNode.recentSectionId, kind: .recentSection))
        }
        let browsable = DatabaseTreeVisibility.visibleSchemas(
            schemaService.schemas(for: connectionId),
            systemSchemas: systemSchemas,
            activeSchema: activeSchema,
            showsSystem: showSystemContainers
        )
        nodes += browsable
            .filter { searchText.isEmpty || hierarchicalSchemaVerdict($0).isVisible }
            .map {
                node(id: DatabaseTreeNode.hierarchicalSchemaSectionId($0), kind: .hierarchicalSchemaSection(schema: $0))
            }
        return nodes
    }

    internal func hierarchicalSchemaVerdict(_ schema: String) -> DatabaseTreeFilter.SchemaSearchVerdict {
        DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
            schema: schema,
            database: browsingDatabase,
            searchText: searchText,
            loadedContent: DatabaseTreeFilter.hierarchicalLoadedContent(
                in: schemaService,
                connectionId: connectionId,
                schema: schema,
                searchText: searchText,
                database: browsingDatabase
            ),
            listingMatches: schemaService.loadedScope(for: connectionId).flatMap { listingMatches(database: $0.database) },
            listingCoversSchema: !systemSchemas.contains(schema)
        )
    }

    /// A schema lists its objects in the same kind groups a tree container uses, so a schema that
    /// holds only procedures shows a Procedures group instead of reading as empty.
    private func hierarchicalSchemaNodes(schema: String) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.hierarchicalSchemaSectionId(schema)
        switch schemaService.schemaState(for: connectionId, schema: schema) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded:
            let database = hierarchicalGroupDatabase
            return groupedObjectNodes(
                buckets: objectBuckets(database: database, schema: schema),
                sidePhases: hierarchicalSideLoadStates(schema: schema),
                database: database,
                schema: schema,
                parentId: parentId
            )
        }
    }

    /// An engine grouped by hierarchical schema browses no database, so its groups are keyed by
    /// the browsed one when there is one and by nothing otherwise.
    private var hierarchicalGroupDatabase: String {
        browsingDatabase ?? ""
    }

    private func hierarchicalSideLoadStates(schema: String) -> DatabaseTreeSidePhases {
        let declared = declaredObjectKinds
        return DatabaseTreeSidePhases(
            routines: schemaService.routinesLoadState(for: connectionId, schema: schema).erased,
            triggers: declared.contains(.trigger)
                ? schemaService.triggersLoadState(for: connectionId, schema: schema).erased
                : nil,
            types: declared.contains(.type)
                ? schemaService.userDefinedTypesLoadState(for: connectionId, schema: schema).erased
                : nil
        )
    }

    private func hierarchicalObjectBuckets(schema: String) -> DatabaseTreeObjectBuckets {
        DatabaseTreeFilter.hierarchicalObjectBuckets(
            schema: schema,
            tables: schemaService.tables(for: connectionId, schema: schema),
            routines: schemaService.routines(for: connectionId, schema: schema),
            triggers: schemaService.triggers(for: connectionId, schema: schema),
            userTypes: schemaService.userDefinedTypes(for: connectionId, schema: schema),
            searchText: searchText,
            database: browsingDatabase
        )
    }

    private func redisChildren(of parent: RedisKeyNode?) -> [DatabaseTreeNode] {
        guard let keyTree = sidebarState?.redisKeyTreeViewModel else { return [] }
        if let parent {
            guard case .namespace(_, _, let children, _) = parent else { return [] }
            return children.map { node(id: DatabaseTreeNode.redisNodeId($0), kind: .redisNode($0)) }
        }
        return RedisKeyTreeRows.rows(for: keyTree.state, searchText: searchText).map { row in
            switch row {
            case .status(let status):
                return statusNode(parentId: DatabaseTreeNode.redisKeysSectionId, status: status)
            case .node(let keyNode):
                return node(id: DatabaseTreeNode.redisNodeId(keyNode), kind: .redisNode(keyNode))
            }
        }
    }

    private func recentTableRefs() -> [DatabaseTreeTableRef] {
        guard let sidebarState, showRecentTables else { return [] }
        let database = browsingDatabase
        let search = SidebarSearch(searchText)
        return sidebarState.recentEntries(inDatabase: database).compactMap { entry -> DatabaseTreeTableRef? in
            if !search.isEmpty {
                guard search.matchesObject(named: entry.name, database: database, schema: entry.schema) else {
                    return nil
                }
            }
            return DatabaseTreeTableRef(database: database, schema: entry.schema, table: entry.tableInfo)
        }
    }

    /// The flat list shows the browsed schema's objects only, so a search also names the other
    /// schemas it found objects in. Each is the tree's own schema row, which expands, loads and
    /// offers its menus exactly as it does in the tree.
    private func flatOtherSchemaMatches(database: String) -> [String] {
        guard !searchText.isEmpty, listsTablesPerSchema else { return [] }
        return DatabaseTreeFilter.otherSchemaMatches(
            database: database,
            browsedSchema: activeSchema,
            searchText: searchText,
            hiddenSchemas: showSystemContainers ? [] : systemSchemas,
            allSchemaTables: service.allSchemaTablesLoadState(connectionId: connectionId, database: database),
            loadedContent: { self.loadedObjectBuckets(database: database, schema: $0) }
        )
    }

    internal var listsTablesPerSchema: Bool {
        DatabaseTreeMetadataService.listsTablesPerSchema(PluginManager.shared.databaseGroupingStrategy(for: databaseType))
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
                activeSchema: database == browsingDatabase ? activeSchema : nil,
                showsSystem: showSystemContainers,
                searchText: searchText,
                database: database,
                contentMatches: { schemaSearchVerdict(database: database, schema: $0).isVisible }
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

    /// The schema-grouped shape reads its objects from the connection's own schema service and the
    /// tree reads them per database, so the one shared bucket cache asks the source that shape owns.
    private func objectBuckets(database: String, schema: String?) -> DatabaseTreeObjectBuckets {
        let key = DatabaseTreeContainerKey(database: database, schema: schema, searchText: searchText)
        if let cached = objectBucketsCache[key] { return cached }
        let buckets: DatabaseTreeObjectBuckets
        if rootShape == .hierarchicalSchema, let schema {
            buckets = hierarchicalObjectBuckets(schema: schema)
        } else {
            buckets = DatabaseTreeFilter.objectBuckets(
                tables: service.tables(connectionId: connectionId, database: database, schema: schema),
                routines: service.routines(connectionId: connectionId, database: database, schema: schema),
                triggers: service.triggers(connectionId: connectionId, database: database, schema: schema),
                userTypes: service.userDefinedTypes(connectionId: connectionId, database: database, schema: schema),
                searchText: searchText,
                database: database
            )
        }
        objectBucketsCache[key] = buckets
        return buckets
    }

    internal func matchCount(in group: DatabaseTreeObjectGroup) -> Int {
        objectBuckets(database: group.database, schema: group.schema).itemCounts[group.kind] ?? 0
    }

    /// Nil until the tree has loaded this schema's tables, so a search can tell a schema that holds
    /// no match from one nobody has listed yet.
    private func loadedObjectBuckets(database: String, schema: String?) -> DatabaseTreeObjectBuckets? {
        guard case .loaded = service.tablesLoadState(connectionId: connectionId, database: database, schema: schema) else {
            return nil
        }
        return objectBuckets(database: database, schema: schema)
    }

    /// A fetch the engine never runs stays idle for good, and idle is not loaded: counting it
    /// would hold every empty container on a spinner for a list that is never coming. So only the
    /// kinds this engine declares take part in deciding between "empty" and "loading".
    private func sideLoadStates(database: String, schema: String?) -> DatabaseTreeSidePhases {
        let declared = declaredObjectKinds
        return DatabaseTreeSidePhases(
            routines: service.routinesLoadState(connectionId: connectionId, database: database, schema: schema).erased,
            triggers: declared.contains(.trigger)
                ? service.triggersLoadState(connectionId: connectionId, database: database, schema: schema).erased
                : nil,
            types: declared.contains(.type)
                ? service.typesLoadState(connectionId: connectionId, database: database, schema: schema).erased
                : nil
        )
    }

    private func sidePhases(for group: DatabaseTreeObjectGroup) -> DatabaseTreeSidePhases {
        if rootShape == .hierarchicalSchema, let schema = group.schema {
            return hierarchicalSideLoadStates(schema: schema)
        }
        return sideLoadStates(database: group.database, schema: group.schema)
    }

    private func loadedObjectNodes(database: String, schema: String?, parentId: String) -> [DatabaseTreeNode] {
        groupedObjectNodes(
            buckets: objectBuckets(database: database, schema: schema),
            sidePhases: sideLoadStates(database: database, schema: schema),
            database: database,
            schema: schema,
            parentId: parentId
        )
    }

    private func groupedObjectNodes(
        buckets: DatabaseTreeObjectBuckets,
        sidePhases: DatabaseTreeSidePhases,
        database: String,
        schema: String?,
        parentId: String
    ) -> [DatabaseTreeNode] {
        guard !buckets.isEmpty else {
            return [statusNode(parentId: parentId, status: .emptyContainer(sideStates: sidePhases.all))]
        }

        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: database,
            schema: schema,
            itemCounts: buckets.itemCounts,
            declaredKinds: declaredObjectKinds
        )
        var nodes = groups.map { group in
            node(
                id: DatabaseTreeNode.containerObjectKindSectionId(group),
                kind: .containerObjectKindSection(group)
            )
        }
        if let failure = sidePhases.unplacedFailure(listing: Set(groups.map(\.kind.category))) {
            nodes.append(statusNode(parentId: parentId, status: .error(failure)))
        }
        return nodes
    }

    private func containerObjectNodes(for group: DatabaseTreeObjectGroup) -> [DatabaseTreeNode] {
        let buckets = objectBuckets(database: group.database, schema: group.schema)
        let emptyId = DatabaseTreeNode.containerObjectKindSectionId(group)
        /// A schema-grouped group carries no database, and a reference naming an empty one would
        /// switch the session to a database called "" the moment the row opened.
        let database: String? = group.database.isEmpty ? nil : group.database
        let placeholder = DatabaseTreeNode.Status.emptySection(sidePhases(for: group).phase(for: group.kind.category))
        switch group.kind.category {
        case .table:
            let tables = buckets.tables[group.kind] ?? []
            guard !tables.isEmpty else {
                return [statusNode(parentId: emptyId, status: placeholder)]
            }
            return tables.map { table in
                let ref = DatabaseTreeTableRef(database: database, schema: group.schema, table: table)
                return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
            }
        case .routine:
            let routines = buckets.routines[group.kind] ?? []
            guard !routines.isEmpty else {
                return [statusNode(parentId: emptyId, status: placeholder)]
            }
            return routineNodes(routines, database: database, schema: { _ in group.schema })
        case .trigger:
            guard !buckets.triggers.isEmpty else {
                return [statusNode(parentId: emptyId, status: placeholder)]
            }
            return buckets.triggers.map { trigger in
                let ref = DatabaseTreeTriggerRef(database: database, schema: group.schema, trigger: trigger)
                return node(id: DatabaseTreeNode.triggerId(ref), kind: .trigger(ref))
            }
        case .type:
            guard !buckets.userTypes.isEmpty else {
                return [statusNode(parentId: emptyId, status: placeholder)]
            }
            return buckets.userTypes.map { type in
                let ref = DatabaseTreeUserTypeRef(database: database, schema: group.schema, type: type)
                return node(id: DatabaseTreeNode.userTypeId(ref), kind: .userType(ref))
            }
        }
    }

    /// The labels are decided over the whole section at once, because "is this name ambiguous"
    /// is a question about the section and not about the routine.
    private func routineNodes(
        _ routines: [RoutineInfo],
        database: String?,
        schema: (RoutineInfo) -> String?
    ) -> [DatabaseTreeNode] {
        let labels = RoutineDisplayLabel.labels(for: routines)
        return routines.map { routine in
            let ref = DatabaseTreeRoutineRef(database: database, schema: schema(routine), routine: routine)
            routineDisplayLabels[ref.id] = labels[routine.id] ?? routine.name
            return node(id: DatabaseTreeNode.routineId(ref), kind: .routine(ref))
        }
    }

    private func statusNode(parentId: String, status: DatabaseTreeNode.Status) -> DatabaseTreeNode {
        node(id: DatabaseTreeNode.statusId(parentId: parentId, status: status), kind: .status(status))
    }

    // MARK: - Search

    /// A database is kept when its name answers a plain search, when a schema of it is kept, or when
    /// objects it holds outside any schema match. Only schemas the tree would show are asked, so a
    /// hidden system schema cannot keep a database on screen that shows nothing matching.
    internal func databaseMatchesSearch(_ metadata: DatabaseMetadata) -> Bool {
        let search = SidebarSearch(searchText)
        if search.qualified == nil, DatabaseTreeFilter.matches(searchText, metadata.name) { return true }
        if case .loaded(let schemas) = service.schemaListState(connectionId: connectionId, database: metadata.name) {
            let browsable = DatabaseTreeVisibility.visibleSchemas(
                schemas,
                systemSchemas: systemSchemas,
                activeSchema: metadata.name == browsingDatabase ? activeSchema : nil,
                showsSystem: showSystemContainers
            )
            if browsable.contains(where: { schemaSearchVerdict(database: metadata.name, schema: $0).isVisible }) {
                return true
            }
        }
        return databaseContentMatchesSearch(database: metadata.name)
    }

    internal func schemaSearchVerdict(database: String, schema: String) -> DatabaseTreeFilter.SchemaSearchVerdict {
        DatabaseTreeFilter.schemaSearchVerdict(
            schema: schema,
            database: database,
            searchText: searchText,
            loadedContent: loadedObjectBuckets(database: database, schema: schema),
            listingMatches: listingMatches(database: database),
            listingCoversSchema: listsTablesPerSchema && !systemSchemas.contains(schema)
        )
    }

    /// Worked out once per database per redraw, since every schema of the database is judged
    /// against the same listing.
    private func listingMatches(database: String) -> DatabaseTreeFilter.SchemaListingMatches? {
        let key = DatabaseTreeContainerKey(database: database, schema: nil, searchText: searchText)
        if let cached = listingMatchesCache[key] { return cached }
        guard let listing = service.allSchemaTablesLoadState(connectionId: connectionId, database: database).value else {
            return nil
        }
        let matches = DatabaseTreeFilter.SchemaListingMatches(listing: listing, database: database, searchText: searchText)
        listingMatchesCache[key] = matches
        return matches
    }

    /// The objects a database holds outside any schema, which is every object on an engine with no
    /// schema level. `shop.` asks for all of them, and a schema engine has none to give.
    private func databaseContentMatchesSearch(database: String) -> Bool {
        let search = SidebarSearch(searchText)
        if search.qualified != nil, search.nameQuery.isEmpty {
            return !supportsSchemaLevel && search.admits(database: database, schema: nil)
        }
        return !objectBuckets(database: database, schema: nil).isEmpty
    }
}
