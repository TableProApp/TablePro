//
//  MainContentCoordinator+ResultReload.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

extension MainContentCoordinator {
    /// Reads the tab's rows again after a write, keeping its place, value filter and selection.
    /// A query tab re-reads its active result, never the statement at the editor's caret.
    func reloadActiveResult() {
        guard let tab = tabManager.selectedTab else { return }
        guard tab.tabType == .query else {
            runQuery(viewport: .keepPlace)
            return
        }
        guard tab.display.activeResultSet != nil, let rerun = tab.sortRerun else { return }
        rerunActiveResult(rerun, viewport: .keepPlace)
    }

    @discardableResult
    func rerunActiveResult(_ rerun: ResultRerun, viewport: GridReloadIntent) -> Bool {
        guard let (tab, index) = tabManager.selectedTabAndIndex,
              !tabExecution.isExecuting(tab.id),
              let batches = rerunBatches(for: rerun, of: tab) else { return false }

        let target = RereadTarget(
            tabId: tab.id,
            resultId: tab.display.activeResultSetId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName
        )
        let install = ResultInstall(
            viewport: viewport,
            source: .reread(target),
            anchor: tab.display.activeResultSet?.statementAnchor
        )
        tabManager.tabStructureVersion += 1
        if let parameters = rerun.boundParameters {
            queryExecutionCoordinator.dispatchParameterizedBatches(
                batches,
                parameters: parameters,
                tabIndex: index,
                install: install
            )
        } else {
            queryExecutionCoordinator.dispatchBatches(batches, tabIndex: index, install: install)
        }
        return true
    }

    func sortQueryResult(by newState: SortState, tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        guard supportsColumnSort, let rerun = tab.sortRerun, rerunBatches(for: rerun, of: tab) != nil else {
            sortHeldRows(by: newState, tabId: tabId)
            return
        }
        /// A click while the next run is in flight is dropped, not queued: kept, it stood in for the
        /// reader's next Run, bound to the values of a result that run had already replaced.
        guard !tabExecution.isExecuting(tabId) else {
            traceExecutionBlocked(tabId: tabId, site: "handleSortStateChanged")
            return
        }
        let capturedColumns = tabSessionRegistry.tableRows(for: tabId).columns
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed, self.tabManager.selectedTabId == tabId,
                  !self.tabExecution.isExecuting(tabId) else { return }
            let orderClause = newState.columns.compactMap { sortCol -> String? in
                guard sortCol.columnIndex >= 0, sortCol.columnIndex < capturedColumns.count else { return nil }
                let columnName = capturedColumns[sortCol.columnIndex]
                let direction = sortCol.direction == .ascending ? "ASC" : "DESC"
                return "\(self.queryBuilder.quoteIdentifier(columnName)) \(direction)"
            }.joined(separator: ", ")
            let orderQuery = rerun.transformingSQL {
                QuerySqlParser.applyingOrderBy(orderClause, to: $0, grammar: self.lexicalGrammar)
            }
            guard let current = self.tabManager.selectedTab,
                  self.rerunBatches(for: orderQuery, of: current) != nil,
                  self.tabManager.mutate(tabId: tabId, { tab in
                      tab.sortState = newState
                      tab.hasUserInteraction = true
                      tab.pagination.reset()
                      tab.pagination.resetLoadMore()
                  }) else { return }
            self.rerunActiveResult(orderQuery, viewport: .firstRow)
        }
    }

    /// The read outlasts a result switch, and landing after one would put this result's rows and view
    /// state on another. The tab may be in the background by then; the rows still belong to it.
    func rereadStillApplies(_ source: ResultSourceChange) -> Bool {
        guard case .reread(let target) = source else { return true }
        guard let tab = tabManager.tabs.first(where: { $0.id == target.tabId }) else { return false }
        return tab.display.activeResultSetId == target.resultId
            && tab.tableContext.databaseName == target.databaseName
            && tab.tableContext.schemaName == target.schemaName
    }

    /// A run executes on the selected tab, so a re-read authorized after a tab switch would run there.
    func rereadCanStart(_ source: ResultSourceChange) -> Bool {
        guard case .reread(let target) = source else { return true }
        return tabManager.selectedTabId == target.tabId && rereadStillApplies(source)
    }

    /// Nil unless the result can be read again as it was: one statement, and a read. A write behind
    /// the rows must not run a second time.
    private func rerunBatches(for rerun: ResultRerun, of tab: QueryTab) -> [ExecutableBatch]? {
        guard tab.tabType == .query else { return nil }
        let batches = queryExecutionCoordinator.executionBatches(in: rerun.sql)
        let statements = batches.flatMap(\.statements)
        guard statements.count == 1,
              OperationKind.worst(of: statements.map(\.sql), databaseType: connection.type) == .readQuery else { return nil }
        return batches
    }
}
