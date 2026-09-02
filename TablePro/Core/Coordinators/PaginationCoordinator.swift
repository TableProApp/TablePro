//
//  PaginationCoordinator.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let progressLog = Logger(subsystem: "com.TablePro", category: "ProgressiveLoad")

@MainActor @Observable
final class PaginationCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Pagination

    func goToNextPage() {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        let loadedRowCount = parent.tabSessionRegistry.tableRows(for: tab.id).rows.count
        guard tab.pagination.canGoToNextPage(loadedRowCount: loadedRowCount) else { return }
        paginateAfterConfirmation(tabIndex: tabIndex) { $0.goToNextPage(loadedRowCount: loadedRowCount) }
    }

    func goToPreviousPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToPreviousPage() }
    }

    func goToFirstPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToFirstPage() }
    }

    func goToLastPage() {
        paginateIfPossible(where: { $0.isLastPageKnown && $0.currentPage != $0.totalPages }) { $0.goToLastPage() }
    }

    func goToPage(_ page: Int) {
        paginateIfPossible(where: { $0.hasRowCountTotal && page > 0 }) { $0.goToPage(page) }
    }

    func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        paginateIfPossible { $0.updatePageSize(newSize) }
    }

    /// Only ever sized from a real count.
    ///
    /// It used to accept the driver's estimate, so a table MySQL guessed at 420,000 rows loaded
    /// `LIMIT 420000` and silently dropped the rest while the bar reported the page as complete.
    /// `Count Exactly` in the status bar is the route to an exact total, and it sits next to the
    /// estimate that makes this unavailable.
    func showAllRows() {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex,
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
            parent.pendingScrollToTopAfterReplace.insert(tabId)
            reloadCurrentPage()
        }
    }

    private func reloadCurrentPage() {
        guard let tabIndex = parent.tabManager.selectedTabIndex,
              tabIndex < parent.tabManager.tabs.count else { return }

        parent.rebuildTableQuery(at: tabIndex)
        parent.runQuery()
    }

    // MARK: - Cancel Current Query

    func cancelCurrentQuery() {
        parent.cancelInFlightQueryTask()
        parent.cancelAllRowCountTasks()
        parent.releaseAllExactCounts()
        parent.reportEndedExecutions(parent.tabExecution.invalidateAll(reason: .cancelledByUser))
        for idx in parent.tabManager.tabs.indices where parent.tabManager.tabs[idx].pagination.isBusy {
            parent.tabManager.mutate(at: idx) { tab in
                tab.pagination.isLoadingMore = false
                tab.pagination.isCountingExact = false
                tab.pagination.isCountPending = false
                tab.pagination.isLoading = false
            }
        }
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
        let isNonSQL = PluginManager.shared.editorLanguage(for: parent.connection.type) != .sql
        let buffer = parent.tabSessionRegistry.tableRows(for: tabId)
        let countSQL = isNonSQL ? nil : parent.queryBuilder.buildFilteredCountQuery(
            tableName: tableName, schemaName: schemaName, filters: filters, logicMode: logicMode,
            columns: buffer.columns, columnTypes: buffer.columnTypes
        )

        /// Taking the task slot supersedes whatever automatic count held it, so this claims that
        /// count's flag too. Leaving it set would strand it: the superseded task's completion finds
        /// the token changed and correctly declines to clear a successor's state.
        parent.tabManager.mutate(at: index) { tab in
            tab.pagination.isCountingExact = true
            tab.pagination.isCountPending = false
        }

        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let token = UUID()
        parent.claimExactCount(for: tabId, token: token)
        let task = Task(priority: .userInitiated) { [parent] in
            let count = await Self.exactRowCount(
                scope: scope,
                tableName: tableName,
                filters: filters,
                logicMode: logicMode,
                countSQL: countSQL
            )

            /// The flag says a count is running, so it has to clear on every way out. Returning
            /// early on cancellation left it set, and a page turn cancels this task, so turning a
            /// page during a long COUNT(*) used to leave a spinner that never stopped and a
            /// `Count Exactly` that never came back for that tab.
            let isCurrent = !Task.isCancelled && parent.tabExecution.isSameContent(contentEpoch, for: tabId)
            /// Cancelling through `Cmd+.` clears the flag and lets a second count start, so a late
            /// first task would otherwise stop the second one's spinner while its query still runs.
            let ownsIndicator = parent.releaseExactCount(for: tabId, token: token)
            parent.clearRowCountTask(for: tabId, token: token)
            parent.tabManager.mutate(tabId: tabId) { tab in
                if ownsIndicator {
                    tab.pagination.isCountingExact = false
                }
                guard isCurrent, let count, count >= 0 else { return }
                tab.pagination.totalRowCount = count
                tab.pagination.isApproximateRowCount = false
            }
        }
        parent.setRowCountTask(task, token: token, for: tabId)
    }

    private static func exactRowCount(
        scope: DatabaseScope,
        tableName: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        countSQL: String?
    ) async -> Int? {
        try? await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            guard let countSQL else {
                return try await driver.fetchExactRowCount(
                    table: tableName, filters: filters, logicMode: logicMode
                )
            }
            let result = try await driver.execute(query: countSQL)
            guard let countStr = result.rows.first?.first?.asText else { return Int?.none }
            return Int(countStr)
        }
    }

    // MARK: - Fetch All Rows

    /// The scope is read before the confirmation alert, so a database change made while
    /// the alert is open cannot send the tab's own query somewhere else.
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

    /// Only the driver work runs inside the lease. Applying the rows to the tab stays
    /// outside it, because the connection's driver gate is not reentrant.
    ///
    /// The rows belong to the result the fetch was started on. A result switch leaves the content
    /// epoch alone, so the fetch is fenced on the result set as well, or the full row set lands on
    /// whichever result is showing when it arrives, normalized to that result's column count.
    private func performFetchAll(tabId: UUID, baseQuery: String, scope: DatabaseScope) {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard !parent.tabManager.tabs[idx].pagination.isLoadingMore else { return }

        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let resultSetId = parent.tabManager.tabs[idx].display.activeResultSetId
        let storedParamValues = parent.tabManager.tabs[idx].pagination.baseQueryParameterValues

        parent.tabManager.mutate(at: idx) { $0.pagination.isLoadingMore = true }

        /// Fetch All extends the result already on screen instead of replacing it, so it validates
        /// against the tab's content epoch and cannot claim the tab: claiming mints a new epoch and
        /// would discard its own rows. It registers as unclaimed work instead, which is what keeps
        /// the titlebar reporting it, and releases that on every exit including cancellation.
        let workToken = parent.tabExecution.beginUnclaimedWork(for: tabId)

        let route = DatabaseManager.shared.executionRoute(for: scope)

        let startedAt = ContinuousClock.Instant.now
        let fetchAllTask = Task { [weak self, parent] in
            defer { parent.tabExecution.endUnclaimedWork(workToken, for: tabId) }
            guard let self, !parent.isTearingDown else { return }

            do {
                let start = CFAbsoluteTimeGetCurrent()
                progressLog.info("[fetchAll] executing full query: \(baseQuery.prefix(100), privacy: .public)")
                let result = try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: route,
                    cancellation: .cancellableRead
                ) { driver in
                    try await driver.executeUserQuery(
                        query: baseQuery,
                        rowCap: nil,
                        parameters: storedParamValues.map { $0.map { $0 as Any? } }
                    )
                }
                let fetchTime = CFAbsoluteTimeGetCurrent() - start
                progressLog.info("[fetchAll] rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s")

                guard !Task.isCancelled else {
                    /// Every other exit from this function clears the flag, and this one used to
                    /// bare return, so a fetch-all cancelled after its rows had already arrived
                    /// left the tab showing "Loading…" for good with Fetch All hidden, healed
                    /// only by re-running the query. Deterministic on any driver whose
                    /// `cancelQuery()` is the PluginKit no-op default, because the fetch always
                    /// runs to completion there and returns straight into this guard.
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
                        parent.retireQueryTask(for: nil)
                        return
                    }
                    guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                        parent.retireQueryTask(for: nil)
                        return
                    }

                    let replaceDelta = parent.mutateActiveTableRows(for: tabId) { rows in
                        rows.replace(rows: result.rows)
                    }
                    parent.tabManager.mutate(at: idx) { tab in
                        tab.execution.executionTime = result.executionTime
                        tab.schemaVersion += 1
                        tab.pagination.resetLoadMore()
                        tab.display.activeResultSet?.isTruncated = false
                    }
                    parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(replaceDelta)
                    parent.retireQueryTask(for: nil)
                    parent.toolbarState.lastQueryTiming = result.resolvedTiming

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
                    parent.retireQueryTask(for: nil)
                    MainContentCoordinator.logger.error("Fetch all failed: \(error.localizedDescription, privacy: .public)")
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
        parent.installQueryTask(fetchAllTask, for: nil)
    }
}
