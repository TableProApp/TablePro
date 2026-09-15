//
//  ConnectionTreeMenuCommand.swift
//  TablePro
//

import Foundation

/// What a connections tree menu item does.
///
/// Deleting ends in a confirmation the controller owns, so the command names the intent and the
/// view decides how to ask. That split is what keeps the whole menu a pure function of values.
internal enum ConnectionTreeMenuCommand: Equatable {
    case connect(UUID)
    case disconnect(UUID)
    case edit(UUID)
    case duplicate(UUID)
    case delete(UUID)
    case copyConnectionString(UUID)
    case moveToGroup(connectionId: UUID, groupId: UUID?)

    case newConnection
    /// No `newGroup` or `renameGroup` yet, and deliberately: naming a folder belongs in an inline
    /// rename on the row, the way `FavoritesRenameSession` does it, and an item that opens a dialog
    /// that does not exist is worse than an absent one.
    case deleteGroup(ConnectionGroup)
}

extension ConnectionTreeMenuCommand: SidebarMenuShortcutProviding {
    /// Only New Connection has a menu-bar twin that carries a `ShortcutAction`. Everything else
    /// answers nil and shows no shortcut, which is the honest result: a key equivalent spelled here
    /// would be a binding the menu bar does not have.
    internal var shortcutAction: ShortcutAction? {
        switch self {
        case .newConnection:
            return .newConnection
        default:
            return nil
        }
    }
}
