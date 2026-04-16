//
//  MainContentCoordinator+TabOperations.swift
//  TablePro
//
//  In-app tab bar operations: close, reorder, rename, duplicate, add.
//

import AppKit
import Foundation

extension MainContentCoordinator {
    // MARK: - Tab Close

    func closeInAppTab(_ id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }

        let tab = tabManager.tabs[index]
        let isSelected = tabManager.selectedTabId == id

        // Check for unsaved changes on this specific tab
        if isSelected && changeManager.hasChanges {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Your changes will be lost if you don't save them."),
                    window: contentWindow
                )
                switch result {
                case .save:
                    await self.saveDataChangesAndClose(tabId: id)
                case .dontSave:
                    changeManager.clearChangesAndUndoHistory()
                    removeTab(id)
                case .cancel:
                    return
                }
            }
            return
        }

        // Check for dirty file
        if tab.isFileDirty {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Your changes will be lost if you don't save them."),
                    window: contentWindow
                )
                switch result {
                case .save:
                    if let url = tab.sourceFileURL {
                        try? await SQLFileService.writeFile(content: tab.query, to: url)
                    }
                    removeTab(id)
                case .dontSave:
                    removeTab(id)
                case .cancel:
                    return
                }
            }
            return
        }

        removeTab(id)
    }

    private func removeTab(_ id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = tabManager.selectedTabId == id

        tabManager.tabs[index].rowBuffer.evict()
        tabManager.tabs.remove(at: index)

        if wasSelected {
            if tabManager.tabs.isEmpty {
                tabManager.selectedTabId = nil
                // Close the window when last tab is closed
                contentWindow?.close()
            } else {
                // Select adjacent tab (prefer left, fall back to right)
                let newIndex = min(index, tabManager.tabs.count - 1)
                tabManager.selectedTabId = tabManager.tabs[newIndex].id
            }
        }

        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    private func saveDataChangesAndClose(tabId: UUID) async {
        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]
        let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            saveCompletionContinuation = continuation
            saveChanges(pendingTruncates: &truncates, pendingDeletes: &deletes, tableOperationOptions: &options)
        }
        if saved {
            removeTab(tabId)
        }
    }

    func closeOtherTabs(excluding id: UUID) {
        let tabsToClose = tabManager.tabs.filter { $0.id != id }
        let selectedIsBeingClosed = tabManager.selectedTabId != id
        let hasUnsavedWork = tabsToClose.contains { $0.pendingChanges.hasChanges || $0.isFileDirty }
            || (selectedIsBeingClosed && changeManager.hasChanges)

        if hasUnsavedWork {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Some tabs have unsaved changes that will be lost."),
                    window: contentWindow
                )
                switch result {
                case .save, .dontSave:
                    if selectedIsBeingClosed {
                        changeManager.clearChangesAndUndoHistory()
                    }
                    forceCloseOtherTabs(excluding: id)
                case .cancel:
                    return
                }
            }
            return
        }

        forceCloseOtherTabs(excluding: id)
    }

    private func forceCloseOtherTabs(excluding id: UUID) {
        for index in tabManager.tabs.indices where tabManager.tabs[index].id != id {
            tabManager.tabs[index].rowBuffer.evict()
        }
        tabManager.tabs.removeAll { $0.id != id }
        tabManager.selectedTabId = id
        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    func closeAllTabs() {
        let hasUnsavedWork = tabManager.tabs.contains { $0.pendingChanges.hasChanges || $0.isFileDirty }
            || changeManager.hasChanges

        if hasUnsavedWork {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "You have unsaved changes that will be lost."),
                    window: contentWindow
                )
                switch result {
                case .save, .dontSave:
                    changeManager.clearChangesAndUndoHistory()
                    forceCloseAllTabs()
                case .cancel:
                    return
                }
            }
            return
        }

        forceCloseAllTabs()
    }

    private func forceCloseAllTabs() {
        for tab in tabManager.tabs {
            tab.rowBuffer.evict()
        }
        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil
        persistence.clearSavedState()
        contentWindow?.close()
    }

    // MARK: - Tab Reorder

    func reorderTabs(_ newOrder: [QueryTab]) {
        tabManager.tabs = newOrder
        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    // MARK: - Tab Rename

    func renameTab(_ id: UUID, to name: String) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        tabManager.tabs[index].title = name
        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    // MARK: - Add Tab

    func addNewQueryTab() {
        let allTabs = tabManager.tabs
        let title = QueryTabManager.nextQueryTitle(existingTabs: allTabs)
        tabManager.addTab(title: title, databaseName: connection.database)
    }

    // MARK: - Duplicate Tab

    func duplicateTab(_ id: UUID) {
        guard let sourceTab = tabManager.tabs.first(where: { $0.id == id }) else { return }

        switch sourceTab.tabType {
        case .table:
            if let tableName = sourceTab.tableName {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: sourceTab.databaseName
                )
            }
        case .query:
            tabManager.addTab(
                initialQuery: sourceTab.query,
                title: sourceTab.title + " Copy",
                databaseName: sourceTab.databaseName
            )
        case .createTable:
            tabManager.addCreateTableTab(databaseName: sourceTab.databaseName)
        case .erDiagram:
            openERDiagramTab()
        case .serverDashboard:
            openServerDashboardTab()
        }
    }
}
