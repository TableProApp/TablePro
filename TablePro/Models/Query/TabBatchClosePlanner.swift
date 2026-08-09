//
//  TabBatchClosePlanner.swift
//  TablePro
//

import Foundation

struct TabBatchCloseTarget: Equatable {
    let windowId: ObjectIdentifier
    let containerNames: Set<String>
}

enum TabBatchClosePlanner {
    struct Plan: Equatable {
        let windowsToCloseOutright: [ObjectIdentifier]
        let survivorWindowId: ObjectIdentifier?

        static let empty = Plan(windowsToCloseOutright: [], survivorWindowId: nil)

        var isEmpty: Bool {
            windowsToCloseOutright.isEmpty && survivorWindowId == nil
        }
    }

    static func planCloseAll(
        targets: [TabBatchCloseTarget],
        currentWindowId: ObjectIdentifier
    ) -> Plan {
        Plan(
            windowsToCloseOutright: windowIds(in: targets, excluding: currentWindowId),
            survivorWindowId: currentWindowId
        )
    }

    static func planCloseOthers(
        targets: [TabBatchCloseTarget],
        currentWindowId: ObjectIdentifier
    ) -> Plan {
        Plan(
            windowsToCloseOutright: windowIds(in: targets, excluding: currentWindowId),
            survivorWindowId: nil
        )
    }

    /// A window closes only when every tab in it names a container other than the active one.
    /// An unnamed container means "whatever the connection is pointed at", which is never foreign,
    /// and an unknown active container cannot classify anything, so both yield an empty plan.
    static func planCloseForOtherContainers(
        targets: [TabBatchCloseTarget],
        currentWindowId: ObjectIdentifier,
        currentContainerName: String
    ) -> Plan {
        guard !currentContainerName.isEmpty else { return .empty }
        let foreign = targets.filter { target in
            target.windowId != currentWindowId
                && !target.containerNames.isEmpty
                && !target.containerNames.contains(currentContainerName)
        }
        return Plan(windowsToCloseOutright: foreign.map(\.windowId), survivorWindowId: nil)
    }

    /// Closing one workspace takes only the windows whose every tab belongs to it. A window
    /// holding a tab on another container is shared, so it stays: the rail's promise is that a
    /// row disappears when its own work is gone, never that it closes someone else's.
    ///
    /// An empty name is the single workspace of an engine that switches neither database nor
    /// schema, so its windows are the ones whose tabs name no container at all. Treating that as
    /// "nothing to close" made the command inert for SQLite, Redis, DuckDB and every other
    /// single-container engine.
    static func planCloseContainer(
        targets: [TabBatchCloseTarget],
        containerName: String
    ) -> Plan {
        let owned = targets.filter { target in
            containerName.isEmpty
                ? target.containerNames.isEmpty
                : target.containerNames == [containerName]
        }
        return Plan(windowsToCloseOutright: owned.map(\.windowId), survivorWindowId: nil)
    }

    private static func windowIds(
        in targets: [TabBatchCloseTarget],
        excluding currentWindowId: ObjectIdentifier
    ) -> [ObjectIdentifier] {
        targets.map(\.windowId).filter { $0 != currentWindowId }
    }
}
