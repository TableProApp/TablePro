//
//  DatabaseTreeOutlineCoordinator+Expansion.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// Which rows are disclosed, where that is remembered, and the loads a disclosure triggers.
extension DatabaseTreeOutlineCoordinator {
    internal func applyDesiredExpansion() {
        guard let outlineView = self.outlineView else { return }
        seedExpansionFromSession()
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
                if outlineView.isItemExpanded(sectionNode) { restorePartitionExpansion(under: sectionNode) }
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
                restoreObjectGroupExpansion(under: databaseNode)
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
                    restoreObjectGroupExpansion(under: schemaNode)
                }
            }
        }
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

    private func restorePartitionExpansion(under parent: DatabaseTreeNode) {
        guard searchText.isEmpty, let outlineView = self.outlineView, let windowState else { return }
        for tableNode in resolvedChildren(of: parent) {
            guard case .table(let ref) = tableNode.kind, ref.table.type == .partitionedTable else { continue }
            let key = DatabaseTableKey(database: ref.database ?? "", schema: ref.schema, table: ref.table.name)
            guard windowState.expandedTreeTables.contains(key) else { continue }
            setExpanded(tableNode, true)
            guard outlineView.isItemExpanded(tableNode) else { continue }
            triggerLoad(for: tableNode)
            restorePartitionExpansion(under: tableNode)
        }
    }

    private func restoreObjectGroupExpansion(under parent: DatabaseTreeNode) {
        guard let outlineView = self.outlineView else { return }
        let searching = !searchText.isEmpty
        for groupNode in resolvedChildren(of: parent) {
            guard case .containerObjectKindSection(let group) = groupNode.kind else { continue }
            let expanded = searching || (windowState?.isTreeObjectGroupExpanded(group) ?? group.kind.isExpandedByDefault)
            setExpanded(groupNode, expanded)
            if outlineView.isItemExpanded(groupNode) { restorePartitionExpansion(under: groupNode) }
        }
    }

    /// The cascade only re-asserts disclosure the store already holds, so it runs behind the flag
    /// `applyDesiredExpansion` uses. Recording each row it opens rewrote the whole expansion
    /// snapshot to `UserDefaults`, and re-entered this restore once per row.
    internal func restoreDescendantExpansion(afterExpanding node: DatabaseTreeNode) {
        let wasApplyingExpansion = isApplyingExpansion
        isApplyingExpansion = true
        defer { isApplyingExpansion = wasApplyingExpansion }
        switch node.kind {
        case .database where !supportsSchemaLevel:
            restoreObjectGroupExpansion(under: node)
        case .schema:
            restoreObjectGroupExpansion(under: node)
        case .objectKindSection, .containerObjectKindSection, .hierarchicalSchemaSection:
            restorePartitionExpansion(under: node)
        case .recentSection, .recentTable, .database, .table, .routine, .status,
             .redisKeysSection, .redisNode:
            break
        }
    }

    private func setExpanded(_ node: DatabaseTreeNode, _ expanded: Bool) {
        guard let outlineView = self.outlineView else { return }
        if expanded, !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        } else if !expanded, outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        }
    }

    internal func recordExpansion(_ node: DatabaseTreeNode, expanded: Bool) {
        switch node.kind {
        case .recentSection:
            viewModel?.isRecentsExpanded = expanded
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
            let key = DatabaseTableKey(database: ref.database ?? "", schema: ref.schema, table: ref.table.name)
            if expanded {
                windowState?.expandedTreeTables.insert(key)
            } else {
                windowState?.expandedTreeTables.remove(key)
            }
        case .recentTable, .routine, .status, .redisNode:
            break
        }
    }

    internal func triggerLoad(for node: DatabaseTreeNode) {
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
             .objectKindSection, .containerObjectKindSection,
             .redisKeysSection, .redisNode:
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
        let database = ref.database ?? ""
        let state = service.partitionsLoadState(
            connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name
        )
        guard isIdle(state) else { return }
        Task {
            await service.loadPartitions(
                connectionId: connectionId, database: database, schema: ref.schema, table: ref.table.name
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
}
