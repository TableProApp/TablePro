//
//  MainContentCommandActions+BulkClose.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCommandActions {
    enum BatchCloseKind {
        case all
        case others
        case otherDatabases
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
        openTabCount > 0 || !batchClosePlan(kind: .all).windowsToCloseOutright.isEmpty
    }

    var canCloseOtherTabs: Bool {
        !batchClosePlan(kind: .others).windowsToCloseOutright.isEmpty
    }

    var canCloseTabsForOtherDatabases: Bool {
        guard supportsContainerSwitching else { return false }
        return !batchClosePlan(kind: .otherDatabases).windowsToCloseOutright.isEmpty
    }

    var closeTabsForOtherDatabasesTitle: String {
        switch PluginManager.shared.containerSwitchTarget(for: currentDatabaseType) {
        case .schema:
            return String(localized: "Close Tabs for Other Schemas")
        case .database, .none:
            return String(localized: "Close Tabs for Other Databases")
        }
    }

    /// Closes every window the plan names, one at a time so each keeps the ordinary single-window
    /// save prompt, then empties the survivor. Siblings go first: a cancel part-way through then
    /// leaves the window the user is actually looking at untouched.
    private func runBatchClose(kind: BatchCloseKind) async {
        let lookup = closeCandidateLookup(kind: kind)
        let plan = batchClosePlan(kind: kind, lookup: lookup)
        guard !plan.isEmpty else { return }

        for windowId in plan.windowsToCloseOutright {
            guard let actions = lookup[windowId]?.commandActions else { continue }
            guard await actions.closeWindowAwaiting(asBatchSurvivor: false) == .closed else { return }
        }

        guard plan.survivorWindowId != nil, openTabCount > 0 else { return }
        await closeWindowAwaiting(asBatchSurvivor: true)
    }

    private func batchClosePlan(kind: BatchCloseKind) -> TabBatchClosePlanner.Plan {
        batchClosePlan(kind: kind, lookup: closeCandidateLookup(kind: kind))
    }

    private func batchClosePlan(
        kind: BatchCloseKind,
        lookup: [ObjectIdentifier: MainContentCoordinator]
    ) -> TabBatchClosePlanner.Plan {
        guard let anchor = closeAnchorWindow else { return .empty }
        let currentWindowId = ObjectIdentifier(anchor)
        let targets = lookup.map { windowId, coordinator in
            TabBatchCloseTarget(windowId: windowId, databaseNames: coordinator.openTabDatabaseNames)
        }

        switch kind {
        case .all:
            return TabBatchClosePlanner.planCloseAll(targets: targets, currentWindowId: currentWindowId)
        case .others:
            return TabBatchClosePlanner.planCloseOthers(targets: targets, currentWindowId: currentWindowId)
        case .otherDatabases:
            return TabBatchClosePlanner.planCloseForOtherDatabases(
                targets: targets,
                currentWindowId: currentWindowId,
                currentDatabaseName: activeDatabaseName
            )
        }
    }

    /// Tab-group scope for the positional commands, because that is the strip the user is looking
    /// at. Connection scope for the database command, because a database means nothing across
    /// connections and one connection's tabs can be spread over sibling windows.
    private func closeCandidateLookup(kind: BatchCloseKind) -> [ObjectIdentifier: MainContentCoordinator] {
        let coordinators: [MainContentCoordinator]
        switch kind {
        case .all, .others:
            guard let anchor = closeAnchorWindow else { return [:] }
            coordinators = (anchor.tabGroup?.windows ?? [anchor])
                .filter(\.isVisible)
                .compactMap { MainContentCoordinator.coordinator(forWindow: $0) }
        case .otherDatabases:
            coordinators = MainContentCoordinator.allActiveCoordinators()
                .filter { $0.connectionId == connectionId }
        }

        return coordinators.reduce(into: [:]) { result, coordinator in
            guard let window = coordinator.contentWindow else { return }
            result[ObjectIdentifier(window)] = coordinator
        }
    }
}

private extension MainContentCoordinator {
    var openTabDatabaseNames: Set<String> {
        Set(tabManager.tabs.map(\.tableContext.databaseName).filter { !$0.isEmpty })
    }
}
