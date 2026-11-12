//
//  DatabaseTreeOutlineCoordinator+Expansion.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import TableProUtilities

/// Which rows are disclosed, where that is remembered, and the loads a disclosure triggers.
extension DatabaseTreeOutlineCoordinator {
    internal func applyDesiredExpansion() {
        guard self.outlineView != nil else { return }
        seedExpansionFromSession()
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        guard listsConnections else {
            applyShapeExpansion(roots: resolvedChildren(of: nil))
            return
        }
        // Rows under a closed connection or group are restored when it opens.
        guard let ownConnection = applyConnectionExpansion(under: nil) else { return }
        applyShapeExpansion(roots: resolvedChildren(of: ownConnection))
    }

    /// The rows the shape lists at its top, wherever they hang: the root, or the own connection.
    private func applyShapeExpansion(roots: [DatabaseTreeNode]) {
        guard let outlineView = self.outlineView else { return }
        let searching = !searchText.isEmpty
        for rootNode in roots {
            switch rootNode.kind {
            case .recentSection:
                setExpanded(rootNode, searching || (viewModel?.isRecentsExpanded ?? true))
            case .favoritesSection:
                setExpanded(rootNode, searching || (viewModel?.isFavoritesExpanded ?? true))
            case .temporarySection:
                setExpanded(rootNode, searching || (viewModel?.isTemporaryExpanded ?? true))
            default:
                break
            }
        }
        for sectionNode in roots {
            switch sectionNode.kind {
            case .objectKindSection(let kind):
                let hasMatches = flatItemCount(for: kind) > 0
                setExpanded(sectionNode, viewModel?.effectiveExpanded(kind: kind, hasMatches: hasMatches) ?? true)
                if outlineView.isItemExpanded(sectionNode) { restoreTableExpansion(under: sectionNode) }
            case .foldersSection:
                setExpanded(sectionNode, searching || (viewModel?.isFoldersExpanded ?? true))
                if outlineView.isItemExpanded(sectionNode) { restoreFolderExpansion(under: sectionNode) }
            case .redisKeysSection:
                setExpanded(sectionNode, searching || (viewModel?.isRedisKeysExpanded ?? true))
            case .schema(let database, let schema) where listsAttachedSchemas:
                let want = searching
                    ? searchOpens(sectionNode, database: database, schema: schema)
                    : windowState?.expandedTreeDatabaseSchemas.contains(DatabaseSchemaKey(database: database, schema: schema)) ?? false
                setExpanded(sectionNode, want)
                if outlineView.isItemExpanded(sectionNode) {
                    triggerLoad(for: sectionNode)
                    restoreObjectGroupExpansion(under: sectionNode)
                }
            case .schema:
                setExpanded(sectionNode, true)
                if outlineView.isItemExpanded(sectionNode) {
                    triggerLoad(for: sectionNode)
                    restoreObjectGroupExpansion(under: sectionNode)
                }
            case .hierarchicalSchemaSection(let schema):
                let want = searching
                    ? hierarchicalSchemaVerdict(schema) == .match
                    : windowState?.expandedTreeSchemas.contains(schema) ?? false
                setExpanded(sectionNode, want)
                if outlineView.isItemExpanded(sectionNode) {
                    triggerLoad(for: sectionNode)
                    restoreObjectGroupExpansion(under: sectionNode)
                }
            default:
                break
            }
        }
        for databaseNode in roots {
            guard case .database(let metadata) = databaseNode.kind else { continue }
            let want = searching
                ? databaseMatchesSearch(metadata)
                : windowState?.expandedTreeDatabases.contains(metadata.name) ?? false
            setExpanded(databaseNode, want)
            guard outlineView.isItemExpanded(databaseNode) else { continue }
            triggerLoad(for: databaseNode)
            guard supportsSchemaLevel else {
                restoreObjectGroupExpansion(under: databaseNode)
                continue
            }
            for schemaNode in resolvedChildren(of: databaseNode) {
                guard case .schema(let database, let schema) = schemaNode.kind else { continue }
                let wantSchema = searching
                    ? searchOpens(schemaNode, database: database, schema: schema)
                    : windowState?.expandedTreeDatabaseSchemas.contains(DatabaseSchemaKey(database: database, schema: schema)) ?? false
                setExpanded(schemaNode, wantSchema)
                if outlineView.isItemExpanded(schemaNode) {
                    triggerLoad(for: schemaNode)
                    restoreObjectGroupExpansion(under: schemaNode)
                }
            }
            restoreObjectGroupExpansion(under: databaseNode)
        }
    }

