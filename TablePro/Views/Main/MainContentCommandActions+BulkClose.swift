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

    /// Closes a workspace from the rail: every window of this connection whose tabs all sit in
    /// that container. Routed through the same batch machinery as the menu commands, so it
    /// inherits the per-window save prompt and the cancel-stops-the-rest behaviour.
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
        openTabCount > 0 || !batchClosePlan(kind: .all).windowsToCloseOutright.isEmpty
    }

    var canCloseOtherTabs: Bool {
        !batchClosePlan(kind: .others).windowsToCloseOutright.isEmpty
    }

    var canCloseTabsForOtherDatabases: Bool {
        guard supportsContainerSwitching else { return false }
        return !batchClosePlan(kind: .otherDatabases).windowsToCloseOutright.isEmpty
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
        let target = PluginManager.shared.containerSwitchTarget(for: currentDatabaseType)
        let targets = lookup.map { windowId, coordinator in
            TabBatchCloseTarget(
                windowId: windowId,
                containerNames: coordinator.openTabContainerNames(target: target)
            )
        }

        switch kind {
        case .all:
            return TabBatchClosePlanner.planCloseAll(targets: targets, currentWindowId: currentWindowId)
        case .others:
            return TabBatchClosePlanner.planCloseOthers(targets: targets, currentWindowId: currentWindowId)
        case .otherDatabases:
            return TabBatchClosePlanner.planCloseForOtherContainers(
                targets: targets,
                currentWindowId: currentWindowId,
                currentContainerName: browsedContainerName
            )
        case .container(let container):
            return TabBatchClosePlanner.planCloseContainer(targets: targets, containerName: container)
        }
    }

    /// Tab-group scope for the positional commands, because that is the strip the user is looking
    /// at. Connection scope for the database command, because a database means nothing across
    /// connection: a native tab group belongs to one connection, so the positional commands
    /// intersect that group with the connection, while the database command spans the whole
    /// connection regardless of which window a tab sits in.
    private func closeCandidateLookup(kind: BatchCloseKind) -> [ObjectIdentifier: MainContentCoordinator] {
        let coordinators: [MainContentCoordinator]
        switch kind {
        case .all, .others:
            guard let anchor = closeAnchorWindow else { return [:] }
            coordinators = (anchor.tabGroup?.windows ?? [anchor])
                .filter(\.isVisible)
                .compactMap { MainContentCoordinator.coordinator(forWindow: $0) }
                .filter { $0.connectionId == connectionId }
        case .otherDatabases, .container:
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
    /// Named by the same rule the workspace rail uses, so a close command and the row it
    /// removes can never disagree about which container a tab belongs to. Every tab counts
    /// here, including an untouched one the rail would not give a row of its own.
    func openTabContainerNames(target: ContainerSwitchTarget?) -> Set<String> {
        Set(tabManager.tabs.compactMap { WorkspaceAnchoring.containerName(of: $0, target: target) })
    }
}
