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
    internal static func fill<Command: Equatable & SidebarMenuShortcutProviding>(
        _ menu: NSMenu,
        with sections: [SidebarMenuSection<Command>],
        target: AnyObject,
        action: Selector,
        keyboard: KeyboardSettings = AppSettingsManager.shared.keyboard
    ) {
        menu.removeAllItems()
        /// `autoenablesItems` defaults to true, and validation runs after `menuNeedsUpdate`, so
        /// every item would be greyed out unless a validator answers for it. The spec decides what
        /// exists instead of what is dimmed, so nothing here needs validating.
        menu.autoenablesItems = false
        for (index, section) in sections.nonEmptySections().enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in section.items {
                menu.addItem(makeItem(item, target: target, action: action, keyboard: keyboard))
            }
        }
    }

    private static func makeItem<Command: Equatable & SidebarMenuShortcutProviding>(
        _ item: SidebarMenuItem<Command>,
        target: AnyObject,
        action: Selector,
        keyboard: KeyboardSettings
    ) -> NSMenuItem {
        switch item {
        case .command(let entry):
            return makeCommandItem(entry, target: target, action: action, keyboard: keyboard)
        case .submenu(let title, let sections):
            let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            fill(submenu, with: sections, target: target, action: action, keyboard: keyboard)
            container.submenu = submenu
            return container
        }
    }

    /// The key equivalent is resolved rather than spelled, so a rebind in Settings moves this item
    /// and its menu-bar twin together. Measured on macOS 27: a key equivalent on a contextual menu
    /// item is display-only, because `NSView.performKeyEquivalent` never consults the view's own
    /// menu, so this claims nothing the menu bar already owns and blanks nothing.
    private static func makeCommandItem<Command: Equatable & SidebarMenuShortcutProviding>(
        _ entry: SidebarMenuEntry<Command>,
        target: AnyObject,
        action: Selector,
        keyboard: KeyboardSettings
    ) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = SidebarMenuCommandBox(entry.command)
        item.isEnabled = true
        if let shortcut = entry.command.shortcutAction {
            MenuItemFactory.apply(shortcut: shortcut, keyboard: keyboard, to: item)
        }
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
