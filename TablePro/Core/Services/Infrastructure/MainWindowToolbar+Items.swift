//
//  MainWindowToolbar+Items.swift
//  TablePro
//

import AppKit

extension MainWindowToolbar {
    // MARK: - Item Builders

    /// The name of the driver's own query language, so the Preview tooltip says "Preview MQL" on
    /// MongoDB rather than a generic word the user has to translate.
    var previewDescription: String {
        let language = coordinator.map {
            PluginManager.shared.queryLanguageName(for: $0.toolbarState.databaseType)
        } ?? String(localized: "SQL")
        return String(format: String(localized: "Preview %@"), language)
    }

    /// The engine's own glyph, which is what the centred status item used to draw beside the
    /// connection name. It is the brand channel and nothing else: the connection's identity colour
    /// deliberately never reaches a glyph, because a second meaning painted over the engine's own
    /// colour reads as a hue shift rather than a signal (#2398).
    var engineGlyph: NSImage? {
        let type = coordinator?.toolbarState.databaseType
        let label = type?.rawValue ?? String(localized: "Connection")
        guard let name = type?.iconName else {
            return NSImage(systemSymbolName: "network", accessibilityDescription: label)
        }
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label) {
            return symbol
        }
        /// Copied before it is touched. `NSImage(named:)` returns the one cached instance for that
        /// asset, so setting `isTemplate` or `accessibilityDescription` on it rewrites the image
        /// every other engine-icon consumer in the app is holding.
        guard let asset = NSImage(named: name)?.copy() as? NSImage else { return nil }
        asset.isTemplate = true
        asset.accessibilityDescription = label
        return asset
    }

    /// The connection's own name, which is what the centred item is for. Empty for a window that
    /// is between connections, where AppKit draws the glyph alone rather than an empty capsule.
    var connectionTitle: String {
        coordinator?.connection.name ?? ""
    }

    /// The container this control switches, and only that. It briefly read "app › public" on a
    /// schema-grouped engine while the click still opened the database chooser, which makes the
    /// word the user aimed at the one thing the control cannot change. The schema has its own
    /// commands under Database > Schema, including the same chooser.
    var containerTitle: String {
        coordinator?.toolbarState.currentDatabase ?? ""
    }

    /// The verb the selected tab commits with, for an item vended now. `refreshCommitVerb(for:)`
    /// keeps a live one in step, from the same tab kind.
    var commitVerb: String {
        ToolbarContextResolver.commitVerb(for: coordinator?.tabManager.selectedTab?.tabType)
    }

    func makeConnectionItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.connection,
            label: String(localized: "Connection"),
            symbol: "network",
            action: #selector(performOpenConnectionSwitcher(_:)),
            shortcut: .switchConnection,
            description: String(localized: "Switch Connection"),
            image: engineGlyph,
            titleProvider: { [weak self] in self?.connectionTitle ?? "" }
        )
    }

    /// A one-of-six chooser that also has to report which one is current, which is
    /// `NSMenuToolbarItem` plus a glyph that follows the level. `SafeModeToolbarItem.validate()`
    /// re-reads `statusProvider` on every validation pass, and `observeItemState` puts
    /// `safeModeLevel` on the list of things that trigger one.
    func makeSafeModeItem() -> NSToolbarItem {
        let label = String(localized: "Safe Mode")
        let item = SafeModeToolbarItem(itemIdentifier: Self.safeMode)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.statusProvider = { [weak self] in
            self?.coordinator?.safeModeStatus ?? SafeModeStatus(level: .silent, floor: nil)
        }
        item.isEnabledProvider = enablement(of: Self.safeMode)
        /// The same class the Database menu's submenu uses, so the two lists cannot describe
        /// different levels, and the checkmark is resolved when the menu opens rather than when
        /// the item was built. `NSMenu.delegate` is weak, so the toolbar holds this one.
        item.menu = menu(delegate: safeModeMenuDelegate)

        /// The overflow entry names the list, not the control, for the same reason the Database
        /// menu's container does: one of the levels inside it is itself called Safe Mode.
        let menuItem = NSMenuItem(title: String(localized: "Safe Mode Level"), action: nil, keyEquivalent: "")
        menuItem.submenu = menu(delegate: safeModeMenuDelegate)
        item.menuFormRepresentation = menuItem
        /// No `toolTip` here. `statusProvider` already wrote one naming the current level, and
        /// overwriting it with the bare label was permanent: `applyStatus` returns early once the
        /// status it applied has not changed, so nothing would ever put the level back.
        return item
    }

    /// The long tail of what a context can do, in one control whose menu changes with the tab.
    ///
    /// `ellipsis.circle` is the glyph Finder gives its own Action pull-down. The menu is built by
    /// `ConnectionActionsMenuDelegate` when it opens. The overflow entry is AppKit's own and is
    /// left to it: measured on macOS 27, an `NSMenuToolbarItem` answers `menuFormRepresentation`
    /// with a fresh item titled with its label over this same menu, whatever was assigned, so a
    /// narrow window's overflow offers exactly what the control would.
    func makeActionsItem() -> NSToolbarItem {
        let label = String(localized: "Actions")
        let item = StatefulMenuToolbarItem(itemIdentifier: Self.actions)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: label)
        item.toolTip = String(localized: "Commands for the current tab and connection")
        item.isEnabledProvider = enablement(of: Self.actions)
        item.menu = menu(delegate: actionsMenuDelegate)
        return item
    }

    /// A menu filled by its delegate when it opens. `NSMenu.delegate` is weak, so the delegate is
    /// one the toolbar keeps.
    private func menu(delegate: any NSMenuDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = delegate
        return menu
    }

    /// The enablement a menu-owning item asks for on each validation pass, answered by the same
    /// resolver and from the same pass context as every other item.
    private func enablement(of identifier: NSToolbarItem.Identifier) -> @MainActor () -> Bool {
        { [weak self] in
            guard let self else { return false }
            return ToolbarContextResolver.isEnabled(identifier, context: self.validationContext())
        }
    }

    /// What this driver calls the thing a connection browses, so the item reads "Open Keyspace" on
    /// Cassandra rather than a word that does not exist there.
    var containerEntityName: String {
        coordinator.map {
            PluginManager.shared.containerEntityName(for: $0.toolbarState.databaseType)
        } ?? String(localized: "Database")
    }

    func makeDatabaseItem() -> NSToolbarItem {
        let containerName = containerEntityName
        return menuOnlyItem(
            id: Self.database,
            label: containerName,
            symbol: "cylinder",
            action: #selector(performOpenDatabaseSwitcher(_:)),
            shortcut: .openDatabase,
            description: String(format: String(localized: "Open %@"), containerName),
            titleProvider: { [weak self] in self?.containerTitle ?? "" }
        )
    }

    func makeNewTabItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.newTab,
            label: String(localized: "New Tab"),
            symbol: "plus.rectangle",
            action: #selector(performNewTab(_:)),
            shortcut: .newTab,
            description: String(localized: "New Query Tab")
        )
    }

    func makeQuickSwitcherItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.quickSwitcher,
            label: String(localized: "Open Quickly"),
            symbol: "magnifyingglass",
            action: #selector(performOpenQuickSwitcher(_:)),
            shortcut: .quickSwitcher
        )
    }

    func makeRefreshItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.refresh,
            label: String(localized: "Refresh"),
            symbol: "arrow.clockwise",
            action: #selector(performRefresh(_:)),
            shortcut: .refresh
        )
    }

    /// No text label on either button: the HIG asks for the standard chevrons and says not to
    /// label a Back control. `chevron.backward` and `chevron.forward` mirror in a right-to-left
    /// layout, which `chevron.left` and `chevron.right` do not.
    func makeNavigateBackItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.navigateBack,
            label: String(localized: "Back"),
            symbol: "chevron.backward",
            action: #selector(performNavigateBack(_:)),
            shortcut: .navigateBack
        )
    }

    func makeNavigateForwardItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.navigateForward,
            label: String(localized: "Forward"),
            symbol: "chevron.forward",
            action: #selector(performNavigateForward(_:)),
            shortcut: .navigateForward
        )
    }

    /// Labelled with the verb the tab commits with, and re-labelled by `refreshCommitVerb(for:)` when
    /// the tab kind moves, so the palette, the overflow entry and the tooltip never offer to save a
    /// table definition that is about to be created.
    func makeSaveChangesItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.saveChanges,
            label: commitVerb,
            symbol: "checkmark.circle.fill",
            action: #selector(performSaveChanges(_:)),
            shortcut: .saveChanges
        )
    }

    /// A row insert is a change to the data, so it belongs with the other data commands rather than
    /// in the status bar, which reports what is on screen. Offered by Customize Toolbar and by the
    /// Actions pull-down on a table tab showing data.
    func makeAddRowItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.addRow,
            label: String(localized: "Add Row"),
            symbol: "plus",
            action: #selector(performAddRow(_:)),
            shortcut: .addRow
        )
    }

    /// It stays enabled without a license. The point of it being here is that someone who has just
    /// saved the wrong thing finds it, and finding it is what makes the licence worth buying; a
    /// dimmed item they never notice sells nothing and helps nobody.
    func makeRestorePreviousValuesItem() -> NSToolbarItem {
        menuOnlyItem(
            id: Self.restorePreviousValues,
            label: String(localized: "Restore Previous Values"),
            symbol: "clock.arrow.circlepath",
            action: #selector(performRestorePreviousValues(_:)),
            description: String(localized: "Restore the previous values of a save")
        )
    }

    func makeExportItem() -> NSToolbarItem {
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
    /// The formats come from `ImportFormatMenuDelegate` when the menu opens, the same instance the
    /// Actions pull-down's Import Data submenu uses, so the two lists cannot differ. The overflow
    /// entry is AppKit's, over this same menu, for the reason `makeActionsItem` gives.
    func makeImportItem() -> NSToolbarItem {
        let label = String(localized: "Import")
        let item = StatefulMenuToolbarItem(itemIdentifier: Self.importTables)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: label)
        item.isEnabledProvider = enablement(of: Self.importTables)
        item.menu = menu(delegate: importFormatMenuDelegate)
        bindShortcut(.importData, description: String(localized: "Import Data"), to: item)
        return item
    }

    // MARK: - Helpers

    /// The label is what the customization palette and the overflow menu show, so it stays short.
    /// The tooltip is the one place with room to say what the item does and which key runs it.
    ///
    /// `image` overrides the symbol for an item whose glyph is not an SF Symbol at all, which is
    /// the engine icons: half of them are asset-catalog art.
    ///
    /// `titleProvider` supplies the words an item draws beside its glyph, which is not the label:
    /// measured, an icon-only toolbar suppresses the label and still draws the title, and that is
    /// what lets the centred pair read as words while every other item stays a glyph. It is a
    /// closure because the words follow the connection, and the item outlives every connection the
    /// window shows.
    func menuOnlyItem(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        shortcut: ShortcutAction? = nil,
        description: String? = nil,
        symbolProvider: (@MainActor () -> String)? = nil,
        image: NSImage? = nil,
        titleProvider: (@MainActor () -> String)? = nil
    ) -> NSToolbarItem {
        let item = StatefulToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.titleProvider = titleProvider
        item.target = self
        item.action = action
        item.autovalidates = true
        item.isBordered = true
        item.symbolAccessibilityDescription = label
        if let image {
            item.image = image
        } else {
            item.symbolProvider = symbolProvider ?? { symbol }
        }
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

    /// Which items AppKit gives up last. The HIG's rule is that trailing items "remain visible at
    /// all window sizes" while centre items "automatically collapse into the system-managed
    /// overflow menu", and `visibilityPriority` is how that order is expressed: the header says
    /// items with the highest value "are chosen last for the overflow menu".
    ///
    /// The commands are raised rather than the centre lowered, because the centre carries two
    /// names of unbounded length. Measured at 850pt with everything at the default: the connection
    /// and container titles took the whole content width and every command went to the overflow
    /// menu. A truncated container name is a worse loss than Refresh and Save.
    func applyVisibilityPriority(to item: NSToolbarItem) {
        guard item.itemIdentifier != Self.connection, item.itemIdentifier != Self.database else { return }
        item.visibilityPriority = .high
    }
}
