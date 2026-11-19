//
//  MainContentCoordinator+CatalogPage.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A first page built on a column list from the connection's catalog. SQL text says which queries were built on which list.
struct CatalogPage {
    enum Standing {
        case awaiting
        case outdated
        case dismissed
    }

    let id = UUID()
    var key: String
    var tableName: String
    var scope: DatabaseScope
    // Each query built on a list no read beside it confirmed: a rerun folds by that list and is judged as it ran.
    var builtQueries: [String: SchemaColumnStore.Entry]
    var standing = Standing.awaiting
    // The list the verdict that found the page outdated was read with, so Reload needs no read of its own.
    var confirmed: SchemaColumnStore.Entry?
}

// Taken when a run starts, so the verdict describes the state that run was built from.
struct CatalogPageCheck {
    let pageId: UUID
    let tab: QueryTab
    let tableName: String
    let scope: DatabaseScope
    let hint: DefaultSortHint
    let sql: String
    let isBuiltOnCatalog: Bool
    let confirmedAtStart: SchemaColumnStore.Entry?
    let awaitsConfirmation: Bool
}

struct OutdatedPageNotice: Equatable {
    let tableName: String
    let resultSetId: UUID?
}

extension QueryTab {
    // Only over the result it was judged for: another result set or the Structure view hides it.
    @MainActor
    var shownOutdatedPageNotice: OutdatedPageNotice? {
        guard let notice = outdatedPageNotice, display.resultsViewMode != .structure,
              display.activeResultSet?.id == notice.resultSetId
        else { return nil }
        return notice
    }
}

extension MainContentCoordinator {
    // A temp table is the session's alone, a restored view resolves only on confirmed columns, a change in flight may stale them.
    func catalogColumnsForFirstLoad(
        of tab: QueryTab,
        tableName: String,
        scope: DatabaseScope?
    ) async -> SchemaColumnStore.Entry? {
        guard let scope, !scope.isSessionBound,
              tab.pendingRestoredSort == nil, tab.restoredPage == nil,
              !services.catalogChangeService.isApplyingChange(for: connectionId),
              schemaColumns.cached(schemaColumnsKey(tableName, scope: scope)) == nil,
              let catalog = services.schemaProviderRegistry.provider(for: scope),
              let columns = await catalog.catalogColumns(forTable: tableName, schema: scope.schema)
        else { return nil }
        return SchemaColumnStore.Entry(fetchedColumns: columns, classifier: schemaColumnClassifier)
    }

    func noteCatalogPage(_ list: SchemaColumnStore.Entry, ofTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tableName = tab.tableContext.tableName,
              let scope = scope(for: tab)
        else { return }
        forgetCatalogPage(ofTab: tabId)
        let page = CatalogPage(
            key: schemaColumnsKey(tableName, scope: scope),
            tableName: tableName,
            scope: scope,
            builtQueries: [tab.content.query: list]
        )
        tabSessionRegistry.setCatalogPage(page, for: tabId)
    }

    // Reload builds on a list it did not read, so its run is judged by the SQL it sends, like the first page's.
    func noteCatalogPageQuery(ofTab tabId: UUID, builtOn list: SchemaColumnStore.Entry) {
        guard var page = tabSessionRegistry.catalogPage(for: tabId),
              let query = tabManager.tabs.first(where: { $0.id == tabId })?.content.query
        else { return }
        page.builtQueries[query] = list
        tabSessionRegistry.setCatalogPage(page, for: tabId)
    }

    func catalogPageList(of tab: QueryTab, sql: String) -> SchemaColumnStore.Entry? {
        guard let page = tabSessionRegistry.catalogPage(for: tab.id),
              let tableName = tab.tableContext.tableName,
              page.key == schemaColumnsKey(tableName, scope: scope(for: tab))
        else { return nil }
        return page.builtQueries[sql]
    }

    func catalogPageCheck(for tab: QueryTab, sql: String, scope: DatabaseScope) -> CatalogPageCheck? {
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName,
              let page = tabSessionRegistry.catalogPage(for: tab.id), page.key == schemaColumnsKey(tableName, scope: scope)
        else { return nil }
        return CatalogPageCheck(
            pageId: page.id,
            tab: tab,
            tableName: tableName,
            scope: scope,
            hint: PluginManager.shared.defaultSortHint(for: connection.type, table: tableName),
            sql: sql,
            isBuiltOnCatalog: page.builtQueries[sql] != nil,
            confirmedAtStart: schemaColumns.cached(page.key),
            awaitsConfirmation: page.standing == .awaiting
        )
    }