    /// A schema matched by its own name alone stays closed, since opened it shows an empty container.
    /// One already open stays open, so a row opened by hand does not snap shut when its read lands.
    private func searchOpens(_ node: DatabaseTreeNode, database: String, schema: String) -> Bool {
        guard schemaSearchVerdict(database: database, schema: schema) == .match else { return false }
        if outlineView?.isItemExpanded(node) == true { return true }
        return !objectBuckets(database: database, schema: schema).isEmpty
    }

    /// The flag is down for a click, so a schema opened by hand mid-search reads like any other.
    private var disclosureOrigin: DatabaseTreeFilter.DisclosureOrigin {
        guard isApplyingExpansion else { return .user }
        return searchText.isEmpty ? .restore : .search
    }

    /// A connection knows where it is browsing from the moment it connects, so the tree can
    /// open there instead of showing every container closed. Runs once per connection; after
    /// that the user's own expansion state is the only input.
    private func seedExpansionFromSession() {
        guard let windowState, !windowState.didSeedExpansion else { return }
        let session = DatabaseManager.shared.session(for: connectionId)
        windowState.seedExpansionIfNeeded(
            database: session?.resolvedBrowseDatabase,
            schema: session?.browseSchema
        )
    }

    /// A table, its detail groups and a subpartitioned partition are restored here. On PostgreSQL a
    /// subpartitioned partition is a relation of its own and loads its own children, so it is
    /// recorded and re-expanded under the same key a table uses. A section can hold 17,000 tables,
    /// so the names the window recorded are checked before any key is built.
    private func restoreTableExpansion(under parent: DatabaseTreeNode) {
        guard showsPartitions || showsTableDetails, let outlineView = self.outlineView, let windowState else { return }
        guard searchText.isEmpty else {
            readOpenDetailRows(under: parent)
            return
        }
        let expandedNames = Set(windowState.expandedTreeTables.map { $0.table })
        guard !expandedNames.isEmpty else { return }
        for node in resolvedChildren(of: parent) {
            if case .tableDetailGroup(let group) = node.kind {
                guard windowState.expandedTreeTableDetailGroups.contains(group.expansionKey) else { continue }
            } else {
                guard let ref = expandableTableRef(of: node), expandedNames.contains(ref.table.name),
                      node.isExpandable(showsPartitions: showsPartitions, showsTableDetails: showsTableDetails),
                      windowState.expandedTreeTables.contains(DatabaseTableKey(ref))
                else { continue }
            }
            setExpanded(node, true)
            guard outlineView.isItemExpanded(node) else { continue }
            triggerLoad(for: node)
            restoreTableExpansion(under: node)
        }
    }

    /// A search decides what is open and opens no table, yet a group already open on screen still
    /// reads a list a change or a reconnect overtook. The restore pass was its only reader, so its
    /// spinner stayed until the search was cleared.
    private func readOpenDetailRows(under parent: DatabaseTreeNode) {
        guard showsTableDetails, let outlineView = self.outlineView else { return }
        for node in resolvedChildren(of: parent) where outlineView.isItemExpanded(node) {
            switch node.kind {
            case .table, .partition, .tableDetailGroup:
                triggerLoad(for: node)
                readOpenDetailRows(under: node)
            case .connectionGroup, .savedConnection, .recentSection, .recentTable, .favoritesSection, .favoriteTable,
                 .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
                 .database, .schema, .tableDetail, .routine, .trigger, .userType, .serverObject, .status, .objectKindSection,
                 .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
                continue
            }
        }
    }

