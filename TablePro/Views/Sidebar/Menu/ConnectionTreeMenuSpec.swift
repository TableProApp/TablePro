//
//  ConnectionTreeMenuSpec.swift
//  TablePro
//

import Foundation

internal struct ConnectionTreeMenuContext {
    /// Nil when the click landed below the last row, which is the background menu.
    internal let clicked: ConnectionTreeNode.Kind?
    internal let status: ConnectionTreeStatus
    internal let connectionName: String
    internal let groups: [ConnectionGroup]
    /// The group the clicked connection is filed under, so the menu can offer to take it out.
    internal let currentGroupId: UUID?

    internal init(
        clicked: ConnectionTreeNode.Kind?,
        status: ConnectionTreeStatus = .notConnected,
        connectionName: String = "",
        groups: [ConnectionGroup] = [],
        currentGroupId: UUID? = nil
    ) {
        self.clicked = clicked
        self.status = status
        self.connectionName = connectionName
        self.groups = groups
        self.currentGroupId = currentGroupId
    }
}

internal enum ConnectionTreeMenuSpec {
    internal static func sections(for context: ConnectionTreeMenuContext) -> [ConnectionTreeMenuSection] {
        guard let clicked = context.clicked else { return backgroundSections() }
        switch clicked {
        case .connection(let id):
            return connectionSections(id, context: context)
        case .group(let group):
            return groupSections(group)
        }
    }

    /// Connect and Disconnect are never both offered: one of them would do nothing, and a menu item
    /// that does nothing is worse than an absent one. A connection still connecting offers neither,
    /// for the same reason the double-click does nothing there.
    private static func connectionSections(
        _ id: UUID,
        context: ConnectionTreeMenuContext
    ) -> [ConnectionTreeMenuSection] {
        var open: [ConnectionTreeMenuItem] = []
        switch context.status {
        case .notConnected, .failed:
            open.append(.command(String(localized: "Connect"), .connect(id)))
        case .connected:
            open.append(.command(String(localized: "Disconnect"), .disconnect(id)))
        case .connecting:
            break
        }

        let edit: [ConnectionTreeMenuItem] = [
            .command(String(localized: "Edit"), .edit(id)),
            .command(String(localized: "Duplicate"), .duplicate(id)),
            .command(String(localized: "Copy Connection String"), .copyConnectionString(id)),
        ]

        return [
            ConnectionTreeMenuSection( open),
            ConnectionTreeMenuSection( edit),
            ConnectionTreeMenuSection( groupItems(id, context: context)),
            /// Delete sits last, behind a separator. AppKit gives `NSMenuItem` no destructive role
            /// on any SDK up to macOS 26, and Apple's own menus do not colour one, so position is
            /// the whole affordance.
            ConnectionTreeMenuSection( [.command(String(localized: "Delete"), .delete(id))]),
        ]
    }

    private static func groupItems(
        _ id: UUID,
        context: ConnectionTreeMenuContext
    ) -> [ConnectionTreeMenuItem] {
        var items: [ConnectionTreeMenuItem] = []
        let targets = context.groups.filter { $0.id != context.currentGroupId }
        if !targets.isEmpty {
            items.append(.submenu(
                title: String(localized: "Move to Group"),
                sections: [ConnectionTreeMenuSection( targets.map {
                    .command($0.name, .moveToGroup(connectionId: id, groupId: $0.id))
                })]
            ))
        }
        if context.currentGroupId != nil {
            items.append(.command(
                String(localized: "Remove from Group"),
                .moveToGroup(connectionId: id, groupId: nil)
            ))
        }
        return items
    }

    private static func groupSections(_ group: ConnectionGroup) -> [ConnectionTreeMenuSection] {
        [
            ConnectionTreeMenuSection( [
                .command(String(localized: "New Connection…"), .newConnection),
            ]),
            ConnectionTreeMenuSection( [
                .command(String(localized: "Delete"), .deleteGroup(group)),
            ]),
        ]
    }

    private static func backgroundSections() -> [ConnectionTreeMenuSection] {
        [
            ConnectionTreeMenuSection( [
                .command(String(localized: "New Connection…"), .newConnection),
            ]),
        ]
    }
}
