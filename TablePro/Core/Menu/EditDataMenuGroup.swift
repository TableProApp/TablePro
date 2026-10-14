//
//  EditDataMenuGroup.swift
//  TablePro
//

import AppKit

/// Edit > Data only acts on a data file window, so it shows only while one would receive its
/// commands. A hidden submenu still matches its items' key equivalents (measured on macOS 27), so
/// every item in the group is hidden, not only the submenu.
@MainActor
internal enum EditDataMenuGroup {
    internal static let separatorIdentifier = NSUserInterfaceItemIdentifier("edit.data.separator")
    internal static let submenuIdentifier = NSUserInterfaceItemIdentifier("edit.data")

    private static let probeAction = #selector(DataFileSplitViewController.dataFileShowProperties(_:))

    internal static func isShown(forReceiver receiver: Any?) -> Bool {
        receiver is DataFileSplitViewController
    }

    internal static func update(in menu: NSMenu) {
        let receiver = NSApp.target(forAction: probeAction, to: nil, from: nil)
        setShown(isShown(forReceiver: receiver), in: menu)
    }

    internal static func setShown(_ shown: Bool, in menu: NSMenu) {
        let group = menu.items.filter { $0.identifier == separatorIdentifier || $0.identifier == submenuIdentifier }
        // Runs on every modified keystroke, so nothing is written when the group already matches.
        guard group.contains(where: { $0.isHidden == shown }) else { return }
        for item in group {
            setHidden(!shown, item)
        }
    }

    private static func setHidden(_ hidden: Bool, _ item: NSMenuItem) {
        item.isHidden = hidden
        for child in item.submenu?.items ?? [] {
            setHidden(hidden, child)
        }
    }
}

/// AppKit calls `menuNeedsUpdate` before the Edit menu opens and, because this delegate has no
/// `menuHasKeyEquivalent`, before it matches a key equivalent too.
@MainActor
internal final class EditMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        EditDataMenuGroup.update(in: menu)
    }
}
