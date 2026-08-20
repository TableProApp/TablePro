//
//  MainWindowToolbar+Items.swift
//  TablePro
//

import AppKit
import SwiftUI

extension MainWindowToolbar {
    // MARK: - Subitem Builders

    /// The name of the driver's own query language, so the Preview tooltip says "Preview MQL" on
    /// MongoDB rather than a generic word the user has to translate.
    var previewDescription: String {
        let language = coordinator.map {
            PluginManager.shared.queryLanguageName(for: $0.toolbarState.databaseType)
        } ?? String(localized: "SQL")
        return String(format: String(localized: "Preview %@"), language)
    }

    func subitemConnection() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.connection,
            label: String(localized: "Connection"),
            symbol: "network",
            action: #selector(performOpenConnectionSwitcher(_:)),
            shortcut: .switchConnection,
            description: String(localized: "Switch Connection")
        )
    }

    /// What this driver calls the thing a connection browses, so the item reads "Open Keyspace" on
    /// Cassandra rather than a word that does not exist there.
    var containerEntityName: String {
        coordinator.map {
            PluginManager.shared.containerEntityName(for: $0.toolbarState.databaseType)
        } ?? String(localized: "Database")
    }

    func subitemDatabase() -> NSToolbarItem {
        let containerName = containerEntityName
        return menuOnlyItem(
            id: Self.database,
            label: containerName,
            symbol: "cylinder",
            action: #selector(performOpenDatabaseSwitcher(_:)),
            shortcut: .openDatabase,
            description: String(format: String(localized: "Open %@"), containerName)
        )
    }

    func subitemRefresh() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.refresh,
            label: String(localized: "Refresh"),
            symbol: "arrow.clockwise",
            action: #selector(performRefresh(_:)),
            shortcut: .refresh
        )
    }

    func subitemSaveChanges() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.saveChanges,
            label: String(localized: "Save Changes"),
            symbol: "checkmark.circle.fill",
            action: #selector(performSaveChanges(_:)),
            shortcut: .saveChanges
        )
    }

    /// A row insert is a change to the data, so it belongs with the other data commands rather than
    /// in the status bar, which reports what is on screen. It ships as a subitem of an existing group
    /// so a toolbar the user already customized picks it up: `autosavesConfiguration` restores the
    /// saved identifier list, and a brand new top-level identifier would never appear for them.
    func subitemAddRow() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.addRow,
            label: String(localized: "Add Row"),
            symbol: "plus",
            action: #selector(performAddRow(_:)),
            shortcut: .addRow
        )
    }

    func subitemExport() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.exportTables,
            label: String(localized: "Export"),
            symbol: "square.and.arrow.up",
            action: #selector(performExport(_:)),
            shortcut: .export,
            description: String(localized: "Export Data")
        )
    }

    /// `NSMenuToolbarItem` is the toolbar control that opens a menu. A plain `NSToolbarItem` with a
    /// submenu on its `menuFormRepresentation` only shows that menu in the overflow list.
    ///
    /// It carries no action on purpose. Given one, AppKit splits the control into a body that sends
    /// the action and a separate chevron that opens the menu, so clicking the item itself does
    /// nothing whenever the driver offers more than one format. With no action the whole control
    /// opens the menu, and a single-format driver simply gets a one-item menu.
    func subitemImport() -> NSToolbarItem {
        let label = String(localized: "Import")
        let item = NSMenuToolbarItem(itemIdentifier: Self.importTables)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: label)
        item.menu = buildImportSubmenu()

        let menuItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        menuItem.image = item.image
        menuItem.submenu = buildImportSubmenu()
        item.menuFormRepresentation = menuItem
        bindMenuForm(action: #selector(performImportFormat(_:)), to: Self.importTables)

        bindShortcut(.importData, description: String(localized: "Import Data"), to: item)
        return item
    }

    func buildImportSubmenu() -> NSMenu {
        let menu = NSMenu()
        guard let databaseType = coordinator?.connection.type else { return menu }
        for format in PluginManager.shared.importFormatOptions(for: databaseType) {
            let menuItem = NSMenuItem(
                title: format.submenuLabel,
                action: #selector(performImportFormat(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = format.id
            menu.addItem(menuItem)
        }
        return menu
    }

    // MARK: - Helpers

    func hostingItem<Content: View>(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String?,
        action: Selector?,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        retainsController: Bool = true,
        content: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label

        // Controller must outlive the item; AppKit doesn't retain it and the view orphans otherwise.
        // focusable(false) stops SwiftUI from claiming scene focus on click, which would break menu shortcuts.
        let controller = NSHostingController(rootView: AnyView(content.focusable(false)))
        controller.sizingOptions = MainWindowToolbar.hostedItemSizingOptions
        retain(controller, for: id, when: retainsController)
        item.view = controller.view

        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
        if let action {
            item.target = self
            item.action = action
            item.autovalidates = true
            bindMenuForm(action: action, to: id)
            let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: keyEquivalent)
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = self
            menuItem.image = item.image
            item.menuFormRepresentation = menuItem
        }

        return item
    }

    /// The label is what the customization palette and the overflow menu show, so it stays short.
    /// The tooltip is the one place with room to say what the item does and which key runs it.
    func menuOnlyItem(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        shortcut: ShortcutAction? = nil,
        description: String? = nil,
        symbolProvider: (@MainActor () -> String)? = nil
    ) -> NSToolbarItem {
        let item = StatefulToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.target = self
        item.action = action
        item.autovalidates = true
        item.isBordered = true
        item.symbolAccessibilityDescription = label
        item.symbolProvider = symbolProvider ?? { symbol }
        bindMenuForm(action: action, to: id)

        let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.image = item.image
        item.menuFormRepresentation = menuItem

        bindShortcut(shortcut, description: description ?? label, to: item)
        return item
    }

    /// A group with real subitems and no `view` is drawn by AppKit itself, so it answers display
    /// mode changes and collapses into the overflow menu. A hosted view can do neither.
    func makeNativeGroup(
        id: NSToolbarItem.Identifier,
        label: String,
        subitems: [NSToolbarItem]
    ) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = label
        group.paletteLabel = label
        group.controlRepresentation = .automatic
        group.subitems = subitems
        return group
    }

    func makeGroup<Content: View>(
        id: NSToolbarItem.Identifier,
        label: String,
        subitems: [NSToolbarItem],
        retainsController: Bool = true,
        content: Content
    ) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = label
        group.paletteLabel = label

        // Same retention requirement as hostingItem: group.view comes from this controller.
        let controller = NSHostingController(rootView: AnyView(content.focusable(false)))
        controller.sizingOptions = MainWindowToolbar.hostedItemSizingOptions
        retain(controller, for: id, when: retainsController)
        group.view = controller.view

        group.subitems = subitems
        return group
    }

    /// One slot per identifier, and the slot belongs to the item that is actually in the toolbar.
    /// AppKit asks the delegate again with `willBeInsertedIntoToolbar: false` to build the palette
    /// copies shown by Customize Toolbar, and letting those overwrite the slot released the
    /// controllers whose views were on screen. `NSToolbarItem` does not retain its controller, so
    /// the live items collapsed to zero width the moment the panel opened. The sidebar segmented
    /// control keeps its live group in a slot of the same shape, so both read this one predicate.
    static func claimsItemSlot(willBeInsertedIntoToolbar: Bool) -> Bool {
        willBeInsertedIntoToolbar
    }

    private func retain(
        _ controller: NSHostingController<AnyView>,
        for id: NSToolbarItem.Identifier,
        when retains: Bool
    ) {
        guard retains else { return }
        hostingControllers[id] = controller
    }
}
