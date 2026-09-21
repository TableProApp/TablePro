//
//  ContentModeMenuDelegate.swift
//  TablePro
//

import AppKit

/// Browse and Agent as a pair of menu items, filled when the menu opens.
///
/// Each entry names its mode in `representedObject`, and that is load-bearing twice over:
/// `setContentModeFromMenu(_:)` reads it to know which mode was chosen and does nothing without
/// it, and the window's `validateMenuItem` reads it to put the checkmark on the mode the
/// connection is in. An entry without it validates enabled, acts on nothing and ticks nothing.
///
/// Driven from the enum rather than a hand copy, the way View > Mode is, so a third mode cannot be
/// offered in one menu and missing from the other.
@MainActor
internal final class ContentModeMenuDelegate: NSObject, NSMenuDelegate {
    internal static let action = #selector(MainSplitViewController.setContentModeFromMenu(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for mode in ConnectionWorkspaceContentMode.allCases {
            menu.addItem(Self.item(for: mode))
        }
    }

    internal static func item(for mode: ConnectionWorkspaceContentMode) -> NSMenuItem {
        let item = NSMenuItem(title: mode.localizedTitle, action: action, keyEquivalent: "")
        item.target = nil
        item.representedObject = mode.rawValue
        return item
    }

    /// Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