    // The read the open would have waited for, run beside its page instead.
    func startCatalogConfirmation(for check: CatalogPageCheck?) -> Task<FirstLoadColumnRead?, Never>? {
        guard let check, check.confirmedAtStart == nil else { return nil }
        return Task { [weak self] in
            await self?.loadSchemaColumns(for: check.tableName, scope: check.scope)
        }
    }

    // Nil when no read confirmed the columns, or one did from before a change to the table's definition.
    func confirmedColumns(
        for check: CatalogPageCheck?,
        from confirmation: Task<FirstLoadColumnRead?, Never>?
    ) async -> SchemaColumnStore.Entry? {
        guard let check else { return nil }
        if let confirmed = check.confirmedAtStart { return confirmed }
        guard let confirmation else { return nil }
        let read = await withTaskCancellationHandler {
            await confirmation.value
        } onCancel: {
            confirmation.cancel()
        }
        guard let read else {
            return schemaColumns.cached(schemaColumnsKey(check.tableName, scope: check.scope))
        }
        guard tabSessionRegistry.definitionIsCurrent(asOf: read.startedAt, for: check.tab.id) else { return nil }
        return SchemaColumnStore.Entry(fetchedColumns: read.columns, classifier: schemaColumnClassifier)
    }

    // Only the run that owns the tab calls this, in the turn it installs its page or shows its error.
    func settleCatalogPage(_ check: CatalogPageCheck?, confirmed: SchemaColumnStore.Entry?, installed: Bool) {
        guard let check, var page = tabSessionRegistry.catalogPage(for: check.tab.id), page.id == check.pageId else { return }
        let tabId = check.tab.id
        // A failed later run leaves the page on screen, and the notice with it.
        guard installed || page.standing == .awaiting else { return }
        // Unconfirmed, a known verdict stands for a page that can still carry what the catalog list decided.
        guard let confirmed else {
            if !installed {
                discardCatalogColumns(of: page)
            } else if page.standing == .outdated {
                let carries = check.isBuiltOnCatalog || Self.isAppChosen(check.tab.sortState)
                setOutdatedPageNotice(
                    carries ? OutdatedPageNotice(tableName: page.tableName, resultSetId: activeResultSetId(of: tabId)) : nil,
                    onTab: tabId
                )
            }
            return
        }
        guard catalogPageIsOutdated(check, confirmed: confirmed) else {
            tabSessionRegistry.setCatalogPage(nil, for: tabId)
            setOutdatedPageNotice(nil, onTab: tabId)
            return
        }
        if page.standing == .awaiting {
            discardCatalogColumns(of: page)
            page.standing = .outdated
        }
        page.confirmed = confirmed
        tabSessionRegistry.setCatalogPage(page, for: tabId)
        guard page.standing == .outdated else { return }
        setOutdatedPageNotice(OutdatedPageNotice(tableName: page.tableName, resultSetId: activeResultSetId(of: tabId)), onTab: tabId)
    }

    // The catalog-built query is judged as it ran, since the tab can change before it is rebuilt; any other run used confirmed columns.
    private func catalogPageIsOutdated(_ check: CatalogPageCheck, confirmed: SchemaColumnStore.Entry) -> Bool {
        var corrected = check.tab
        corrected.sortState = confirmedSortState(for: check.tab, builtOn: confirmed, hint: check.hint)
        let ran = check.isBuiltOnCatalog ? check.sql : filterCoordinator.pageQuery(for: check.tab, builtOn: confirmed)
        return filterCoordinator.pageQuery(for: corrected, builtOn: confirmed) != ran
    }

    private func activeResultSetId(of tabId: UUID) -> UUID? {
        tabManager.tabs.first(where: { $0.id == tabId })?.display.activeResultSet?.id
    }

