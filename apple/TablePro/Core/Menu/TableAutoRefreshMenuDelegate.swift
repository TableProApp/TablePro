//
//  TableAutoRefreshMenuDelegate.swift
//  TablePro
//

import AppKit

// Filled when it opens, so the checkmark names the selected tab's interval; validation dims the items off a table tab.
@MainActor
final class TableAutoRefreshMenuDelegate: NSObject, NSMenuDelegate {
    static let action = #selector(MainSplitViewController.setTableAutoRefreshInterval(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        Self.populate(menu, current: controller?.tableAutoRefreshInterval)
    }

    internal static func populate(_ menu: NSMenu, current: TableAutoRefreshInterval?) {
        menu.removeAllItems()
        for interval in TableAutoRefreshInterval.allCases {
            let item = NSMenuItem(title: interval.title, action: action, keyEquivalent: "")
            item.target = nil
            item.representedObject = interval.rawValue
            item.state = interval == current ? .on : .off
            menu.addItem(item)
        }
    }

    // Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
