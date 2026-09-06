//
//  SidebarMenuItem.swift
//  TablePro
//

import Foundation

/// One row of a sidebar contextual menu, described rather than built.
///
/// The menus used to be SwiftUI `.contextMenu` blocks on the hosted row, which meant the hosting
/// view answered the right-click and `NSOutlineView` never did: no clicked-row highlight, no
/// `clickedRow`, and no menu at all in the empty area below the last row. Moving ownership to the
/// outline view means the items have to be `NSMenuItem`s, and describing them as values first keeps
/// every decision about which items exist, in what order, testable without a window.
///
/// There is deliberately no `separator` case. A menu is a list of `SidebarMenuSection`s and the
/// builder rules between them, so a stray separator is unrepresentable rather than swept up.
///
/// Generic over the command so both sidebar lists share one model and one builder while keeping
/// their own, closed, vocabularies.
internal enum SidebarMenuItem<Command: Equatable>: Equatable {
    case command(SidebarMenuEntry<Command>)
    case submenu(title: String, sections: [SidebarMenuSection<Command>])
}

/// No destructive flag. AppKit gives `NSMenuItem` no destructive role, on any SDK up to macOS 26,
/// and Apple's own menus do not colour one: Finder's Move to Trash and Mail's Delete are ordinary
/// items. Hand-rolling red through `attributedTitle` would invent a convention the platform does not
/// have. A destructive item is set apart by sitting last in its group, behind a separator, which is
/// what every spec here already does.
internal struct SidebarMenuEntry<Command: Equatable>: Equatable {
    internal let title: String
    internal let command: Command
    internal var isOn: Bool?

    internal init(
        title: String,
        command: Command,
        isOn: Bool? = nil
    ) {
        self.title = title
        self.command = command
        self.isOn = isOn
    }
}

internal extension SidebarMenuItem {
    static func command(_ title: String, _ command: Command) -> SidebarMenuItem<Command> {
        .command(SidebarMenuEntry(title: title, command: command))
    }

    static func submenu(title: String, items: [SidebarMenuItem<Command>]) -> SidebarMenuItem<Command> {
        .submenu(title: title, sections: [SidebarMenuSection(items)])
    }
}

internal typealias DatabaseTreeMenuItem = SidebarMenuItem<SidebarMenuCommand>
internal typealias FavoritesMenuItem = SidebarMenuItem<FavoritesMenuCommand>
