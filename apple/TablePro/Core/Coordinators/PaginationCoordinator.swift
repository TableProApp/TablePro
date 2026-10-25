//
//  PaginationCoordinator.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

private let progressLog = Logger(subsystem: "com.TablePro", category: "ProgressiveLoad")
private let exactCountLog = Logger(subsystem: "com.TablePro", category: "ExactRowCount")

@MainActor
final class PaginationCoordinator: ObservableObject {
    unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Pagination

    func goToNextPage() {
        guard canSeek, let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        let loadedRowCount = parent.tabSessionRegistry.tableRows(for: tab.id).rows.count
        guard tab.pagination.canGoToNextPage(loadedRowCount: loadedRowCount) else { return }
        paginateAfterConfirmation(tabIndex: tabIndex) { $0.goToNextPage(loadedRowCount: loadedRowCount) }
    }

    func goToPreviousPage() {
        seekIfPossible(where: \.hasPreviousPage) { $0.goToPreviousPage() }
    }

    func goToFirstPage() {
        seekIfPossible(where: \.hasPreviousPage) { $0.goToFirstPage() }
    }

    func goToLastPage() {
        seekIfPossible(where: { $0.isLastPageKnown && $0.currentPage != $0.totalPages }) { $0.goToLastPage() }
    }

    func goToPage(_ page: Int) {
        seekIfPossible(where: { $0.hasRowCountTotal && page > 0 }) { $0.goToPage(page) }
    }

