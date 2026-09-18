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
        guard case .close(let closable) = await resolveUnsavedWork(in: victims) else { return }
        coordinator.closeTabsByUser(ids: victims.map(\.id).filter { closable.contains($0) })
    }

    /// What a close should do about the work it is going to destroy.
    internal enum UnsavedWorkOutcome: Equatable {
        case cancel
        /// The ids that may now be closed. Save leaves out any victim it could not actually save.
        case close(Set<UUID>)
    }

    /// A partial close leaves the window open, so it cannot lean on the window's own prompt.
    /// The question is asked once for the batch rather than once per tab, which is also what keeps
    /// the sheets from queueing: `NSWindow.beginSheet` queues a second sheet behind the first rather
    /// than presenting it, so N prompts would be answered one at a time with no way to see why.
    ///
    /// Save goes on to close. It used to save and then return false, which left the batch standing
    /// after a successful save and made Save mean "cancel" on this path while it meant "close" on
    /// the window path. And it used to run `saveSelectedTabWork()` whatever the victims were, so on
    /// Close Other Tabs and Close Tabs for Other Databases, where the selected tab is never a
    /// victim, Save wrote a bystander's changes and the close destroyed the victims' own.
    internal func resolveUnsavedWork(in victims: [QueryTab]) async -> UnsavedWorkOutcome {
        let everything = Set(victims.map(\.id))
        guard hasUnsavedWork(among: victims) else { return .close(everything) }

        switch await AlertHelper.confirmSaveChanges(message: unsavedWorkMessage(for: victims), window: closeAnchorWindow) {
        case .save:
            return .close(await saveVictims(victims))
        case .dontSave:
            return .close(everything)
        case .cancel:
            return .cancel
        }
    }

    /// For the paths that close everything whatever the answer: a window closing, a connection
    /// closing, a disconnect. They have nowhere to leave a tab open, so a save that could not take
    /// every victim stops them, the way a failed apply of staged ALTERs always did. Answering true
    /// on a partial save would close exactly the tabs the save refused.
    func confirmDiscardingUnsavedWork(victims: [QueryTab] = []) async -> Bool {
        switch await resolveUnsavedWork(in: victims) {
        case .cancel:
            return false
        case .close(let closable):
            return closable.isSuperset(of: Set(victims.map(\.id)))
        }
    }

    /// Save cannot reach a tab that is not on screen for grid edits, staged principals or a table
    /// draft, so the alert says what will happen to those rather than promising a save it cannot
    /// make: they stay open, and everything else closes.
    private func unsavedWorkMessage(for victims: [QueryTab]) -> String {
        guard let coordinator,
              victims.contains(where: { coordinator.savability(of: $0) == .mountedOnly })
        else {
            return String(localized: "Your changes will be lost if you don't save them.")
        }
        return String(
            localized: """
            Your changes will be lost if you don't save them. \
            Tabs whose changes can only be saved from the tab itself stay open.
            """
        )
    }

    /// Saves each victim through the path that can reach it, and answers with the ones that are now
    /// safe to close.
    ///
    /// A victim it cannot save keeps its tab: closing it would be the data loss the prompt exists to
    /// prevent. That includes a file whose copy on disk changed underneath it, because the conflict
    /// sheet is one window-level slot with no queue, and a second victim's conflict would overwrite
    /// the first while both tabs closed behind it.
    private func saveVictims(_ victims: [QueryTab]) async -> Set<UUID> {
        guard let coordinator else { return Set(victims.map(\.id)) }
        guard await applyStagedStructureEdits(in: victims) else { return [] }
        guard await saveWorkOnScreen(among: victims) else { return [] }

        var closable: Set<UUID> = []
        for victim in victims where !coordinator.isSelectedTab(victim) {
            switch coordinator.savability(of: victim) {
            case .nothingAtRisk:
                closable.insert(victim.id)
            case .mountedOnly:
                continue
            case .saveable:
                guard victim.content.isFileDirty, let url = victim.content.sourceFileURL else {
                    closable.insert(victim.id)
                    continue
                }
                if await saveFile(of: victim, to: url) { closable.insert(victim.id) }
            }
        }
        if let selected = coordinator.tabManager.selectedTab, victims.contains(where: { $0.id == selected.id }) {
            closable.insert(selected.id)
        }
        return closable
    }

    /// The pane on screen, saved through the one path that reaches all of it.
    ///
    /// Not every kind of unsaved work belongs to a tab: a staged TRUNCATE and an edit in the row
    /// inspector belong to the connection, `savability` deliberately leaves them out, and
    /// `saveSelectedTabWork` is the only thing that applies them. Skipping it because the selected
    /// tab's own work looked clean is how Save came to close a connection with a staged TRUNCATE
    /// still staged. An empty victim list is the whole connection, which is what the window-close
    /// and disconnect paths ask about, and it goes through here too.
    private func saveWorkOnScreen(among victims: [QueryTab]) async -> Bool {
        guard let coordinator else { return true }
        let selected = coordinator.tabManager.selectedTab
        let onScreenIsAVictim = victims.isEmpty || victims.contains { $0.id == selected?.id }
        guard onScreenIsAVictim else { return true }
        return await saveSelectedTabWork()
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
