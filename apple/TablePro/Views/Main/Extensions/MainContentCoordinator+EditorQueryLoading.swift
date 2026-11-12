//
//  MainContentCoordinator+EditorQueryLoading.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    @discardableResult
    func loadQueryIntoEditor(
        _ query: String,
        databaseName: String? = nil,
        forceNewTab: Bool = false
    ) -> WindowTabOpenDisposition {
        let targetDatabaseName = databaseName ?? newTabDatabaseName
        if !forceNewTab,
           let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           databaseName == nil
           || tab.tableContext.resolvedDatabaseName(browsing: browseDatabaseName) == targetDatabaseName {
            replaceQueryText(inTab: tab.id, with: query)
            tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
            return .currentCoordinator
        }

        if !forceNewTab, tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: query, databaseName: targetDatabaseName)
            return .currentCoordinator
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: targetDatabaseName,
            initialQuery: query
        )
        openTabInNewWindow(payload)
        return .focusedElsewhere
    }

    var aiInsertReusesSelectedQueryTab: Bool {
        guard let (tab, _) = tabManager.selectedTabAndIndex, tab.tabType == .query else { return false }
        return tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func insertQueryFromAI(_ query: String) {
        if aiInsertReusesSelectedQueryTab, let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            replaceQueryText(inTab: tab.id, with: query)
            tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        } else if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: query, databaseName: newTabDatabaseName)
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                initialQuery: query
            )
            WindowManager.shared.openTab(payload: payload)
        }
    }

    func clearSelectedQuery() {
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return }
        replaceQueryText(inTab: tab.id, with: "")
    }

    // Through the mounted editor the change is one undoable edit; with no editor mounted the model takes the text,
    // and the version recorded first is the way back. Nil `reason` is for a caller that recorded already.
    @discardableResult
    func replaceQueryText(
        inTab tabId: UUID,
        range: NSRange? = nil,
        with text: String,
        recording reason: QueryTabVersionReason? = .beforeReplace
    ) -> Bool {
        flushEditorText(forTab: tabId)
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.tabType == .query else { return false }
        let current = tab.content.query as NSString
        let target = range ?? NSRange(location: 0, length: current.length)
        guard NSMaxRange(target) <= current.length else { return false }
        if let reason {
            tabVersions.record(tab, connectionId: connectionId, reason: reason)
        }
        let replacedInEditor = EditorEventRouter.shared.replaceText(
            forTab: tabId,
            connectionId: connectionId,
            in: target,
            with: text
        )
        if !replacedInEditor {
            let replaced = current.replacingCharacters(in: target, with: text)
            tabManager.mutate(tabId: tabId) { $0.content.query = replaced }
        }
        scheduleDraftSave(editedTab: tabId)
        syncQueryToolbarStateForSelectedTab()
        refreshUnsavedIndicator()
        return true
    }
}
