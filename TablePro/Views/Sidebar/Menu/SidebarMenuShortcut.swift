//
//  SidebarMenuShortcut.swift
//  TablePro
//

import Foundation

/// The shortcut a sidebar contextual command shares with its menu-bar twin, if it has one.
///
/// The binding itself is never spelled here. A command names a `ShortcutAction` and the builder
/// resolves it through the same `MenuItemFactory.apply(shortcut:keyboard:to:)` the menu bar uses,
/// so both menus read one `KeyboardSettings` and a rebind in Settings moves them together. Spelling
/// a key equivalent in the sidebar instead would be a second copy of a binding nothing forces to
/// agree with the first.
///
/// A command with no menu-bar twin, or a twin the menu bar never gave a `ShortcutAction`, answers
/// nil and shows no shortcut. That is the honest result: an invented binding here would be a
/// shortcut the menu bar does not have.
internal protocol SidebarMenuShortcutProviding {
    var shortcutAction: ShortcutAction? { get }
}

extension SidebarMenuCommand: SidebarMenuShortcutProviding {
    /// Only the commands whose menu-bar twin actually carries a `ShortcutAction` today: Database >
    /// Refresh, Database > Truncate Table, File > Import Data and File > Export. Drop is left out
    /// deliberately, because the menu bar's Delete is the data grid's row delete and pointing the
    /// sidebar's object drop at it would show a shortcut that deletes something else.
    internal var shortcutAction: ShortcutAction? {
        switch self {
        case .refreshContainers, .refreshObjectKind, .refreshContainerObjectKind, .refreshHierarchicalSchema:
            return .refresh
        case .truncateTables:
            return .truncateTable
        case .importTables:
            return .importData
        case .exportTables, .exportContainers:
            return .export
        default:
            return nil
        }
    }
}

extension FavoritesMenuCommand: SidebarMenuShortcutProviding {
    /// The Favorites list shares no command with the menu bar that carries a binding. Declared all
    /// the same so one builder serves both menus.
    internal var shortcutAction: ShortcutAction? {
        nil
    }
}
