//
//  MainContentCommandActions+BulkClose.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCommandActions {
    enum BatchCloseKind: Equatable {
        case all
        // Explicit: a contextual menu acts on the tab under the pointer, which is not always the selected one.
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
        return canCloseOtherTabs(anchoredOn: anchor)
    }

    func canCloseOtherTabs(anchoredOn anchor: UUID) -> Bool {
        !tabsToClose(kind: .others(anchor: anchor)).isEmpty
    }

    var canCloseTabsForOtherDatabases: Bool {
        guard supportsContainerSwitching else { return false }
        return !tabsToClose(kind: .otherDatabases).isEmpty
    }

    // Named the engine's way: a schema-switching engine's tabs compared against a database name classified nothing.
    var shownContainerName: String {
        coordinator?.tabManager.visibleContainer ?? coordinator?.browseCursorCoordinator.browsedContainer ?? ""
    }

    var closeTabsForOtherDatabasesTitle: String {
        containerSwitchTitle(
            schema: String(localized: "Close Tabs for Other Schemas"),
            database: String(localized: "Close Tabs for Other Databases")
        )
    }

    // A list edit, not a window close: the window hosts every connection, so closing all tabs leaves this one empty.
    private func runBatchClose(kind: BatchCloseKind) async {
        guard let coordinator else { return }
        let victims = tabsToClose(kind: kind)
        guard !victims.isEmpty else { return }
        guard case .close(let closable) = await resolveUnsavedWork(in: victims) else { return }
        // A save can suspend long enough for a victim to be pinned.
        let unpinned = Set(coordinator.tabManager.tabs.filter { !$0.isPinned }.map(\.id))
        coordinator.closeTabsByUser(ids: victims.map(\.id).filter { closable.contains($0) && unpinned.contains($0) })
    }

    internal enum UnsavedWorkOutcome: Equatable {
        case cancel
        // Save leaves out any victim it could not actually save.
        case close(Set<UUID>)
    }

    // One prompt for the batch: NSWindow.beginSheet queues a second sheet behind the first instead of presenting it.
    internal func resolveUnsavedWork(in victims: [QueryTab]) async -> UnsavedWorkOutcome {
        let everything = Set(victims.map(\.id))
        coordinator?.commitActiveGridEdit()
        guard hasUnsavedWork(among: victims) else { return .close(everything) }

        switch await confirmSaveChanges(unsavedWorkMessage(for: victims), closeAnchorWindow) {
        case .save:
            return .close(await saveVictims(victims))
        case .dontSave:
            return .close(everything)
        case .cancel:
            return .cancel
        }
    }

    // Save cannot reach off-screen grid edits, staged principals or table drafts; those tabs stay open and the alert says so.
    private func unsavedWorkMessage(for victims: [QueryTab]) -> String {
        Self.unsavedWorkMessage(keepsTabsOpen: holdsWorkOnlyItsTabCanSave(among: victims))
    }

    func holdsWorkOnlyItsTabCanSave(among victims: [QueryTab]) -> Bool {
        guard let coordinator else { return false }
        return victims.contains { coordinator.savability(of: $0) == .mountedOnly }
    }

    static func unsavedWorkMessage(keepsTabsOpen: Bool) -> String {
        guard keepsTabsOpen else {
            return String(localized: "Your changes will be lost if you don't save them.")
        }
        return String(
            localized: """
            Your changes will be lost if you don't save them. \
            Tabs whose changes can only be saved from the tab itself stay open.
            """
        )
    }

    // Closing the connection takes every tab, so Save has to reach each one; false keeps the connection open.
    func saveEveryTabsWork() async -> Bool {
        guard let coordinator else { return true }
        coordinator.commitActiveGridEdit()
        let tabs = coordinator.tabManager.tabs
        let saved = await saveVictims(tabs)
        return tabs.allSatisfy { saved.contains($0.id) } && !coordinator.hasAnyUnsavedWork()
    }

    // A victim it cannot save keeps its tab, a file conflict too: the conflict sheet is one window-level slot with no queue.
    private func saveVictims(_ victims: [QueryTab]) async -> Set<UUID> {
        guard let coordinator else { return Set(victims.map(\.id)) }
        guard await applyStagedStructureEdits(in: victims) else { return [] }
        guard await saveWorkOnScreen(among: victims) else { return [] }

        var closable: Set<UUID> = []
        var files: [(tab: QueryTab, url: URL)] = []
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
                files.append((tab: victim, url: url))
            }
        }
        closable.formUnion(await saveFiles(files))
        if let selected = coordinator.tabManager.selectedTab, victims.contains(where: { $0.id == selected.id }) {
            closable.insert(selected.id)
        }
        return closable
    }

    // Always runs: a staged TRUNCATE and inspector edits belong to the connection, and only saveSelectedTabWork applies them.
    private func saveWorkOnScreen(among victims: [QueryTab]) async -> Bool {
        guard let coordinator else { return true }
        let selected = coordinator.tabManager.selectedTab
        let onScreenIsAVictim = victims.isEmpty || victims.contains { $0.id == selected?.id }
        guard onScreenIsAVictim else { return true }
        return await saveSelectedTabWork()
    }

    // Victims only (empty means the whole connection); connection-wide flags count only when the on-screen tab is a victim.
    func hasUnsavedWork(among victims: [QueryTab]) -> Bool {
        guard let coordinator, !victims.isEmpty else { return hasUnsavedWorkInConnection }
        if victims.contains(where: { coordinator.hasUnsavedWork(in: $0) }) { return true }
        guard victims.contains(where: { coordinator.isSelectedTab($0) }) else { return false }
        return coordinator.hasSidebarEdits || coordinator.hasPendingDestructiveTableOps
    }

    // Close All and Close Others act on the visible entry; Other Databases reaches every other entry, empty tabs too.
    private func tabsToClose(kind: BatchCloseKind) -> [QueryTab] {
        guard let coordinator else { return [] }
        let manager = coordinator.tabManager

        switch kind {
        case .all:
            return manager.visibleTabs.filter { !$0.isPinned }
        case .others(let anchor):
            return manager.visibleTabs.filter { $0.id != anchor && !$0.isPinned }
        case .otherDatabases:
            let current = shownContainerName
            // A tab with no container name is in every container, not another one; nil compared to a name made it foreign.
            return manager.tabs.filter { tab in
                guard !tab.isPinned, let name = manager.containerName(of: tab) else { return false }
                return name != current
            }
        }
    }
}
