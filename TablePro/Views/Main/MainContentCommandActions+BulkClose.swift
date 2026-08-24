//
//  MainContentCommandActions+BulkClose.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCommandActions {
    enum BatchCloseKind: Equatable {
        case all
        /// Anchored explicitly, because a contextual menu acts on the tab under the pointer and
        /// that is not always the selected one.
        case others(anchor: UUID)
        case otherDatabases
    }

    func closeAllTabs() {
        Task { await runBatchClose(kind: .all) }
    }

    func closeOtherTabs() {
        guard let anchor = coordinator?.tabManager.selectedTab?.id else { return }
        closeOtherTabs(anchoredOn: anchor)
    }

    func closeOtherTabs(anchoredOn anchor: UUID) {
        Task { await runBatchClose(kind: .others(anchor: anchor)) }
    }

    func closeTabsForOtherDatabases() {
        Task { await runBatchClose(kind: .otherDatabases) }
    }

    var canCloseAllTabs: Bool {
        !tabsToClose(kind: .all).isEmpty
    }

    var canCloseOtherTabs: Bool {
        guard let anchor = coordinator?.tabManager.selectedTab?.id else { return false }
        return !tabsToClose(kind: .others(anchor: anchor)).isEmpty
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
        containerSwitchTitle(
            schema: String(localized: "Close Tabs for Other Schemas"),
            database: String(localized: "Close Tabs for Other Databases")
        )
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
        guard await confirmDiscardingUnsavedWork(victims: victims) else { return }
        coordinator.closeTabsByUser(ids: victims.map(\.id))
    }

    /// A partial close leaves the window open, so it cannot lean on the window's own prompt.
    /// Unsaved work is tracked for the connection rather than per tab, so the question is asked
    /// once for the batch rather than once per tab, which is also what keeps the sheets from
    /// queueing: `NSWindow.beginSheet` queues a second sheet behind the first rather than
    /// presenting it, so N prompts would be answered one at a time with no way to see why.
    ///
    /// Save goes on to close. This used to save and then return false, which left the batch
    /// standing after a successful save and made Save mean "cancel" on this path while it meant
    /// "close" on the window path.
    func confirmDiscardingUnsavedWork(victims: [QueryTab] = []) async -> Bool {
        guard hasUnsavedWork(among: victims) else { return true }

        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: closeAnchorWindow
        ) {
        case .save:
            guard await applyStagedStructureEdits(in: victims) else { return false }
            return await saveSelectedTabWork()
        case .dontSave:
            return true
        case .cancel:
            return false
        }
    }

    /// What the batch is about to destroy, not what the connection happens to hold.
    ///
    /// A close that names its victims used to be judged by `hasUnsavedWorkInConnection`, which walks
    /// every tab of the connection: closing one database's tabs while another database had a dirty
    /// one asked the user to save work the command was not going to touch, and Save then ran
    /// `saveSelectedTabWork()` on whatever tab was selected, which could be that other database's.
    /// An empty victim list still means the whole connection, which is what the window-close and
    /// disconnect paths ask about.
    ///
    /// The connection-wide flags ride with the selected tab. The row inspector's edits and the
    /// pending truncates and drops belong to the pane on screen, so they count exactly when that
    /// pane's tab is one of the victims.
    func hasUnsavedWork(among victims: [QueryTab]) -> Bool {
        guard let coordinator, !victims.isEmpty else { return hasUnsavedWorkInConnection }
        if victims.contains(where: { coordinator.hasUnsavedWork(in: $0) }) { return true }
        guard victims.contains(where: { coordinator.isSelectedTab($0) }) else { return false }
        return coordinator.hasSidebarEdits || coordinator.hasPendingDestructiveTableOps
    }

    private func tabsToClose(kind: BatchCloseKind) -> [QueryTab] {
        guard let coordinator else { return [] }
        let tabs = coordinator.tabManager.tabs
        let target = PluginManager.shared.containerSwitchTarget(for: currentDatabaseType)

        switch kind {
        case .all:
            return tabs
        case .others(let anchor):
            return tabs.filter { $0.id != anchor }
        case .otherDatabases:
            let current = browsedContainerName
            /// A tab that cannot name its container is not in another one, it is in none, and
            /// `containerName` returning nil compared against a non-optional name made every such
            /// tab foreign. Only `.table` tabs carry a schema, so on a schema-switching engine that
            /// swept up every query tab the user had typed into. `container(of:)` is the same
            /// composition the workspace rail already uses to avoid exactly this.
            return tabs.filter { tab in
                guard let name = WorkspaceAnchoring.container(of: tab, target: target) else { return false }
                return name != current
            }
        }
    }
}
