//
//  MainContentCoordinator+TableFirstLoad.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func openTableTabQuery(tabId: UUID, trigger: TableLoadTrigger = .userInitiated) async {
        let tracer = TableLoadTracer.shared
        let token = tracer.activeToken(for: tabId)
        if let token { tracer.stage(.prepareFirstLoad, token: token) }

        guard await prepareTableTabFirstLoad(tabId: tabId) else {
            if let token {
                tracer.anomaly(
                    .preparationAbandoned,
                    token: token,
                    detail: "cancelled=\(Task.isCancelled)"
                )
                tracer.finish(token: token, outcome: .prepareAbandoned)
            }
            return
        }
        let viewport = restoredRowAnchor(forTab: tabId).map(GridReloadIntent.restoreRow) ?? .keepPlace
        executeTableTabQueryDirectly(onTab: tabId, trigger: trigger, viewport: viewport)
        // A load that asked first, or never started, reads the definition itself.
        firstLoadColumnReads[tabId] = nil
    }

    @discardableResult
    func prepareTableTabFirstLoad(tabId: UUID) async -> Bool {
        guard tabManager.selectedTabId == tabId,
              var tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return false }

        if resolveTableTabSchemaIfNeeded(tabId: tabId),
           let resolvedTab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab = resolvedTab
        }

        let hint = PluginManager.shared.defaultSortHint(for: connection.type, table: tableName)
        guard firstLoadNeedsSchemaColumns(for: tab, hint: hint) else {
            if let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                filterCoordinator.rebuildTableQuery(at: index)
            }
            return true
        }

        let tracer = TableLoadTracer.shared
        let token = tracer.activeToken(for: tabId)
        let schemaName = tab.tableContext.schemaName
        let tabScope = scope(for: tab)
        if let token { tracer.stage(.schemaColumnsBegin, token: token) }
        let cataloged = await catalogColumnsForFirstLoad(of: tab, tableName: tableName, scope: tabScope)
        let columnRead = cataloged == nil ? await loadSchemaColumns(for: tableName, scope: tabScope) : nil
        if let token { tracer.stage(.schemaColumnsEnd, token: token) }

        guard !Task.isCancelled,
              tabManager.selectedTabId == tabId,
              let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tableContext.tableName == tableName,
              tabManager.tabs[index].tableContext.schemaName == schemaName,
              cataloged == nil || scope(for: tabManager.tabs[index]) == tabScope else { return false }

        if !applyPendingRestoredViewState(at: index) {
            _ = applyResolvedDefaultSort(at: index, hint: hint, builtOn: cataloged)
        }
        // Unconditional: a tab reopened from closed history carries filtered SQL whose filter may come back unapplied.
        filterCoordinator.rebuildTableQuery(at: index, builtOn: cataloged)
        if let cataloged { noteCatalogPage(cataloged, ofTab: tabId) }
        firstLoadColumnReads[tabId] = columnRead
        return true
    }

    @discardableResult
    func resolveTableTabSchemaIfNeeded(tabId: UUID) -> Bool {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .table,
              tabManager.tabs[index].tableContext.schemaName == nil,
              let resolvedSchema = DatabaseManager.shared.resolvedSchemaName(
                  nil,
                  inDatabase: tabManager.tabs[index].tableContext.resolvedDatabaseName(browsing: browseDatabaseName),
                  for: connectionId
              )
        else { return false }

        tabManager.adoptResolvedSchema(resolvedSchema, at: index)
        filterCoordinator.rebuildTableQuery(at: index)
        return true
    }

    /// Applied filters wait for the schema because no rows have arrived to type their values, and
    /// an untyped value is guessed from its text: `123` goes to a text column as a number, which
    /// PostgreSQL rejects and MySQL answers by comparing numerically. An engine that defers large
    /// values needs the column types to leave them out of the first page.
    func firstLoadNeedsSchemaColumns(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        wantsDefaultSort(for: tab, hint: hint)
            || defersLargeValues
            || !tab.columnLayout.hiddenColumns.isEmpty
            || tab.filterState.isFiltering
            || tab.pendingRestoredSort != nil
            || tab.restoredPage != nil
    }

    private func applyPendingRestoredViewState(at index: Int) -> Bool {
        let tab = tabManager.tabs[index]
        guard tab.pendingRestoredSort != nil || tab.restoredPage != nil else { return false }

        let pendingSort = tab.pendingRestoredSort ?? []
        /// Against the full schema, not the scoped selection. `selectColumns` retains only the
        /// columns the *live* sort names, and a restored sort is still sitting in
        /// `pendingRestoredSort`, so a saved sort on a hidden column resolved to nothing and the
        /// next save wrote the loss to disk.
        let resolvedSort = supportsColumnSort ? MainContentCoordinator.resolveRestoredSortColumns(
            pendingSort,
            in: cachedSchemaColumns(for: tab)?.columns ?? effectiveResultColumns(for: tab)
        ) : []
        /// A sort that resolved to nothing has not been consumed, it has failed to resolve, which is
        /// what an empty column list looks like when the schema fetch did not land. Clearing it
        /// anyway threw the saved sort away and the next save wrote the loss to disk.
        let sortWasConsumed = pendingSort.isEmpty || !resolvedSort.isEmpty || !supportsColumnSort
        // The persisted page index counts pages of the size it was taken in, so reading it in
        // today's default would land the tab on rows it was never showing.
        let pageSize = paginationCapability.clampedRowCount(
            tab.restoredPageSize ?? AppSettingsManager.shared.dataGrid.defaultPageSize
        )
        let page = paginationCapability.allowsSeeking ? max(1, tab.restoredPage ?? 1) : 1

        tabManager.mutate(at: index) { tab in
            if sortWasConsumed {
                tab.pendingRestoredSort = nil
            }
            tab.restoredPage = nil
            tab.restoredPageSize = nil
            if !resolvedSort.isEmpty {
                tab.sortState = SortState(columns: resolvedSort, source: tab.restoredSortSource)
            }
            tab.pagination.pageSize = pageSize
            tab.pagination.currentPage = page
            tab.pagination.currentOffset = (page - 1) * pageSize
        }
        return !resolvedSort.isEmpty || page > 1
    }

    /// The app default applies only while nothing has decided the order.
    ///
    /// `isSorting` alone cannot gate this: an empty sort the user chose through Don't Sort looks
    /// exactly like a tab that has never sorted, so the default was written straight back over it on
    /// the next first load, and Don't Sort could never stick.
    func wantsDefaultSort(for tab: QueryTab, hint: DefaultSortHint) -> Bool {
        guard tab.tabType == .table,
              supportsColumnSort,
              tab.sortState.source == .unset,
              !tab.sortState.isSorting,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else {
            return false
        }

        switch hint {
        case .suppress:
            return false
        case .forceColumns:
            return true
        case .useAppDefault:
            return AppSettingsManager.shared.dataGrid.defaultSortBehavior != .none
        }
    }

    private func applyResolvedDefaultSort(at index: Int, hint: DefaultSortHint, builtOn schema: SchemaColumnStore.Entry?) -> Bool {
        let tab = tabManager.tabs[index]
        guard wantsDefaultSort(for: tab, hint: hint) else { return false }

        let resolved = resolvedDefaultSort(
            hint: hint,
            primaryKeys: (schema ?? cachedSchemaColumns(for: tab))?.primaryKeys,
            allColumns: schema.map { effectiveResultColumns(for: tab, schema: $0) } ?? effectiveResultColumns(for: tab)
        )
        guard resolved.isSorting else { return false }

        tabManager.mutate(at: index) {
            $0.sortState = resolved
            $0.pagination.reset()
        }
        return true
    }

    private func resolvedDefaultSort(hint: DefaultSortHint, primaryKeys: [String]?, allColumns: [String]) -> SortState {
        DefaultSortResolver.resolveSortState(
            behavior: AppSettingsManager.shared.dataGrid.defaultSortBehavior,
            direction: AppSettingsManager.shared.dataGrid.defaultSortDirection,
            pluginHint: hint,
            primaryKeyColumns: resolvedPrimaryKeyColumns(primaryKeys),
            allColumns: allColumns
        )
    }

    private func resolvedPrimaryKeyColumns(_ primaryKeys: [String]?) -> [String] {
        if let primaryKeys, !primaryKeys.isEmpty {
            return primaryKeys
        }
        if let defaultPK = PluginManager.shared.defaultPrimaryKeyColumn(for: connection.type) {
            return [defaultPK]
        }
        return []
    }

    // The sort an open would choose from this list. One the user chose stays, and so does one the setting no longer asks for.
    func confirmedSortState(for tab: QueryTab, builtOn schema: SchemaColumnStore.Entry, hint: DefaultSortHint) -> SortState {
        guard Self.isAppChosen(tab.sortState) else { return tab.sortState }
        var unsorted = tab
        unsorted.sortState = SortState()
        guard wantsDefaultSort(for: unsorted, hint: hint) else { return tab.sortState }
        let resolved = resolvedDefaultSort(
            hint: hint,
            primaryKeys: schema.primaryKeys,
            allColumns: effectiveResultColumns(for: unsorted, schema: schema)
        )
        return resolved.isSorting ? resolved : SortState()
    }

    static func isAppChosen(_ sort: SortState) -> Bool {
        sort.source == .defaultSort || (sort.source == .unset && !sort.isSorting)
    }
}
