//
//  MainContentCoordinator+LoadMore.swift
//  TablePro
//
//  Progressive loading: Load More, Fetch All, and Cancel for query tabs.
//

import AppKit
import Foundation
import os

private let progressLog = Logger(subsystem: "com.TablePro", category: "ProgressiveLoad")

extension MainContentCoordinator {
    // MARK: - Cancel Current Query

    func cancelCurrentQuery() {
        currentQueryTask?.cancel()
        currentQueryTask = nil
        queryGeneration += 1
        if let driver = DatabaseManager.shared.driver(for: connectionId) {
            try? driver.cancelQuery()
        }
        toolbarState.setExecuting(false)
        for idx in tabManager.tabs.indices {
            if tabManager.tabs[idx].execution.isExecuting || tabManager.tabs[idx].pagination.isLoadingMore {
                var tab = tabManager.tabs[idx]
                tab.execution.isExecuting = false
                tab.pagination.isLoadingMore = false
                tabManager.tabs[idx] = tab
            }
        }
    }

    // MARK: - Load More Rows

    func loadMoreRows() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              !tab.pagination.isLoadingMore,
              !tab.execution.isExecuting,
              tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

        let tabId = tab.id
        let offset = tab.pagination.loadMoreOffset
        let limit = AppSettingsManager.shared.dataGrid.validatedQueryResultLimit
        let capturedGeneration = queryGeneration
        let storedParamValues = tab.pagination.baseQueryParameterValues

        tabManager.tabs[tabIndex].pagination.isLoadingMore = true
        toolbarState.setExecuting(true)

        currentQueryTask = Task { [weak self] in
            guard let self, !isTearingDown else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }
                let fetchStart = CFAbsoluteTimeGetCurrent()
                progressLog.info("[loadMore] offset=\(offset) limit=\(limit)")
                let pagedResult: PagedQueryResult
                if let paramValues = storedParamValues {
                    let anyParams: [Any?] = paramValues.map { $0 as Any? }
                    pagedResult = try await driver.fetchNextPageParameterized(
                        query: baseQuery,
                        parameters: anyParams,
                        offset: offset,
                        limit: limit
                    )
                } else {
                    pagedResult = try await driver.fetchNextPage(
                        query: baseQuery,
                        offset: offset,
                        limit: limit
                    )
                }
                let fetchElapsed = CFAbsoluteTimeGetCurrent() - fetchStart
                progressLog.info("[loadMore] rows=\(pagedResult.rows.count) hasMore=\(pagedResult.hasMore) fetchTime=\(String(format: "%.3f", fetchElapsed))s")

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, !isTearingDown else { return }
                    guard capturedGeneration == queryGeneration else {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].pagination.isLoadingMore = false
                        }
                        toolbarState.setExecuting(false)
                        return
                    }
                    guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                        toolbarState.setExecuting(false)
                        return
                    }

                    var tab = tabManager.tabs[idx]
                    var pageOffset = 0
                    let appendDelta = mutateActiveTableRows(for: tab.id) { rows in
                        pageOffset = rows.count
                        return rows.appendPage(pagedResult.rows, startingAt: rows.count)
                    }
                    let newCount = pageOffset + pagedResult.rows.count
                    tab.schemaVersion += 1
                    tab.pagination.loadMoreOffset = pagedResult.nextOffset
                    tab.pagination.hasMoreRows = pagedResult.hasMore
                    tab.pagination.isLoadingMore = false
                    if !pagedResult.hasMore {
                        tab.pagination.baseQueryForMore = nil
                    }
                    tabManager.tabs[idx] = tab
                    dataTabDelegate?.tableViewCoordinator?.applyDelta(appendDelta)
                    toolbarState.setExecuting(false)
                    if capturedGeneration == queryGeneration {
                        currentQueryTask = nil
                    }
                    progressLog.info("[loadMore] applied totalRows=\(newCount)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.isLoadingMore = false
                    }
                    toolbarState.setExecuting(false)
                    currentQueryTask = nil
                    Self.logger.error("Load more failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Fetch All Rows

    func fetchAllRows() {
        guard let (tab, _) = tabManager.selectedTabAndIndex,
              !tab.pagination.isLoadingMore,
              !tab.execution.isExecuting,
              tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

        let loadedCount = tableRowsStore.tableRows(for: tab.id).rows.count
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

        let window = contentWindow ?? NSApp.keyWindow
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.performFetchAll(tabId: tab.id, baseQuery: baseQuery)
            }
        } else {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            performFetchAll(tabId: tab.id, baseQuery: baseQuery)
        }
    }

    private func performFetchAll(tabId: UUID, baseQuery: String) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard !tabManager.tabs[idx].pagination.isLoadingMore else { return }

        let capturedGeneration = queryGeneration
        let storedParamValues = tabManager.tabs[idx].pagination.baseQueryParameterValues

        tabManager.tabs[idx].pagination.isLoadingMore = true
        toolbarState.setExecuting(true)

        currentQueryTask = Task { [weak self] in
            guard let self, !isTearingDown else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }

                let start = CFAbsoluteTimeGetCurrent()
                progressLog.info("[fetchAll] executing full query: \(baseQuery.prefix(100), privacy: .public)")
                let result: QueryResult
                if let paramValues = storedParamValues {
                    let anyParams: [Any?] = paramValues.map { $0 as Any? }
                    result = try await driver.executeParameterized(query: baseQuery, parameters: anyParams)
                } else {
                    result = try await driver.execute(query: baseQuery)
                }
                let fetchTime = CFAbsoluteTimeGetCurrent() - start
                progressLog.info("[fetchAll] rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s")

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, !isTearingDown else { return }
                    guard capturedGeneration == queryGeneration else {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].pagination.isLoadingMore = false
                        }
                        toolbarState.setExecuting(false)
                        return
                    }
                    guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                        toolbarState.setExecuting(false)
                        return
                    }

                    var tab = tabManager.tabs[idx]
                    let replaceDelta = mutateActiveTableRows(for: tab.id) { rows in
                        rows.replace(rows: result.rows)
                    }
                    tab.execution.executionTime = result.executionTime
                    tab.schemaVersion += 1
                    tab.pagination.resetLoadMore()
                    tabManager.tabs[idx] = tab
                    dataTabDelegate?.tableViewCoordinator?.applyDelta(replaceDelta)
                    toolbarState.setExecuting(false)
                    toolbarState.lastQueryDuration = result.executionTime
                    currentQueryTask = nil

                    let totalTime = CFAbsoluteTimeGetCurrent() - start
                    progressLog.info("[fetchAll] DONE rows=\(result.rows.count) fetchTime=\(String(format: "%.3f", fetchTime))s totalTime=\(String(format: "%.3f", totalTime))s")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.isLoadingMore = false
                    }
                    toolbarState.setExecuting(false)
                    if capturedGeneration == queryGeneration {
                        currentQueryTask = nil
                    }
                    Self.logger.error("Fetch all failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