    func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        let pageSize = parent.paginationCapability.clampedRowCount(newSize)
        paginateIfPossible { $0.updatePageSize(pageSize) }
    }

    // An engine that cannot skip rows has only the first page.
    private var canSeek: Bool {
        parent.paginationCapability.allowsSeeking
    }

    private func seekIfPossible(
        where condition: (PaginationState) -> Bool,
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        guard canSeek else { return }
        paginateIfPossible(where: condition, mutate: mutate)
    }

    // Only sized from a real count: the driver's estimate (MySQL guessed 420,000) loaded a LIMIT that silently dropped rows.
    func showAllRows() {
        guard canSeek,
              let (tab, _) = parent.tabManager.selectedTabAndIndex,
              tab.pagination.hasExactRowCount,
              let total = tab.pagination.totalRowCount, total > 0 else { return }

        let tabId = tab.id
        confirmLargeFetch(
            messageText: String(localized: "Show All Rows"),
            informativeText: String(
                format: String(localized: "This will load all %@ rows on a single page. Large result sets use significant memory. Continue?"),
                total.formatted()
            ),
            confirmTitle: String(localized: "Show All")
        ) { [weak self] in
            guard let self,
                  let tabIndex = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
                pagination.updatePageSize(max(total, 1))
                pagination.goToFirstPage()
            }
        }
    }

    private func confirmLargeFetch(
        messageText: String,
        informativeText: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))

        if let window = parent.contentWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                onConfirm()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    private func paginateIfPossible(
        where condition: (PaginationState) -> Bool = { _ in true },
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              condition(tab.pagination) else { return }
        paginateAfterConfirmation(tabIndex: tabIndex, mutate: mutate)
    }

    private func paginateAfterConfirmation(
        tabIndex: Int,
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        let tabId = parent.tabManager.tabs[tabIndex].id
        parent.confirmDiscardChangesIfNeeded(action: .pagination) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard parent.tabManager.mutate(tabId: tabId, { tab in
                mutate(&tab.pagination)
                tab.paginationVersion += 1
            }) else { return }
            reloadCurrentPage()
        }
    }

    private func reloadCurrentPage() {
        guard let tabIndex = parent.tabManager.selectedTabIndex,
              tabIndex < parent.tabManager.tabs.count else { return }

        parent.rebuildTableQuery(at: tabIndex)
        parent.runQuery(viewport: .firstRow)
    }

    // MARK: - Cancel Current Query

    // Acts on the visible tab: a window-wide stop let one tab's Stop roll back another tab's batch.
    func cancelCurrentQuery() {
        guard let tabId = parent.tabManager.selectedTabId else { return }
        parent.stopExecution(for: tabId)
    }

    // MARK: - Exact Row Count

    func requestExactRowCount() {
        guard let (tab, index) = parent.tabManager.selectedTabAndIndex,
              tab.tabType == .table,
              !tab.pagination.isCountingExact,
              let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return }

        guard let scope = parent.scope(for: tab) else { return }
        let tabId = tab.id
        let schemaName = tab.tableContext.schemaName
        let filters = tab.filterState.hasAppliedFilters ? tab.filterState.appliedFilters : []
        let logicMode = tab.filterState.filterLogicMode
        // A plugin search replaces the table filters in a narrowed browse, so the count must read it or it counts the whole table.
        let browseFilters = parent.filterCoordinator.activeBrowseSearch(for: tab.filterState)?.pluginQueryFilters
        let isNonSQL = PluginManager.shared.editorLanguage(for: parent.connection.type) != .sql
        let queryColumns = parent.queryColumns(for: tab)
        let countSQL = isNonSQL ? nil : parent.queryBuilder.buildFilteredCountQuery(
            tableName: tableName, schemaName: schemaName, filters: filters, logicMode: logicMode,
            columns: queryColumns.columns, columnTypes: queryColumns.columnTypes
        )

        // Claims the superseded automatic count's flag too: its task finds the token changed and won't clear a successor's state.
        parent.tabManager.mutate(at: index) { tab in
            tab.pagination.isCountingExact = true
            tab.pagination.isCountPending = false
        }

        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let token = UUID()
        parent.claimExactCount(for: tabId, token: token)
        let task = Task(priority: .userInitiated) { [parent] in
            let outcome = await Self.exactRowCount(
                scope: scope,
                tableName: tableName,
                filters: filters,
                logicMode: logicMode,
                browseFilters: browseFilters,
                countSQL: countSQL
            )

            // Clears on every exit: returning early on cancel left a page turn during COUNT(*) with an endless spinner and no Count Exactly.
            let isCurrent = !Task.isCancelled && parent.tabExecution.isSameContent(contentEpoch, for: tabId)
            // `Cmd+.` clears the flag and allows a second count, so a late first task must not stop the second one's spinner.
            let ownsIndicator = parent.releaseExactCount(for: tabId, token: token)
            parent.clearRowCountTask(for: tabId, token: token)
            parent.tabManager.mutate(tabId: tabId) { tab in
                if ownsIndicator {
                    tab.pagination.isCountingExact = false
                }
                guard isCurrent else { return }
                Self.applyExactCount(outcome, to: &tab)
            }
        }
        parent.setRowCountTask(task, token: token, for: tabId)
    }

    static func applyExactCount(_ outcome: Result<Int?, Error>, to tab: inout QueryTab) {
        switch outcome {
        case .success(let count):
            if let shown = tab.pagination.exactCountError, tab.execution.errorMessage == shown {
                tab.execution.errorMessage = nil
            }
            tab.pagination.exactCountError = nil
            guard let count, count >= 0 else { return }
            tab.pagination.totalRowCount = count
            tab.pagination.isApproximateRowCount = false
        case .failure(let error):
            guard !DatabaseCancellationDiagnosis.isCancellation(error) else { return }
            let message = DatabaseWriteRejectionDiagnosis.formatted(error)
            tab.execution.errorMessage = message
            tab.pagination.exactCountError = message
        }
    }

    // User-requested, so a failure shows on the tab: an engine only its driver can count (throttled DynamoDB scan) has no fallback.
    private static func exactRowCount(
        scope: DatabaseScope,
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        browseFilters: [PluginQueryFilter]?,
        countSQL: String?
    ) async -> Result<Int?, Error> {
        do {
            let count = try await DatabaseManager.shared.withRowCountDriver(scope: scope, filtered: !filters.isEmpty) { driver in
                if let browseFilters {
                    return try await driver.fetchExactRowCount(table: tableName, browseFilters: browseFilters)
                }
                return try await ExactRowCounter.count(
                    on: driver, table: tableName, filters: filters, logicMode: logicMode, countSQL: countSQL
                )
            }
            return .success(count)
        } catch {
            exactCountLog.warning("Exact row count failed: \(error.publicLogShape, privacy: .public)")
            return .failure(error)
        }
    }

    // MARK: - Fetch All Rows

    // The scope is read before the alert, so a database change while it is open can't redirect the tab's query.
    func fetchAllRows() {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex,
              !tab.pagination.isLoadingMore,
              !parent.tabExecution.isExecuting(tab.id),
              tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

        guard let scope = parent.scope(for: tab) else {
            parent.tabManager.mutate(tabId: tab.id) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        let loadedCount = parent.tabSessionRegistry.tableRows(for: tab.id).rows.count
        let totalEstimate = tab.pagination.totalRowCount

        let message: String
        if let total = totalEstimate {
            let remaining = max(0, total - loadedCount)
            message = String(
                format: String(localized: "This will fetch approximately %@ more rows. Large result sets use significant memory. Continue?"),
                remaining.formatted()
            )
        } else {
            message = String(localized: "This will fetch all remaining rows. Large result sets use significant memory. Continue?")
        }

        confirmLargeFetch(
            messageText: String(localized: "Fetch All Rows"),
            informativeText: message,
            confirmTitle: String(localized: "Fetch All")
        ) { [weak self] in
            guard let self else { return }
            performFetchAll(tabId: tab.id, baseQuery: baseQuery, scope: scope)
        }
    }

    // Only driver work runs in the lease (the gate isn't reentrant). Fenced on the result set too: a result switch keeps the epoch.
    internal func performFetchAll(tabId: UUID, baseQuery: String, scope: DatabaseScope) {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard !parent.tabManager.tabs[idx].pagination.isLoadingMore else { return }

        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let resultSetId = parent.tabManager.tabs[idx].display.activeResultSetId
        let storedParamValues = parent.tabManager.tabs[idx].pagination.baseQueryParameterValues

        parent.tabManager.mutate(at: idx) { $0.pagination.isLoadingMore = true }

        // Can't claim the tab: claiming mints a new epoch and drops its own rows. Unclaimed work keeps the titlebar reporting it.
        let workToken = parent.tabExecution.beginUnclaimedWork(for: tabId)
        let owner = TabQueryTaskOwner.unclaimedWork(tabId: tabId, token: workToken)
        let lease = DriverLeaseOwner()
        let isTableTab = parent.tabManager.tabs[idx].tabType == .table
        let lengthColumns = isTableTab ? parent.unloadedValueLengthColumns(for: parent.tabManager.tabs[idx]) : []

        let startedAt = ContinuousClock.Instant.now
        // Both releases cover the whole task: a cancelled bare return left a finished fetch installed, which `installQueryTask` then ended.
        let fetchAllTask = Task { [weak self, parent] in
            defer {
                parent.tabExecution.endUnclaimedWork(workToken, for: tabId)
                parent.retireQueryTask(owner)
            }
            guard let self, !parent.isTearingDown else { return }

            do {
                let start = CFAbsoluteTimeGetCurrent()
                progressLog.info("[fetchAll] executing full query: \(baseQuery.prefix(100), privacy: .private)")
                let result = try await parent.withExecutionDriver(
                    scope: scope,
                    isTableTab: isTableTab,
                    lease: lease
                ) { driver in
                    let result = try await driver.executeUserQuery(
                        query: baseQuery,
                        rowCap: nil,
                        parameters: storedParamValues.map { $0.map { $0 as Any? } }
                    )
                    return result.foldingUnloadedValues(lengthColumns: lengthColumns)
                }
                let fetchTime = CFAbsoluteTimeGetCurrent() - start
                progressLog.info("[fetchAll] rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s")

                guard !Task.isCancelled else {
                    // Clears the flag like every exit: a bare return stuck the tab on Loading after a late cancel (no-op `cancelQuery()` drivers).
                    await MainActor.run { [weak self] in
                        self?.parent.tabManager.mutate(tabId: tabId) { tab in
                            tab.pagination.isLoadingMore = false
                        }
                    }
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self, !parent.isTearingDown else { return }
                    let stillSameResult = parent.tabManager.tabs
                        .contains { $0.id == tabId && $0.display.activeResultSetId == resultSetId }
                    guard parent.tabExecution.isSameContent(contentEpoch, for: tabId), stillSameResult else {
                        parent.tabManager.mutate(tabId: tabId) { $0.pagination.isLoadingMore = false }
                        return
                    }
                    guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

                    parent.mutateActiveTableRows(for: tabId) { rows in
                        rows.replace(
                            rows: result.rows,
                            rowLocators: isTableTab ? result.rowLocators : nil,
                            absentCells: result.absentCells,
                            unloadedCells: result.unloadedCells
                        )
                    }
                    parent.tabManager.mutate(at: idx) { tab in
                        tab.execution.executionTime = result.executionTime
                        tab.schemaVersion += 1
                        tab.pagination.resetLoadMore()
                        tab.display.activeResultSet?.isTruncated = false
                    }
                    parent.toolbarState.recordQueryTiming(result.resolvedTiming, for: tabId)

                    let totalTime = CFAbsoluteTimeGetCurrent() - start
                    progressLog.info("[fetchAll] DONE rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s totalTime=\(String(format: "%.3f", totalTime))s")
                    parent.reportOperation(
                        kind: .fetchAll,
                        tabId: tabId,
                        startedAt: startedAt,
                        databaseName: parent.operationDatabaseName(tabId: tabId),
                        outcome: .succeeded(OperationSummary(rowsReturned: result.rows.count))
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let isStale = !parent.tabExecution.isSameContent(contentEpoch, for: tabId)
                    let isCancelled = DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.isLoadingMore = false
                        guard !isStale, !isCancelled else { return }
                        tab.execution.errorMessage = DatabaseWriteRejectionDiagnosis.formatted(error)
                    }
                    MainContentCoordinator.logger.error("Fetch all failed: \(error.publicLogShape, privacy: .public)")
                    guard !isStale, !isCancelled else { return }
                    parent.reportOperation(
                        kind: .fetchAll,
                        tabId: tabId,
                        startedAt: startedAt,
                        databaseName: parent.operationDatabaseName(tabId: tabId),
                        outcome: .failed(reason: error.localizedDescription)
                    )
                }
            }
        }
        parent.installQueryTask(fetchAllTask, owner: owner, lease: lease)
    }
}
