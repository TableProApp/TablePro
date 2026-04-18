//
//  MainContentCoordinator+LoadMore.swift
//  TablePro
//
//  Progressive loading: Load More, Fetch All, and Cancel for query tabs.
//

import AppKit
import Foundation
import os

extension MainContentCoordinator {
    // MARK: - Cancel Current Query

    func cancelCurrentQuery() {
        currentQueryTask?.cancel()
        currentQueryTask = nil
        if let driver = DatabaseManager.shared.driver(for: connectionId) {
            try? driver.cancelQuery()
        }
        toolbarState.setExecuting(false)
        for idx in tabManager.tabs.indices {
            if tabManager.tabs[idx].isExecuting || tabManager.tabs[idx].pagination.isLoadingMore {
                var tab = tabManager.tabs[idx]
                tab.isExecuting = false
                tab.pagination.isLoadingMore = false
                tabManager.tabs[idx] = tab
            }
        }
    }

    // MARK: - Load More Rows

    func loadMoreRows() {
        guard let idx = tabManager.selectedTabIndex else { return }
        let tab = tabManager.tabs[idx]
        guard !tab.pagination.isLoadingMore,
              tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

        let tabId = tab.id
        let offset = tab.pagination.loadMoreOffset
        let limit = AppSettingsManager.shared.dataGrid.validatedQueryResultLimit
        let capturedGeneration = queryGeneration

        tabManager.tabs[idx].pagination.isLoadingMore = true

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }
                let pagedResult = try await driver.fetchNextPage(
                    query: baseQuery,
                    offset: offset,
                    limit: limit
                )

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard capturedGeneration == queryGeneration else {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].pagination.isLoadingMore = false
                        }
                        return
                    }
                    guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

                    var tab = tabManager.tabs[idx]
                    tab.rowBuffer.rows.append(contentsOf: pagedResult.rows)
                    tab.resultVersion += 1
                    tab.pagination.loadMoreOffset = pagedResult.nextOffset
                    tab.pagination.hasMoreRows = pagedResult.hasMore
                    tab.pagination.isLoadingMore = false
                    if !pagedResult.hasMore {
                        tab.pagination.baseQueryForMore = nil
                    }
                    tabManager.tabs[idx] = tab
                    if capturedGeneration == queryGeneration {
                        currentQueryTask = nil
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.isLoadingMore = false
                    }
                    currentQueryTask = nil
                    Self.logger.error("Load more failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Fetch All Rows

    func fetchAllRows() {
        guard let idx = tabManager.selectedTabIndex else { return }
        let tab = tabManager.tabs[idx]
        guard tab.pagination.hasMoreRows,
              let baseQuery = tab.pagination.baseQueryForMore else { return }

        let loadedCount = tab.resultRows.count
        let totalEstimate = tab.pagination.totalRowCount

        let message: String
        if let total = totalEstimate {
            let remaining = total - loadedCount
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

        let limit = AppSettingsManager.shared.dataGrid.validatedQueryResultLimit
        let capturedGeneration = queryGeneration

        tabManager.tabs[idx].pagination.isLoadingMore = true
        toolbarState.setExecuting(true)

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }

                var currentOffset = await MainActor.run {
                    tabManager.tabs.first { $0.id == tabId }?.pagination.loadMoreOffset ?? 0
                }

                while !Task.isCancelled {
                    let pagedResult = try await driver.fetchNextPage(
                        query: baseQuery,
                        offset: currentOffset,
                        limit: limit
                    )

                    guard !Task.isCancelled else { break }

                    let hasMore = pagedResult.hasMore
                    let nextOffset = pagedResult.nextOffset
                    let newRows = pagedResult.rows

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard capturedGeneration == queryGeneration else { return }
                        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

                        var tab = tabManager.tabs[idx]
                        tab.rowBuffer.rows.append(contentsOf: newRows)
                        tab.resultVersion += 1
                        tab.pagination.loadMoreOffset = nextOffset
                        tab.pagination.hasMoreRows = hasMore
                        if !hasMore {
                            tab.pagination.isLoadingMore = false
                            tab.pagination.baseQueryForMore = nil
                        }
                        tabManager.tabs[idx] = tab
                    }

                    if !hasMore { break }
                    currentOffset = nextOffset
                    await Task.yield()
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.isLoadingMore = false
                    }
                    toolbarState.setExecuting(false)
                    if capturedGeneration == queryGeneration {
                        currentQueryTask = nil
                    }
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