    private func expandableTableRef(of node: DatabaseTreeNode) -> DatabaseTreeTableRef? {
        switch node.kind {
        case .table(let ref):
            return ref
        case .partition(let ref):
            return ref.tableRef
        default:
            return nil
        }
    }

    private func recordTableExpansion(_ ref: DatabaseTreeTableRef, expanded: Bool) {
        if expanded {
            windowState?.expandedTreeTables.insert(DatabaseTableKey(ref))
        } else {
            windowState?.expandedTreeTables.remove(DatabaseTableKey(ref))
        }
    }

    /// A folder is open unless the user closed it, and every folder is open while a search runs, so
    /// a match inside one is on screen rather than behind a closed triangle.
    private func restoreFolderExpansion(under parent: DatabaseTreeNode) {
        guard let outlineView = self.outlineView else { return }
        let searching = !searchText.isEmpty
        for folderNode in resolvedChildren(of: parent) {
            guard let ref = folderNode.folderRef else { continue }
            let collapsed = windowState?.collapsedTableFolders.contains(ref.folder.id) ?? false
            setExpanded(folderNode, searching || !collapsed)
            if outlineView.isItemExpanded(folderNode) { restoreTableExpansion(under: folderNode) }
        }
    }

    private func restoreObjectGroupExpansion(under parent: DatabaseTreeNode) {
        guard let outlineView = self.outlineView else { return }
        let searching = !searchText.isEmpty
        restoreFolderExpansion(under: parent)
        for groupNode in resolvedChildren(of: parent) {
            guard case .containerObjectKindSection(let group) = groupNode.kind else { continue }
            let expanded = DatabaseTreeFilter.objectGroupIsExpanded(
                searching: searching,
                matchCount: searching ? matchCount(in: group) : 0,
                stored: windowState?.isTreeObjectGroupExpanded(group) ?? group.kind.isExpandedByDefault
            )
            setExpanded(groupNode, expanded)
            if outlineView.isItemExpanded(groupNode) { restoreTableExpansion(under: groupNode) }
        }
    }

    // Behind the `applyDesiredExpansion` flag: recording each row rewrote the expansion snapshot and re-entered this.
    internal func restoreDescendantExpansion(afterExpanding node: DatabaseTreeNode) {
        let wasApplyingExpansion = isApplyingExpansion
        isApplyingExpansion = true
        defer { isApplyingExpansion = wasApplyingExpansion }
        switch node.kind {
        case .connectionGroup:
            guard let ownConnection = applyConnectionExpansion(under: node) else { break }
            applyShapeExpansion(roots: resolvedChildren(of: ownConnection))
        case .savedConnection(let ref) where ref.ownsTree:
            applyShapeExpansion(roots: resolvedChildren(of: node))
        // A schema engine's database holds its `.database` kind groups beside the schemas.
        case .database, .schema, .hierarchicalSchemaSection:
            restoreObjectGroupExpansion(under: node)
        case .foldersSection:
            restoreFolderExpansion(under: node)
        case .objectKindSection, .containerObjectKindSection, .tableFolder, .table, .partition, .tableDetailGroup:
            restoreTableExpansion(under: node)
        case .savedConnection, .recentSection, .recentTable, .favoritesSection, .favoriteTable, .temporarySection,
             .temporaryTable, .routine, .trigger, .userType, .serverObject, .status, .redisKeysSection, .redisNode,
             .tableDetail:
            break
        }
    }

