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
                tabManager.mutate(at: idx) { tab in
                    tab.execution.isExecuting = false
                    tab.pagination.isLoadingMore = false
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

        let loadedCount = tabSessionRegistry.tableRows(for: tab.id).rows.count
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

        tabManager.mutate(at: idx) { $0.pagination.isLoadingMore = true }
        toolbarState.setExecuting(true)

        currentQueryTask = Task { [weak self] in
            guard let self, !isTearingDown else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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
                    guard let self, !isTearingDown else { return }
                    guard capturedGeneration == queryGeneration else {
                        tabManager.mutate(tabId: tabId) { $0.pagination.isLoadingMore = false }
                        toolbarState.setExecuting(false)
                        return
                    }
                    guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                        toolbarState.setExecuting(false)
                        return
                    }

                    let replaceDelta = mutateActiveTableRows(for: tabId) { rows in
                        rows.replace(rows: result.rows)
                    }
                    tabManager.mutate(at: idx) { tab in
                        tab.execution.executionTime = result.executionTime
                        tab.schemaVersion += 1
                        tab.pagination.resetLoadMore()
                    }
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
                    tabManager.mutate(tabId: tabId) { $0.pagination.isLoadingMore = false }
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
