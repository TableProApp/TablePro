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
internal enum SidebarMenuItem: Equatable {
    case separator
    case command(SidebarMenuEntry)
    case submenu(title: String, items: [SidebarMenuItem])
}

internal struct SidebarMenuEntry: Equatable {
    internal let title: String
    internal let command: SidebarMenuCommand
    internal var isOn: Bool?
    internal var symbolName: String?

    internal init(
        title: String,
        command: SidebarMenuCommand,
        isOn: Bool? = nil,
        symbolName: String? = nil
    ) {
        self.title = title
        self.command = command
        self.isOn = isOn
        self.symbolName = symbolName
    }
}

internal extension SidebarMenuItem {
    static func command(_ title: String, _ command: SidebarMenuCommand) -> SidebarMenuItem {
        .command(SidebarMenuEntry(title: title, command: command))
    }

    /// A menu is assembled by appending groups, so a group that turns out to be empty leaves a
    /// separator with nothing on one side of it. SwiftUI's `Divider()` collapsed those on its own;
    /// an imperative builder has to.
    static func collapsingSeparators(_ items: [SidebarMenuItem]) -> [SidebarMenuItem] {
        var result: [SidebarMenuItem] = []
        for item in items {
            guard item == .separator else {
                result.append(item)
                continue
            }
            guard let last = result.last, last != .separator else { continue }
            result.append(item)
        }
        while result.last == .separator { result.removeLast() }
        return result
    }
}
