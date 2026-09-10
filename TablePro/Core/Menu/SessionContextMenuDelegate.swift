//
//  SessionContextMenuDelegate.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// The per-driver session contexts a connection can switch, which today is Snowflake's warehouse
/// and role. Which contexts exist, and which values each offers, are answers only the live driver
/// has, so the submenu is filled when it opens.
///
/// It is a menu rather than a toolbar control because the set is dynamic: a driver may publish
/// none, one or several, and `NSToolbar` needs a fixed identifier per item. As hosted SwiftUI
/// inside the connection group these had no overflow entry, no menu command and no shortcut, so a
/// window narrow enough to clip that group left no way to change warehouse or role at all.
@MainActor
final class SessionContextMenuDelegate: NSObject, NSMenuDelegate {
    private static let action = #selector(MainSplitViewController.switchSessionContext(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        let contexts = controller?.commandActions?.coordinator?.sessionContexts ?? []
        guard !contexts.isEmpty else {
            addPlaceholder(to: menu)
            return
        }
        for context in contexts {
            menu.addItem(section(for: context))
        }
    }

    /// One submenu per context, titled with the context's own label, so "Warehouse" and "Role"
    /// read as the two separate choices they are rather than one flat list of unrelated values.
    private func section(for context: PluginSessionContext) -> NSMenuItem {
        let submenu = NSMenu()
        for value in context.availableValues {
            let item = NSMenuItem(title: value, action: Self.action, keyEquivalent: "")
            item.target = nil
            item.representedObject = SessionContextSelection(contextId: context.id, value: value)
            item.state = value == context.currentValue ? .on : .off
            submenu.addItem(item)
        }
        if context.availableValues.isEmpty {
            addPlaceholder(to: submenu)
        }
        let container = NSMenuItem(title: context.label, action: nil, keyEquivalent: "")
        container.image = NSImage(systemSymbolName: context.iconName, accessibilityDescription: nil)
        container.submenu = submenu
        return container
    }

    private func addPlaceholder(to menu: NSMenu) {
        let empty = NSMenuItem(title: String(localized: "None Available"), action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
    }

    /// Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke,
    /// which would walk the responder chain for items that carry no key equivalent.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}

/// Which context and which value, carried on the menu item. Two strings that mean nothing apart
/// travel together rather than being reassembled from a title the user's data could collide with.
internal struct SessionContextSelection: Equatable {
    internal let contextId: String
    internal let value: String
}
