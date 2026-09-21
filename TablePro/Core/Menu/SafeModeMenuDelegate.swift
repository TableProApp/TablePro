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
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        Self.populate(menu, with: controller?.safeModeStatus)
    }

    /// The levels the floor allows and, under them, why the rest are not there. Agent mode raising
    /// the floor used to be silent here: every level was listed, a weaker one could be picked, and
    /// the level on screen did not move. With no status, which is a window with no session, every
    /// level is listed and validation dims them.
    internal static func populate(_ menu: NSMenu, with status: SafeModeStatus?) {
        menu.removeAllItems()
        for level in status?.offeredLevels ?? SafeModeLevel.allCases {
            menu.addItem(item(for: level, current: status?.level))
        }
        guard let explanation = status?.floor?.explanation else { return }
        menu.addItem(.separator())
        menu.addItem(MenuFootnote.item(explanation))
    }

    private static func item(for level: SafeModeLevel, current: SafeModeLevel?) -> NSMenuItem {
        let item = NSMenuItem(title: level.displayName, action: action, keyEquivalent: "")
        item.target = nil
        item.representedObject = level.rawValue
        item.state = level == current ? .on : .off
        item.setInformativeImage(NSImage(systemSymbolName: level.iconName, accessibilityDescription: nil))
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
