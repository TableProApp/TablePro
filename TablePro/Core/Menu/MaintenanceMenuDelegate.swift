//
//  MaintenanceMenuDelegate.swift
//  TablePro
//

import AppKit

/// Which maintenance operations exist depends on the driver and on what is selected,
/// so the submenu is filled when it opens rather than at build time. `menuNeedsUpdate`
/// is AppKit's hook for exactly that.
@MainActor
final class MaintenanceMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let operations = NSApp.keyWindow?.mainSplitViewController?.commandActions?.maintenanceOperations ?? []
        guard !operations.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No Operations Available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for operation in operations {
            let item = NSMenuItem(
                title: operation,
                action: #selector(MainSplitViewController.runMaintenanceOperation(_:)),
                keyEquivalent: ""
            )
            item.target = nil
            item.representedObject = operation
            menu.addItem(item)
        }
    }
}

extension NSWindow {
    /// The connection window's own controller, or nil for any other window. Used only
    /// by menu delegates, which run while the menu opens and have no responder to ask.
    var mainSplitViewController: MainSplitViewController? {
        contentViewController as? MainSplitViewController
    }
}
