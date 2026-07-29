//
//  TabBatchClosePlanner.swift
//  TablePro
//

import Foundation

struct TabBatchCloseTarget: Equatable {
    let windowId: ObjectIdentifier
    let databaseNames: Set<String>
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

    /// A window closes only when every tab in it names a database other than the active one.
    /// An unnamed database means "whatever the connection is pointed at", which is never foreign,
    /// and an unknown active database cannot classify anything, so both yield an empty plan.
    static func planCloseForOtherDatabases(
        targets: [TabBatchCloseTarget],
        currentWindowId: ObjectIdentifier,
        currentDatabaseName: String
    ) -> Plan {
        guard !currentDatabaseName.isEmpty else { return .empty }
        let foreign = targets.filter { target in
            target.windowId != currentWindowId
                && !target.databaseNames.isEmpty
                && !target.databaseNames.contains(currentDatabaseName)
        }
        return Plan(windowsToCloseOutright: foreign.map(\.windowId), survivorWindowId: nil)
    }

    private static func windowIds(
        in targets: [TabBatchCloseTarget],
        excluding currentWindowId: ObjectIdentifier
    ) -> [ObjectIdentifier] {
        targets.map(\.windowId).filter { $0 != currentWindowId }
    }
}
