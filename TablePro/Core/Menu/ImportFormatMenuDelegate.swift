//
//  ImportFormatMenuDelegate.swift
//  TablePro
//

import AppKit

/// The formats the connection's driver imports from, filled when the menu opens.
///
/// Filled on open rather than when the menu is built, because the list is the driver's and a window
/// changes driver with every connection switch. The menu this replaces was rebuilt by hand on each
/// repoint, and a copy built at any other moment kept the formats of the connection it was built for.
///
/// Every entry carries no target and names its format in `representedObject`, so AppKit resolves it
/// through the responder chain to the window's controller and validates it there, the way the menu
/// bar's own commands are. The entries this replaces targeted the toolbar object, which is not a
/// responder, so a menu resolved through the chain could not have reached them at all.
///
/// One class serves every place the list is offered: File > Import > Import Data From, the Actions
/// pull-down's row of the same name, and the Import item a user can add from Customize Toolbar. Each
/// asks the key window when it opens, so none of them can list another connection's formats.
///
/// Built on the same shape as `SafeModeMenuDelegate`, including the responder-chain lookup that
/// finds the window the chosen format will import into. `NSMenu.delegate` is weak, so whoever builds
/// a menu keeps the delegate alive alongside it.
@MainActor
internal final class ImportFormatMenuDelegate: NSObject, NSMenuDelegate {
    internal static let action = #selector(MainSplitViewController.importDataFormat(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        let formats = controller?.commandActions?.availableImportFormats ?? []
        guard !formats.isEmpty else {
            menu.addItem(Self.placeholder())
            return
        }
        for format in formats {
            menu.addItem(Self.item(for: format))
        }
    }

    internal static func item(for format: ImportFormatOption) -> NSMenuItem {
        let item = NSMenuItem(title: format.formatLabel, action: action, keyEquivalent: "")
        item.target = nil
        item.representedObject = format.id
        return item
    }

    /// A list with nothing in it opens as a sliver with no text, which reads as a broken command.
    /// The row that opens it cannot be dimmed through the responder chain, because AppKit gives a
    /// submenu's row its own action, so the list says why it is empty instead, the way Database >
    /// Session Context does. That happens with no connection window in front, and with a driver
    /// whose import plugins are missing or failed to load.
    internal static func placeholder() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "None Available"), action: nil, keyEquivalent: "")
        item.isEnabled = false
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
