//
//  MainWindowToolbar+Items.swift
//  TablePro
//

import AppKit
import SwiftUI

extension MainWindowToolbar {
    // MARK: - Subitem Builders

    func subitemConnection() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.connection,
            label: String(localized: "Connection"),
            symbol: "network",
            action: #selector(performOpenConnectionSwitcher(_:)),
            keyEquivalent: "c",
            modifiers: [.command, .option]
        )
    }

    func subitemDatabase() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.database,
            label: String(localized: "Database"),
            symbol: "cylinder",
            action: #selector(performOpenDatabaseSwitcher(_:)),
            keyEquivalent: "k",
            modifiers: .command
        )
    }

    func subitemRefresh() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.refresh,
            label: String(localized: "Refresh"),
            symbol: "arrow.clockwise",
            action: #selector(performRefresh(_:)),
            keyEquivalent: "r",
            modifiers: .command
        )
    }

    func subitemSaveChanges() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.saveChanges,
            label: String(localized: "Save Changes"),
            symbol: "checkmark.circle.fill",
            action: #selector(performSaveChanges(_:)),
            keyEquivalent: "s",
            modifiers: .command
        )
    }

    func subitemExport() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.exportTables,
            label: String(localized: "Export"),
            symbol: "square.and.arrow.up",
            action: #selector(performExport(_:)),
            keyEquivalent: "e",
            modifiers: [.command, .shift]
        )
    }

    func subitemImport() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.importTables,
            label: String(localized: "Import"),
            symbol: "square.and.arrow.down",
            action: #selector(performImport(_:)),
            keyEquivalent: "i",
            modifiers: [.command, .shift]
        )
    }

    // MARK: - Helpers

    func hostingItem<Content: View>(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String?,
        action: Selector?,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        content: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label

        // Controller must outlive the item; AppKit doesn't retain it and the view orphans otherwise.
        // focusable(false) stops SwiftUI from claiming scene focus on click, which would break menu shortcuts.
        let controller = NSHostingController(rootView: AnyView(content.focusable(false)))
        controller.sizingOptions = .intrinsicContentSize
        hostingControllers[id] = controller
        item.view = controller.view

        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
        if let action {
            item.target = self
            item.action = action
            item.autovalidates = true
            let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: keyEquivalent)
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = self
            menuItem.image = item.image
            item.menuFormRepresentation = menuItem
        }

        return item
    }

    func menuOnlyItem(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.target = self
        item.action = action
        item.autovalidates = true
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)

        let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: keyEquivalent)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = self
        menuItem.image = item.image
        item.menuFormRepresentation = menuItem

        return item
    }

    func makeGroup<Content: View>(
        id: NSToolbarItem.Identifier,
        label: String,
        subitems: [NSToolbarItem],
        content: Content
    ) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = label
        group.paletteLabel = label

        // Same retention requirement as hostingItem: group.view comes from this controller.
        let controller = NSHostingController(rootView: AnyView(content.focusable(false)))
        controller.sizingOptions = .intrinsicContentSize
        hostingControllers[id] = controller
        group.view = controller.view

        group.subitems = subitems
        return group
    }
}
