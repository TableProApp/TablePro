//
//  SafeModeMenuDelegate.swift
//  TablePro
//

import AppKit

/// The safe-mode level list, filled when it opens so the checkmark names the level the window is
/// actually on. One class serves both surfaces that offer it, the Database menu's submenu and the
/// toolbar's own control, so the two cannot describe different levels.
///
/// Built on the same shape as `SchemaMenuDelegate`, including the responder-chain lookup that
/// resolves the window the chosen level will apply to. `NSMenu.delegate` is weak, so whoever
/// builds a menu keeps the delegate alive alongside it.
@MainActor
final class SafeModeMenuDelegate: NSObject, NSMenuDelegate {
    private static let action = #selector(MainSplitViewController.setSafeModeLevel(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        let current = controller?.commandActions?.coordinator?.toolbarState.safeModeLevel
        for level in SafeModeLevel.allCases {
            menu.addItem(item(for: level, current: current))
        }
    }

    private func item(for level: SafeModeLevel, current: SafeModeLevel?) -> NSMenuItem {
        let item = NSMenuItem(title: level.displayName, action: Self.action, keyEquivalent: "")
        item.target = nil
        item.representedObject = level.rawValue
        item.state = level == current ? .on : .off
        item.image = NSImage(systemSymbolName: level.iconName, accessibilityDescription: nil)
        return item
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