    // Asks about unsaved edits as Refresh does; with none it reloads at once. The only wait is that question.
    func reloadOutdatedPage(tabId: UUID) {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table, tab.outdatedPageNotice != nil,
              let page = tabSessionRegistry.catalogPage(for: tabId), page.standing == .outdated,
              let confirmed = schemaColumns.cached(page.key) ?? page.confirmed
        else { return }
        commitActiveGridEdit()
        let manager = changeManager(forTab: tabId)
        guard manager.hasChanges else {
            reload(tabId, page: page, on: confirmed)
            return
        }
        // A run, Stop or retarget while the question is up moves this, and Reload yields to it.
        let epoch = tabExecution.contentEpoch(for: tabId)
        let token = UUID()
        catalogPageReloads[tabId]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if catalogPageReloads[tabId]?.token == token { catalogPageReloads[tabId] = nil } }
            guard await confirmDiscardChanges(action: .refresh, window: contentWindow),
                  stillShows(page, onTab: tabId, since: epoch)
            else { return }
            rowEditingCoordinator.restoreRowBufferToOriginals(forTab: tabId)
            manager.clearChangesAndUndoHistory()
            reload(tabId, page: page, on: confirmed)
        }
        catalogPageReloads[tabId] = (token, task)
    }

    private func reload(_ tabId: UUID, page: CatalogPage, on confirmed: SchemaColumnStore.Entry) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        let hint = PluginManager.shared.defaultSortHint(for: connection.type, table: page.tableName)
        let sort = confirmedSortState(for: tab, builtOn: confirmed, hint: hint)
        if sort != tab.sortState {
            tabManager.mutate(tabId: tabId) {
                $0.sortState = sort
                $0.pagination.reset()
            }
        }
        reloadTableTab(tabId, builtOn: confirmed)
    }

    private func stillShows(_ page: CatalogPage, onTab tabId: UUID, since epoch: Int) -> Bool {
        guard !Task.isCancelled, !isTearingDown, tabSessionRegistry.catalogPage(for: tabId)?.id == page.id,
              tabExecution.isSameContent(epoch, for: tabId),
              let tab = tabManager.tabs.first(where: { $0.id == tabId })
        else { return false }
        return tab.tableContext.tableName == page.tableName && scope(for: tab) == page.scope
    }

    // A rename keeps the rows on screen, so their page and its notice follow the table to its new name.
    func followRename(ofCatalogPageFor tab: QueryTab) {
        guard var page = tabSessionRegistry.catalogPage(for: tab.id),
              let tableName = tab.tableContext.tableName,
              let scope = scope(for: tab)
        else { return }
        page.key = schemaColumnsKey(tableName, scope: scope)
        page.tableName = tableName
        page.scope = scope
        tabSessionRegistry.setCatalogPage(page, for: tab.id)
        if let notice = tab.outdatedPageNotice {
            setOutdatedPageNotice(OutdatedPageNotice(tableName: tableName, resultSetId: notice.resultSetId), onTab: tab.id)
        }
    }

    func dismissOutdatedPageNotice(tabId: UUID) {
        if var page = tabSessionRegistry.catalogPage(for: tabId), page.standing == .outdated {
            page.standing = .dismissed
            tabSessionRegistry.setCatalogPage(page, for: tabId)
        }
        setOutdatedPageNotice(nil, onTab: tabId)
    }

    func forgetCatalogPage(ofTab tabId: UUID) {
        catalogPageReloads.removeValue(forKey: tabId)?.task.cancel()
        tabSessionRegistry.setCatalogPage(nil, for: tabId)
    }

    func cancelCatalogPageReloads() {
        for reload in catalogPageReloads.values { reload.task.cancel() }
        catalogPageReloads.removeAll()
    }

    private func setOutdatedPageNotice(_ notice: OutdatedPageNotice?, onTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.outdatedPageNotice != notice else { return }
        tabManager.mutate(tabId: tabId) { $0.outdatedPageNotice = notice }
    }

    // Another open of the table reads it afresh instead of building on a list that was never confirmed or was wrong.
    private func discardCatalogColumns(of page: CatalogPage) {
        guard let catalog = services.schemaProviderRegistry.provider(for: page.scope) else { return }
        let tableName = page.tableName
        let schema = page.scope.schema
        Task { await catalog.discardColumns(forTable: tableName, schema: schema) }
    }
}
