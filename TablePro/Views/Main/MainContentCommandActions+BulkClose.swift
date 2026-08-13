//
//  MainContentCommandActions+BulkClose.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCommandActions {
    enum BatchCloseKind: Equatable {
        case all
        case others
        case otherDatabases
        case container(String)
    }

    /// Closes a workspace from the rail: every tab of this connection sitting in that container.
    func closeWorkspace(container: String) {
        Task { await runBatchClose(kind: .container(container)) }
    }

    func closeAllTabs() {
        Task { await runBatchClose(kind: .all) }
    }

    func closeOtherTabs() {
        Task { await runBatchClose(kind: .others) }
    }

    func closeTabsForOtherDatabases() {
        Task { await runBatchClose(kind: .otherDatabases) }
    }

    var canCloseAllTabs: Bool {
        !tabsToClose(kind: .all).isEmpty
    }

    var canCloseOtherTabs: Bool {
        !tabsToClose(kind: .others).isEmpty
    }

    var canCloseTabsForOtherDatabases: Bool {
        guard supportsContainerSwitching else { return false }
        return !tabsToClose(kind: .otherDatabases).isEmpty
    }

    /// The container the connection is browsing, named the way this engine names containers.
    /// Comparing a schema-switching engine's tabs against a database name classified nothing.
    var browsedContainerName: String {
        let target = PluginManager.shared.containerSwitchTarget(for: currentDatabaseType)
        guard let session = DatabaseManager.shared.session(for: connectionId) else {
            return target == .schema ? "" : browseDatabaseName
        }
        return WorkspaceAnchoring.browsedContainer(of: session, target: target) ?? ""
    }

    var closeTabsForOtherDatabasesTitle: String {
        switch PluginManager.shared.containerSwitchTarget(for: currentDatabaseType) {
        case .schema:
            return String(localized: "Close Tabs for Other Schemas")
        case .database, .none:
            return String(localized: "Close Tabs for Other Databases")
        }
    }

    /// Tabs live in one window now, so a batch close is a list edit rather than a walk over
    /// sibling windows. Closing every tab is still a window close, which already owns the save
    /// prompt and the recovery capture, so that case is handed straight to it.
    /// Closing every tab leaves the connection on its empty state rather than closing the window,
    /// because the window is no longer this connection's window: it hosts all of them.
    private func runBatchClose(kind: BatchCloseKind) async {
        guard let coordinator else { return }
        let victims = tabsToClose(kind: kind)
        guard !victims.isEmpty else { return }
        guard await confirmDiscardingUnsavedWork() else { return }
        coordinator.closeTabsByUser(ids: victims.map(\.id))
    }

    /// A partial close leaves the window open, so it cannot lean on the window's own prompt.
    /// Unsaved work is tracked for the connection rather than per tab, so the question is asked
    /// once for the batch.
    func confirmDiscardingUnsavedWork() async -> Bool {
        guard hasUnsavedWorkInWindow else { return true }

        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: closeAnchorWindow
        ) {
        case .save:
            saveChanges()
            return false
        case .dontSave:
            return true
        case .cancel:
            return false
        }
    }

    private func tabsToClose(kind: BatchCloseKind) -> [QueryTab] {
        guard let coordinator else { return [] }
        let tabs = coordinator.tabManager.tabs
        let target = PluginManager.shared.containerSwitchTarget(for: currentDatabaseType)

        switch kind {
        case .all:
            return tabs
        case .others:
            guard let selectedId = coordinator.tabManager.selectedTab?.id else { return [] }
            return tabs.filter { $0.id != selectedId }
        case .otherDatabases:
            let current = browsedContainerName
            return tabs.filter { WorkspaceAnchoring.containerName(of: $0, target: target) != current }
        case .container(let container):
            return tabs.filter { WorkspaceAnchoring.containerName(of: $0, target: target) == container }
        }
    }
}
