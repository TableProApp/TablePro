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

        // Check for unsaved changes — live changeManager for selected tab,
        // persisted pendingChanges for background tabs
        let hasUnsavedData = isSelected
            ? changeManager.hasChanges
            : tab.pendingChanges.hasChanges

        if hasUnsavedData {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Your changes will be lost if you don't save them."),
                    window: contentWindow
                )
                switch result {
                case .save:
                    if isSelected {
                        await self.saveDataChangesAndClose(tabId: id)
                    } else {
                        // Background tabs can't be saved through changeManager — discard and close.
                        // The dialog gives the user a chance to cancel and switch to the tab first.
                        removeTab(id)
                    }
                case .dontSave:
                    if isSelected {
                        changeManager.clearChangesAndUndoHistory()
                    }
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

        persistTabs()
    }

    private func saveDataChangesAndClose(tabId: UUID) async {
        guard saveCompletionContinuation == nil else { return }
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
                    // Bulk close can't individually save each tab's changes — changeManager
                    // only holds the active tab's state. Both options discard and close.
                    // The dialog gives users a chance to cancel and save individual tabs first.
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
        persistTabs()
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tabsToClose = Array(tabManager.tabs[(index + 1)...]).filter { !$0.isPinned }
        guard !tabsToClose.isEmpty else { return }

        let selectedIsBeingClosed = tabsToClose.contains { $0.id == tabManager.selectedTabId }
        let hasUnsavedWork = tabsToClose.contains { $0.pendingChanges.hasChanges || $0.isFileDirty }
            || (selectedIsBeingClosed && changeManager.hasChanges)

        if hasUnsavedWork {
            Task { @MainActor in
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Some tabs to the right have unsaved changes that will be lost."),
                    window: contentWindow
                )
                switch result {
                case .save, .dontSave:
                    if selectedIsBeingClosed {
                        changeManager.clearChangesAndUndoHistory()
                    }
                    forceCloseTabsToRight(of: id)
                case .cancel:
                    return
                }
            }
            return
        }

        forceCloseTabsToRight(of: id)
    }

    private func forceCloseTabsToRight(of id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        let toClose = Array(tabManager.tabs[(index + 1)...]).filter { !$0.isPinned }
        for tab in toClose {
            tabManager.pushClosedTab(tab)
            tab.rowBuffer.evict()
        }
        let closeIds = Set(toClose.map(\.id))
        tabManager.tabs.removeAll { closeIds.contains($0.id) }
        if let selectedId = tabManager.selectedTabId, closeIds.contains(selectedId) {
            tabManager.selectedTabId = id
        }
        persistTabs()
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
                    // Bulk close can't individually save each tab — see closeOtherTabs comment
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
        } else {
            tabManager.selectedTabId = tabManager.tabs.first?.id
        }
        persistTabs()
    }

    // MARK: - Reopen Closed Tab (Cmd+Shift+T)

    func reopenClosedTab() {
        guard var tab = tabManager.popClosedTab() else { return }
        tab.rowBuffer = RowBuffer()
        tab.pendingChanges = TabPendingChanges()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        if tab.tabType == .table, !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runQuery()
        }
        persistTabs()
    }

    // MARK: - Pin Tab

    func togglePinTab(_ id: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        tabManager.tabs[index].isPinned.toggle()

        // Stable sort: pinned tabs first, preserving relative order within each group
        let pinned = tabManager.tabs.filter(\.isPinned)
        let unpinned = tabManager.tabs.filter { !$0.isPinned }
        tabManager.tabs = pinned + unpinned

        persistTabs()
    }

    // MARK: - Persistence Helper

    /// Persist tabs to disk, excluding preview tabs (consistent with handleTabsChange).
    private func persistTabs() {
        let persistableTabs = tabManager.tabs.filter { !$0.isPreview }
        if persistableTabs.isEmpty {
            persistence.clearSavedState()
        } else {
            let selectedId = persistableTabs.contains(where: { $0.id == tabManager.selectedTabId })
                ? tabManager.selectedTabId : persistableTabs.first?.id
            persistence.saveNow(tabs: persistableTabs, selectedTabId: selectedId)
        }
    }

    // MARK: - Tab Reorder

    func reorderTabs(_ newOrder: [QueryTab]) {
        tabManager.tabs = newOrder
        persistTabs()
    }

    // MARK: - Tab Rename

    func renameTab(_ id: UUID, to name: String) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
        tabManager.tabs[index].title = name
        persistTabs()
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
