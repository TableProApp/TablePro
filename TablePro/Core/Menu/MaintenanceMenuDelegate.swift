//
//  MaintenanceMenuDelegate.swift
//  TablePro
//

import AppKit

/// Which maintenance operations exist depends on the driver and on what is selected,
/// so the submenu is filled when it opens rather than at build time. `menuNeedsUpdate`
/// is AppKit's hook for exactly that, and the responder chain resolves the window the
/// same way it will resolve the item the user picks.
@MainActor
final class MaintenanceMenuDelegate: NSObject, NSMenuDelegate {
    private static let action = #selector(MainSplitViewController.runMaintenanceOperation(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        let operations = controller?.commandActions?.maintenanceOperations ?? []
        guard !operations.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No Operations Available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for operation in operations {
            let item = NSMenuItem(title: operation, action: Self.action, keyEquivalent: "")
            item.target = nil
            item.representedObject = operation
            menu.addItem(item)
        }
    }

    /// Implementing this keeps AppKit's key-equivalent search from rebuilding the menu on every
    /// modified keystroke, which would re-enter the plugin for items that carry no key equivalent.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