    internal func setExpanded(_ node: DatabaseTreeNode, _ expanded: Bool) {
        guard let outlineView = self.outlineView else { return }
        if expanded, !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        } else if !expanded, outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        }
    }

    internal func recordExpansion(_ node: DatabaseTreeNode, expanded: Bool) {
        switch node.kind {
        case .connectionGroup(let group):
            if !expanded { revealedConnectionGroupIds.remove(group.id) }
            connectionsModel?.setGroupExpanded(group.id, expanded)
        case .savedConnection(let ref):
            guard ref.ownsTree else { break }
            viewModel?.isOwnConnectionExpanded = expanded
        case .recentSection:
            viewModel?.isRecentsExpanded = expanded
        case .favoritesSection:
            viewModel?.isFavoritesExpanded = expanded
        case .temporarySection:
            viewModel?.isTemporaryExpanded = expanded
        case .foldersSection:
            viewModel?.isFoldersExpanded = expanded
        case .tableFolder(let ref):
            if expanded {
                windowState?.collapsedTableFolders.remove(ref.folder.id)
            } else {
                windowState?.collapsedTableFolders.insert(ref.folder.id)
            }
        case .objectKindSection(let kind):
            viewModel?.expanded[kind] = expanded
        case .containerObjectKindSection(let group):
            windowState?.setTreeObjectGroup(group, expanded: expanded)
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
            recordTableExpansion(ref, expanded: expanded)
        case .partition(let ref):
            guard let tableRef = ref.tableRef else { break }
            recordTableExpansion(tableRef, expanded: expanded)
        case .tableDetailGroup(let group):
            if expanded {
                windowState?.expandedTreeTableDetailGroups.insert(group.expansionKey)
            } else {
                windowState?.expandedTreeTableDetailGroups.remove(group.expansionKey)
            }
        case .recentTable, .favoriteTable, .temporaryTable, .routine, .trigger, .userType, .serverObject, .status, .redisNode,
             .tableDetail:
            break
        }
    }

    internal func triggerLoad(for node: DatabaseTreeNode) {
        switch node.kind {
        case .database(let metadata):
            if supportsSchemaLevel {
                if service.schemaListNeedsFetch(connectionId: connectionId, database: metadata.name) {
                    Task { await service.loadSchemas(connectionId: connectionId, database: metadata.name) }
                }
                loadDatabaseServerObjects(database: metadata.name)
                loadExternalSchemaNames(database: metadata.name)
            } else {
                loadObjects(database: metadata.name, schema: nil)
            }
        case .schema(let database, let schema):
            guard DatabaseTreeFilter.readsOnDisclosure(origin: disclosureOrigin)
                || isOpenedByUser(database: database, schema: schema)
            else { return }
            loadObjects(database: database, schema: schema)
        case .table(let ref):
            // With Table Details on, partitions load with their own group rather than with the table.
            guard !showsTableDetails else { return }
            loadPartitions(ref)
        case .partition(let ref):
            loadPartitions(ref.tableRef ?? ref.parent)
        case .tableDetailGroup(let group):
            loadTableDetailGroup(group)
        case .hierarchicalSchemaSection(let schema):
            guard DatabaseTreeFilter.readsOnDisclosure(origin: disclosureOrigin)
                || !hierarchicalSearchSkipsRead(schema)
            else { return }
            loadHierarchicalSchemaObjects(schema)
        case .connectionGroup, .savedConnection, .recentSection, .recentTable, .favoritesSection, .favoriteTable,
             .temporarySection, .temporaryTable, .foldersSection, .tableFolder,
             .routine, .trigger, .userType, .serverObject, .status, .objectKindSection, .containerObjectKindSection,
             .redisKeysSection, .redisNode, .tableDetail:
            break
        }
    }

    private func loadDatabaseServerObjects(database: String) {
        guard service.serverObjectsNeedFetch(connectionId: connectionId, database: database, schema: nil) else { return }
        let connectionId = connectionId
        Task { await service.loadServerObjects(connectionId: connectionId, database: database, schema: nil) }
    }

    /// A schema the user has open keeps reading the lists a change overtook while a search runs; one
    /// the search opened shows the listing's tables instead.
    internal func isOpenedByUser(database: String, schema: String) -> Bool {
        let key = DatabaseSchemaKey(database: database, schema: schema)
        return windowState?.expandedTreeDatabaseSchemas.contains(key) == true || schemasOpenedDuringSearch.contains(key)
    }

    /// The listing holds tables alone, so a search skips reading only a schema never read before, which
    /// it found a matching table in and the user did not open or name. Until the listing lands it reads
    /// none: both share one metadata connection, and the reads queued ahead of it held back the search's
    /// first answer by seconds.
    internal func hierarchicalSearchSkipsRead(_ schema: String) -> Bool {
        guard !searchText.isEmpty,
              !schemaService.hasLoadedContent(for: connectionId, schema: schema),
              !isHierarchicalSchemaOpenedByUser(schema)
        else { return false }
        if isSearchListingPending { return true }
        return !searchNamesSchema(schema) && hierarchicalListingMatchesTable(in: schema)
    }

    /// The databases a search reads the all-schema listing of, the ones `SidebarViewModel` asks for.
    internal var searchListingDatabases: Set<String> {
        SidebarViewModel.databasesListedForSearch(
            grouping: PluginManager.shared.databaseGroupingStrategy(for: databaseType),
            browsedDatabase: DatabaseManager.shared.browseScope(for: connectionId)?.database,
            databasesWithSchemaLists: Set(
                service.schemaList.compactMap { key, state in
                    key.connectionId == connectionId && state.value != nil ? key.database : nil
                }
            ),
            layout: sidebarState?.sidebarLayout ?? .flat
        )
    }

    private var isSearchListingPending: Bool {
        guard DatabaseManager.shared.session(for: connectionId)?.reportedStatus == .connected else { return false }
        return searchListingDatabases.contains { database in
            switch service.allSchemaTablesLoadState(connectionId: connectionId, database: database) {
            case .idle, .loading: return true
            case .loaded, .failed: return false
            }
        }
    }

    private func searchNamesSchema(_ schema: String) -> Bool {
        let search = SidebarSearch(searchText)
        if search.matchesContainer(database: browsingDatabase, schema: schema) { return true }
        return search.qualified != nil && search.admits(database: browsingDatabase, schema: schema)
    }

    internal func isHierarchicalSchemaOpenedByUser(_ schema: String) -> Bool {
        windowState?.expandedTreeSchemas.contains(schema) == true
            || schemasOpenedDuringSearch.contains(Self.hierarchicalSearchKey(schema))
    }

    /// A tree with one row per schema names no database, so its schemas share one key space here.
    internal static func hierarchicalSearchKey(_ schema: String) -> DatabaseSchemaKey {
        DatabaseSchemaKey(database: "", schema: schema)
    }

    /// An expanded schema is the reader a catalog change waits for: it reads a schema never read,
    /// and one a change has overtaken, once per change.
    private func loadHierarchicalSchemaObjects(_ schema: String) {
        guard schemaService.schemaObjectsNeedFetch(for: connectionId, schema: schema) else { return }
        let connectionId = connectionId
        let database = browsingDatabase
        Task {
            await schemaService.loadSchemaObjects(connectionId: connectionId, schema: schema, database: database)
        }
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
        guard showsPartitions, ref.table.type == .partitionedTable else { return }
        let database = ref.database ?? ""
        guard service.partitionsNeedFetch(
            connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name
        ) else { return }
        Task {
            await service.loadPartitions(
                connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name
            )
        }
    }

    /// A group reads its own list alone. Partitions keep their own list and the rule it already follows.
    private func loadTableDetailGroup(_ group: DatabaseTreeTableDetailGroupRef) {
        let ref = group.table
        guard let kind = group.kind.detailKind else {
            loadPartitions(ref)
            return
        }
        let connectionId = connectionId
        let database = ref.database ?? ""
        let phase = service.tableDetailsLoadState(
            connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name, kind: kind
        ).erased
        let needsFetch = service.tableDetailsNeedFetch(
            connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name, kind: kind
        )
        guard TableDetailGroupResolver.readsOnDisclosure(needsFetch: needsFetch, phase: phase, origin: disclosureOrigin)
        else { return }
        Task {
            await service.loadTableDetails(
                connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name, kind: kind
            )
        }
    }

    /// An expanded container whose lists a change overtook reads them again on the next pass; a
    /// collapsed one waits until it is opened.
    private func loadObjects(database: String, schema: String?) {
        guard service.objectsNeedFetch(connectionId: connectionId, database: database, schema: schema) else { return }
        let connectionId = connectionId
        Task { await service.loadObjects(connectionId: connectionId, database: database, schema: schema) }
    }
}
