//
//  MainContentCoordinator+TabOperations.swift
//  TablePro
//
//  In-app tab bar operations: close, reorder, rename, duplicate, pin, reopen.
//

import AppKit
import Foundation

extension MainContentCoordinator {
    // MARK: - Tab Close

    func closeInAppTab(_ id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }

        let tab = tabManager.tabs[index]

        // Pinned tabs cannot be closed
        guard !tab.isPinned else { return }

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

        // Snapshot for Cmd+Shift+T reopen before eviction
        tabManager.pushClosedTab(tabManager.tabs[index])

        tabManager.tabs[index].rowBuffer.evict()
        tabManager.tabs.remove(at: index)

        if wasSelected {
            if tabManager.tabs.isEmpty {
                tabManager.selectedTabId = nil
            } else {
                // MRU: select the most recently active tab, not just adjacent
                tabManager.selectedTabId = tabManager.mruTabId(excluding: id)
                    ?? tabManager.tabs[min(index, tabManager.tabs.count - 1)].id
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
        // Skip pinned tabs — they survive "Close Others"
        let tabsToClose = tabManager.tabs.filter { $0.id != id && !$0.isPinned }
        let selectedIsBeingClosed = tabsToClose.contains { $0.id == tabManager.selectedTabId }
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
        for tab in tabManager.tabs where tab.id != id && !tab.isPinned {
            tabManager.pushClosedTab(tab)
            tab.rowBuffer.evict()
        }
        tabManager.tabs.removeAll { $0.id != id && !$0.isPinned }
        tabManager.selectedTabId = id
        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    func closeAllTabs() {
        // Skip pinned tabs — they survive "Close All"
        let closableTabs = tabManager.tabs.filter { !$0.isPinned }
        guard !closableTabs.isEmpty else { return }

        let hasUnsavedWork = closableTabs.contains { $0.pendingChanges.hasChanges || $0.isFileDirty }
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
        let closable = tabManager.tabs.filter { !$0.isPinned }
        for tab in closable {
            tabManager.pushClosedTab(tab)
            tab.rowBuffer.evict()
        }
        tabManager.tabs.removeAll { !$0.isPinned }

        if tabManager.tabs.isEmpty {
            tabManager.selectedTabId = nil
            persistence.clearSavedState()
        } else {
            // Pinned tabs remain — select the first one
            tabManager.selectedTabId = tabManager.tabs.first?.id
            persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
        }
    }

    // MARK: - Reopen Closed Tab (Cmd+Shift+T)

    func reopenClosedTab() {
        guard var tab = tabManager.popClosedTab() else { return }
        tab.rowBuffer = RowBuffer()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        if tab.tabType == .table, !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runQuery()
        }
        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
    }

    // MARK: - Pin Tab

    func togglePinTab(_ id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        tabManager.tabs[index].isPinned.toggle()

        // Stable sort: pinned tabs first, preserving relative order within each group
        let pinned = tabManager.tabs.filter(\.isPinned)
        let unpinned = tabManager.tabs.filter { !$0.isPinned }
        tabManager.tabs = pinned + unpinned

        persistence.saveNow(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
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
