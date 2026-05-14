//
//  MainContentCoordinator+TabIntent.swift
//  TablePro
//
//  In-window tab lifecycle: adding tabs from intents, closing the current
//  tab, and adding a new empty query tab.
//

import AppKit
import Foundation
import os

private let tabIntentLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator+TabIntent")

extension MainContentCoordinator {
    // MARK: - New Tab

    /// Add a new empty query tab and select it.
    func addNewQueryTab(initialQuery: String? = nil) {
        let title = QueryTabManager.nextQueryTitle(existingTabs: tabManager.tabs)
        tabManager.addTab(
            initialQuery: initialQuery,
            title: title,
            databaseName: activeDatabaseName
        )
    }

    // MARK: - Close Tab

    /// Remove the currently selected tab. When it is the last tab, close the
    /// connection window instead.
    func closeCurrentTab() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            contentWindow?.performClose(nil)
            return
        }

        if tabManager.tabs.count <= 1 {
            contentWindow?.performClose(nil)
            return
        }

        tabSessionRegistry.removeTableRows(for: tab.id)
        if let url = tab.content.sourceFileURL {
            WindowLifecycleMonitor.shared.unregisterSourceFile(url)
        }
        querySortCache.removeValue(forKey: tab.id)
        displayFormatsCache.removeValue(forKey: tab.id)
        tabManager.removeTab(id: selectedId)
    }

    // MARK: - New Tab Intent

    /// Route an `EditorTabPayload` into a new in-window tab on this
    /// connection's tab manager.
    func handleNewTabIntent(_ payload: EditorTabPayload) {
        switch payload.intent {
        case .openContent:
            applyOpenContentIntent(payload)
        case .newEmptyTab:
            addNewQueryTab(initialQuery: payload.initialQuery)
        case .restoreOrDefault:
            tabIntentLogger.warning("handleNewTabIntent received .restoreOrDefault, ignored")
        }

        if let sourceFileURL = payload.sourceFileURL, let windowId {
            WindowLifecycleMonitor.shared.registerSourceFile(sourceFileURL, windowId: windowId)
        }
        contentWindow?.makeKeyAndOrderFront(nil)
    }

    private func applyOpenContentIntent(_ payload: EditorTabPayload) {
        let databaseName = payload.databaseName ?? activeDatabaseName

        switch payload.tabType {
        case .table:
            guard let tableName = payload.tableName else {
                tabManager.addTab(databaseName: databaseName)
                return
            }
            do {
                if payload.isPreview {
                    try tabManager.addPreviewTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: databaseName
                    )
                } else {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: databaseName
                    )
                }
            } catch {
                tabIntentLogger.error(
                    "addTableTab failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            if let index = tabManager.selectedTabIndex {
                tabManager.mutate(at: index) { tab in
                    tab.tableContext.isView = payload.isView
                    tab.tableContext.isEditable = !payload.isView
                    tab.tableContext.schemaName = payload.schemaName
                    if payload.showStructure {
                        tab.display.resultsViewMode = .structure
                    }
                    if let initialFilter = payload.initialFilterState {
                        tab.filterState = initialFilter
                    }
                }
            }
            toolbarState.isTableTab = true

        case .query:
            let hasContent = payload.initialQuery != nil
                || payload.tabTitle != nil
                || payload.sourceFileURL != nil
            guard hasContent else { return }
            tabManager.addTab(
                initialQuery: payload.initialQuery,
                title: payload.tabTitle,
                databaseName: databaseName,
                sourceFileURL: payload.sourceFileURL
            )

        case .createTable:
            tabManager.addCreateTableTab(databaseName: databaseName)

        case .erDiagram:
            tabManager.addERDiagramTab(
                schemaKey: payload.erDiagramSchemaKey ?? databaseName,
                databaseName: databaseName
            )

        case .serverDashboard:
            tabManager.addServerDashboardTab()

        case .terminal:
            tabManager.addTerminalTab(databaseName: databaseName)
        }
    }
}
