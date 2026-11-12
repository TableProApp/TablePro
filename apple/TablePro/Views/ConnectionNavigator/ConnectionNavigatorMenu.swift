//
//  ConnectionNavigatorMenu.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// What the navigator's context menu can do. Reordering and deleting stay in the Welcome window,
/// which owns the library's organization; the navigator only opens and edits.
internal enum ConnectionNavigatorCommand: Equatable {
    case switchTo(UUID)
    case open(UUID)
    case openInNewWindow(UUID)
    case disconnect(UUID)
    case edit(UUID)
    case duplicate(UUID)
    case newConnection
    case newGroup(parentId: UUID?)
}

extension ConnectionNavigatorCommand: SidebarMenuShortcutProviding {
    internal var shortcutAction: ShortcutAction? {
        guard case .newConnection = self else { return nil }
        return .newConnection
    }
}

internal typealias ConnectionNavigatorMenuItem = SidebarMenuItem<ConnectionNavigatorCommand>
internal typealias ConnectionNavigatorMenuSection = SidebarMenuSection<ConnectionNavigatorCommand>

internal struct ConnectionNavigatorMenuConnection: Equatable {
    internal let id: UUID
    internal let placement: ConnectionNavigatorPlacement
    internal let status: ConnectionDisplayStatus
    internal let holdsSession: Bool
    internal let canMoveToNewWindow: Bool
}

internal enum ConnectionNavigatorMenuTarget: Equatable {
    case connection(ConnectionNavigatorMenuConnection)
    case group(UUID)
    case empty
}

/// A context menu shows only what applies to its row, as the strip's and Welcome's do, so a command
/// that would do nothing is left out rather than dimmed (`ConnectionMenuPolicy`).
internal enum ConnectionNavigatorMenu {
    internal static func sections(for target: ConnectionNavigatorMenuTarget) -> [ConnectionNavigatorMenuSection] {
        switch target {
        case .group(let groupId):
            return [creationSection(parentId: groupId)]
        case .empty:
            return [creationSection(parentId: nil)]
        case .connection(let connection):
            return [
                openSection(for: connection),
                ConnectionNavigatorMenuSection([
                    .command(Titles.editConnection, .edit(connection.id)),
                    .command(Titles.duplicate, .duplicate(connection.id)),
                ]),
                creationSection(parentId: nil),
            ].nonEmptySections()
        }
    }

    private static func openSection(for connection: ConnectionNavigatorMenuConnection) -> ConnectionNavigatorMenuSection {
        var items: [ConnectionNavigatorMenuItem] = []
        if let primary = primaryItem(for: connection) {
            items.append(primary)
        }
        if offersNewWindow(connection) {
            items.append(.command(Titles.openInNewWindow, .openInNewWindow(connection.id)))
        }
        if ConnectionMenuPolicy.showsDisconnect(status: connection.status, holdsSession: connection.holdsSession) {
            items.append(.command(Titles.disconnect, .disconnect(connection.id)))
        }
        return ConnectionNavigatorMenuSection(items)
    }

    /// The connection on screen needs no way to get to it. One open here is a switch, one open in
    /// another window raises that window, and one nobody shows dials unless a session already runs.
    private static func primaryItem(for connection: ConnectionNavigatorMenuConnection) -> ConnectionNavigatorMenuItem? {
        switch connection.placement {
        case .shownHere:
            return nil
        case .openHere:
            return .command(Titles.switchTo, .switchTo(connection.id))
        case .openElsewhere:
            return .command(Titles.open, .open(connection.id))
        case .notOpen:
            let title = connection.status == .connected ? Titles.open : Titles.connect
            return .command(title, .open(connection.id))
        }
    }

    /// A connection open elsewhere already has a window of its own, and one this window hosts can
    /// only leave while it is not the window's last (`WindowManager.canMoveToNewWindow`).
    private static func offersNewWindow(_ connection: ConnectionNavigatorMenuConnection) -> Bool {
        switch connection.placement {
        case .notOpen:
            return true
        case .shownHere, .openHere:
            return connection.canMoveToNewWindow
        case .openElsewhere:
            return false
        }
    }

    private static func creationSection(parentId: UUID?) -> ConnectionNavigatorMenuSection {
        ConnectionNavigatorMenuSection([
            .command(Titles.newConnection, .newConnection),
            .command(Titles.newGroup, .newGroup(parentId: parentId)),
        ])
    }

    internal enum Titles {
        static var connect: String { String(localized: "Connect") }
        static var open: String { String(localized: "Open") }
        static var switchTo: String { String(localized: "Switch To") }
        static var openInNewWindow: String { String(localized: "Open in New Window") }
        static var disconnect: String { String(localized: "Disconnect") }
        static var editConnection: String { String(localized: "Edit Connection…") }
        static var duplicate: String { String(localized: "Duplicate") }
        static var newConnection: String { String(localized: "New Connection…") }
        static var newGroup: String { String(localized: "New Group…") }
    }
}
