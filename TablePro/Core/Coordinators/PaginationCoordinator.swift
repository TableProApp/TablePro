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
        paginateIfPossible(where: \.hasNextPage) { $0.goToNextPage() }
    }

    func goToPreviousPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToPreviousPage() }
    }

    func goToFirstPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToFirstPage() }
    }

    func goToLastPage() {
        paginateIfPossible(where: { $0.currentPage != $0.totalPages }) { $0.goToLastPage() }
    }

    func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        paginateIfPossible { $0.updatePageSize(newSize) }
    }

    func updateOffset(_ newOffset: Int) {
        guard newOffset >= 0 else { return }
        paginateIfPossible { $0.updateOffset(newOffset) }
    }

    func applyPaginationSettings() {
        reloadCurrentPage()
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
        parent.currentQueryTask?.cancel()
        parent.currentQueryTask = nil
        parent.queryGeneration += 1
        if let driver = DatabaseManager.shared.driver(for: parent.connectionId) {
            try? driver.cancelQuery()
        }
        parent.toolbarState.setExecuting(false)
        for idx in parent.tabManager.tabs.indices {
            if parent.tabManager.tabs[idx].execution.isExecuting
                || parent.tabManager.tabs[idx].pagination.isLoadingMore {
                parent.tabManager.mutate(at: idx) { tab in
                    tab.execution.isExecuting = false
                    tab.pagination.isLoadingMore = false
                }
            }
        }
    }

    // MARK: - Fetch All Rows

    func fetchAllRows() {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex,
              !tab.pagination.isLoadingMore,
              !tab.execution.isExecuting,
              tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

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

        let alert = NSAlert()
        alert.messageText = String(localized: "Fetch All Rows")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Fetch All"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let window = parent.contentWindow ?? NSApp.keyWindow
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                performFetchAll(tabId: tab.id, baseQuery: baseQuery)
            }
        } else {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            performFetchAll(tabId: tab.id, baseQuery: baseQuery)
        }
    }

    private func performFetchAll(tabId: UUID, baseQuery: String) {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard !parent.tabManager.tabs[idx].pagination.isLoadingMore else { return }

        let capturedGeneration = parent.queryGeneration
        let storedParamValues = parent.tabManager.tabs[idx].pagination.baseQueryParameterValues

        parent.tabManager.mutate(at: idx) { $0.pagination.isLoadingMore = true }
        parent.toolbarState.setExecuting(true)

        parent.currentQueryTask = Task { [weak self, parent] in
            guard let self, !parent.isTearingDown else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: parent.connectionId) else {
                    throw DatabaseError.notConnected
                }

                let start = CFAbsoluteTimeGetCurrent()
                progressLog.info("[fetchAll] executing full query: \(baseQuery.prefix(100), privacy: .public)")
                let anyParams: [Any?]? = storedParamValues.map { $0.map { $0 as Any? } }
                let result = try await driver.executeUserQuery(
                    query: baseQuery,
                    rowCap: nil,
                    parameters: anyParams
                )
                let fetchTime = CFAbsoluteTimeGetCurrent() - start
                progressLog.info("[fetchAll] rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s")

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, !parent.isTearingDown else { return }
                    guard capturedGeneration == parent.queryGeneration else {
                        parent.tabManager.mutate(tabId: tabId) { $0.pagination.isLoadingMore = false }
                        parent.toolbarState.setExecuting(false)
                        return
                    }
                    guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                        parent.toolbarState.setExecuting(false)
                        return
                    }

                    let replaceDelta = parent.mutateActiveTableRows(for: tabId) { rows in
                        rows.replace(rows: result.rows)
                    }
                    parent.tabManager.mutate(at: idx) { tab in
                        tab.execution.executionTime = result.executionTime
                        tab.schemaVersion += 1
                        tab.pagination.resetLoadMore()
                    }
                    parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(replaceDelta)
                    parent.toolbarState.setExecuting(false)
                    parent.toolbarState.lastQueryDuration = result.executionTime
                    parent.currentQueryTask = nil

                    let totalTime = CFAbsoluteTimeGetCurrent() - start
                    progressLog.info("[fetchAll] DONE rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s totalTime=\(String(format: "%.3f", totalTime))s")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    parent.tabManager.mutate(tabId: tabId) { $0.pagination.isLoadingMore = false }
                    parent.toolbarState.setExecuting(false)
                    if capturedGeneration == parent.queryGeneration {
                        parent.currentQueryTask = nil
                    }
                    MainContentCoordinator.logger.error("Fetch all failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
