//
//  MainContentCoordinator+CatalogPage.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A first page built on a column list from the connection's catalog. Its SQL text says which queries were built on it.
struct CatalogPage {
    enum Standing {
        case awaiting
        case outdated
        case dismissed
    }

    let id = UUID()
    let key: String
    let tableName: String
    let scope: DatabaseScope
    let list: SchemaColumnStore.Entry
    let query: String
    var standing = Standing.awaiting
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
            list: list,
            query: tab.content.query
        )
        tabSessionRegistry.setCatalogPage(page, for: tabId)
    }

    func catalogPageList(of tab: QueryTab, sql: String) -> SchemaColumnStore.Entry? {
        guard let page = tabSessionRegistry.catalogPage(for: tab.id), page.query == sql,
              let tableName = tab.tableContext.tableName,
              page.key == schemaColumnsKey(tableName, scope: scope(for: tab))
        else { return nil }
        return page.list
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
            isBuiltOnCatalog: page.query == sql,
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
            tabSessionRegistry.setCatalogPage(page, for: tabId)
        }
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

    // Asks about unsaved edits as Refresh does, and ends as soon as the tab leaves the table it was asked on.
    func reloadOutdatedPage(tabId: UUID) {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .table, tab.outdatedPageNotice != nil,
              let page = tabSessionRegistry.catalogPage(for: tabId), page.standing == .outdated
        else { return }
        let manager = changeManager(forTab: tabId)
        let token = UUID()
        catalogPageReloads[tabId]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if catalogPageReloads[tabId]?.token == token { catalogPageReloads[tabId] = nil } }
            guard stillShows(page, onTab: tabId) else { return }
            if schemaColumns.cached(page.key) == nil {
                await loadSchemaColumns(for: page.tableName, scope: page.scope)
                guard stillShows(page, onTab: tabId) else { return }
            }
            guard let confirmed = schemaColumns.cached(page.key) else { return }
            // After the read, so an edit made while it ran is asked about too.
            if tabManager.selectedTabId == tabId { commitActiveGridEdit() }
            if manager.hasChanges {
                guard await confirmDiscardChanges(action: .refresh, window: contentWindow),
                      stillShows(page, onTab: tabId)
                else { return }
                rowEditingCoordinator.restoreRowBufferToOriginals(forTab: tabId)
                manager.clearChangesAndUndoHistory()
            }
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
        catalogPageReloads[tabId] = (token, task)
    }

    private func stillShows(_ page: CatalogPage, onTab tabId: UUID) -> Bool {
        guard !Task.isCancelled, !isTearingDown, tabSessionRegistry.catalogPage(for: tabId)?.id == page.id,
              let tab = tabManager.tabs.first(where: { $0.id == tabId })
        else { return false }
        return tab.tableContext.tableName == page.tableName && scope(for: tab) == page.scope
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
