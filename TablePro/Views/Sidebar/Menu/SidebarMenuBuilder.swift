//
//  SidebarMenuBuilder.swift
//  TablePro
//

import AppKit

/// Turns a described menu into an `NSMenu`.
///
/// The only AppKit file in the menu path, so everything that decides what a menu contains stays a
/// pure function of values.
@MainActor
internal enum SidebarMenuBuilder {
    internal static func fill<Command: Equatable>(
        _ menu: NSMenu,
        with items: [SidebarMenuItem<Command>],
        target: AnyObject,
        action: Selector
    ) {
        menu.removeAllItems()
        /// `autoenablesItems` defaults to true, and validation runs after `menuNeedsUpdate`, so
        /// every item would be greyed out unless a validator answers for it. The spec decides what
        /// exists instead of what is dimmed, so nothing here needs validating.
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(makeItem(item, target: target, action: action))
        }
    }

    private static func makeItem<Command: Equatable>(
        _ item: SidebarMenuItem<Command>,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()
        case .command(let entry):
            return makeCommandItem(entry, target: target, action: action)
        case .submenu(let title, let items):
            let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            fill(submenu, with: items, target: target, action: action)
            container.submenu = submenu
            return container
        }
    }

    private static func makeCommandItem<Command: Equatable>(
        _ entry: SidebarMenuEntry<Command>,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = SidebarMenuCommandBox(entry.command)
        item.isEnabled = true
        if let isOn = entry.isOn {
            item.state = isOn ? .on : .off
        }
        return item
    }
}

/// `representedObject` is `Any?`, and an enum with associated values does not survive the round trip
/// through the Objective-C runtime on its own.
internal final class SidebarMenuCommandBox<Command>: NSObject {
    internal let command: Command

    internal init(_ command: Command) {
        self.command = command
    }
}
