//
//  MainWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine
import Observation
import os
import SwiftUI
import TableProPluginKit

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    nonisolated internal static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let toolbarIdentifier = NSToolbar.Identifier("com.TablePro.main.toolbar.v2")

    /// Which connection the toolbar is about. Every item reads through this rather than capturing
    /// a coordinator, so a switch repoints one reference instead of rebuilding eight items, two
    /// `NSHostingController`s and the window's whole titlebar.
    internal let subject = ToolbarSubject()

    internal var coordinator: MainContentCoordinator? { subject.coordinator }

    internal let managedToolbar: NSToolbar
    private var pendingChangeObservationGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    /// Which shortcut each item advertises, and the wording it advertises it with. The item cannot
    /// be asked: `NSToolbarItem` has no shortcut of its own, and its `menuFormRepresentation` keeps
    /// only the resolved key, not the action that produced it. Recorded by the factory that already
    /// receives both, so this is not a second list anyone has to keep in step by hand.
    private var shortcutBindings: [NSToolbarItem.Identifier: ToolbarShortcutBinding] = [:]

    /// Which item an overflow-menu entry stands for. AppKit validates an overflowed item as a menu
    /// item rather than as a toolbar item, so `validateToolbarItem(_:)` never runs for it and the
    /// entry stayed enabled while the same button was disabled on a wider window. Recorded by the
    /// factory that already receives both the identifier and the action, for the same reason
    /// `shortcutBindings` is: a second hand-written table drifts.
    private var menuFormIdentifiers: [Selector: NSToolbarItem.Identifier] = [:]

    /// How a hosted item answers "how wide are you". `.intrinsicContentSize` only overrides the
    /// hosting view's `intrinsicContentSize`, and AppKit measures a view-backed item when it is
    /// inserted and never reads that value again. Repointing the subject then left the item at the
    /// width of the connection that had gone: the content redrew correctly inside a container
    /// measured for the other engine, and only a click on the toolbar resized it. Under
    /// `.preferredContentSize` the hosting view resizes itself, which is what AppKit follows.
    internal static let hostedItemSizingOptions: NSHostingSizingOptions = .preferredContentSize

    /// Retain hosting controllers per item identifier. NSHostingController is not retained by NSToolbarItem,
    /// so without this its view orphans and the toolbar item collapses to zero width.
    internal var hostingControllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]
    private(set) var sidebarGroup: NSToolbarItemGroup?

    override internal convenience init() {
        self.init(managedToolbar: NSToolbar(identifier: Self.toolbarIdentifier))
    }

    internal init(managedToolbar: NSToolbar) {
        self.managedToolbar = managedToolbar
        super.init()
        self.managedToolbar.delegate = self
        self.managedToolbar.displayMode = .iconOnly
        self.managedToolbar.allowsUserCustomization = true
        self.managedToolbar.autosavesConfiguration = true
        self.managedToolbar.centeredItemIdentifiers = [Self.principal]
        /// The hop off `AppSettingsManager.keyboard`'s own `didSet` matters: without it the toolbar
        /// items are mutated re-entrantly, part way through the settings write that triggered them.
        AppEvents.shared.keyboardSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshShortcutHints() }
            .store(in: &cancellables)
    }

    /// A toolbar item's tooltip and its overflow-menu key equivalent are written once, when the
    /// delegate vends the item, and AppKit never revisits either. A rebind in Settings therefore
    /// reaches the menu bar and stops there, leaving the toolbar advertising a key that no longer
    /// runs the command.
    private func refreshShortcutHints() {
        for item in allItems() {
            applyShortcutBinding(to: item)
        }
    }

    /// Records what an item advertises and pushes it onto the item for the first time.
    internal func bindShortcut(_ shortcut: ShortcutAction?, description: String, to item: NSToolbarItem) {
        guard let shortcut else {
            item.toolTip = description
            return
        }
        shortcutBindings[item.itemIdentifier] = ToolbarShortcutBinding(
            shortcut: shortcut,
            description: description
        )
        applyShortcutBinding(to: item)
    }

    /// Records which item an overflow-menu action belongs to, so validation can reach it.
    internal func bindMenuForm(action: Selector, to itemIdentifier: NSToolbarItem.Identifier) {
        menuFormIdentifiers[action] = itemIdentifier
    }

    /// Nil for a menu item this toolbar did not build, which is nobody else's item to validate.
    internal func itemIdentifier(forMenuFormAction action: Selector?) -> NSToolbarItem.Identifier? {
        action.flatMap { menuFormIdentifiers[$0] }
    }

    /// Re-words an item whose description follows the connection, keeping its shortcut hint. Setting
    /// `toolTip` directly at those call sites is what dropped the hint on every connection switch.
    internal func updateShortcutDescription(_ description: String, for id: NSToolbarItem.Identifier) {
        shortcutBindings[id]?.description = description
    }

    internal func applyShortcutBinding(to item: NSToolbarItem) {
        guard let binding = shortcutBindings[item.itemIdentifier] else { return }
        let keyboard = AppSettingsManager.shared.keyboard
        item.toolTip = keyboard.shortcutHint(binding.description, for: binding.shortcut)
        /// An item that opens a submenu has no key equivalent to carry; its menu form is the menu.
        guard let menuItem = item.menuFormRepresentation, menuItem.submenu == nil else { return }
        MenuItemFactory.apply(shortcut: binding.shortcut, keyboard: keyboard, to: menuItem)
    }

    /// `@Observable` generates no equality check, so assigning the same coordinator still fires
    /// every observer. `windowDidBecomeKey` runs on activation with the connection unchanged, so
    /// without this guard the window would pay for a switch every time it came forward.
    internal func repoint(to coordinator: MainContentCoordinator?) {
        guard subject.coordinator !== coordinator else { return }
        pendingChangeObservationGeneration += 1
        subject.coordinator = coordinator
        observePendingChangeState()
        refreshConnectionScopedItems()
        syncSidebarSelection()
        managedToolbar.validateVisibleItems()
    }

    func invalidate() {
        pendingChangeObservationGeneration += 1
        sidebarGroup = nil
        hostingControllers.removeAll()
        subject.coordinator = nil
    }

    private func observePendingChangeState() {
        let generation = pendingChangeObservationGeneration
        let coordinatorIdentifier = coordinator.map { ObjectIdentifier($0) }
        withObservationTracking { [weak self] in
            _ = self?.coordinator?.toolbarState.hasPendingChanges
            _ = self?.coordinator?.toolbarState.hasDataPendingChanges
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.pendingChangeObservationGeneration,
                      coordinatorIdentifier == self.coordinator.map({ ObjectIdentifier($0) })
                else { return }
                self.observePendingChangeState()
                self.managedToolbar.validateVisibleItems()
            }
        }
    }

    /// Three items carry text derived from the connection's database type, and none of them can be
    /// repointed by validation: a subitem of a view-backed group is never sent `validate()`, and a
    /// menu built at construction keeps whatever it was built with. They are pushed here instead.
    private func refreshConnectionScopedItems() {
        for item in allItems() {
            switch item.itemIdentifier {
            case Self.database:
                apply(label: containerEntityName, to: item)
                updateShortcutDescription(
                    String(format: String(localized: "Open %@"), containerEntityName),
                    for: Self.database
                )
                applyShortcutBinding(to: item)
            case Self.previewSQL:
                updateShortcutDescription(previewDescription, for: Self.previewSQL)
                applyShortcutBinding(to: item)
            case Self.importTables:
                (item as? NSMenuToolbarItem)?.menu = buildImportSubmenu()
                item.menuFormRepresentation?.submenu = buildImportSubmenu()
            default:
                continue
            }
        }
    }

    /// The overflow menu keeps the title it was built with, so a label change has to reach it too.
    private func apply(label: String, to item: NSToolbarItem) {
        item.label = label
        item.paletteLabel = label
        item.menuFormRepresentation?.title = label
    }

    private func allItems() -> [NSToolbarItem] {
        managedToolbar.items.flatMap { item -> [NSToolbarItem] in
            guard let group = item as? NSToolbarItemGroup else { return [item] }
            return [item] + group.subitems
        }
    }

    // MARK: - Identifiers

    static let connectionGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.connectionGroup")
    static let connection = NSToolbarItem.Identifier("com.TablePro.toolbar.connection")
    static let database = NSToolbarItem.Identifier("com.TablePro.toolbar.database")
    static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    static let addRow = NSToolbarItem.Identifier("com.TablePro.toolbar.addRow")
    static let principal = NSToolbarItem.Identifier("com.TablePro.toolbar.principal")
    static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    static let inspector = NSToolbarItem.Identifier.toggleInspector
    static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    static let refreshSaveGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.refreshSaveGroup")
    static let exportImportGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.exportImportGroup")
    static let sidebarToggle = NSToolbarItem.Identifier("com.TablePro.toolbar.sidebarToggle")
    static let backForwardGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.backForwardGroup")
    static let navigateBack = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateBack")
    static let navigateForward = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateForward")

    // MARK: - NSToolbarDelegate

    /// Items ahead of `.sidebarTrackingSeparator` lay out in the sidebar's own titlebar strip,
    /// so the control that switches what the sidebar shows sits over the pane it drives.
    ///
    /// A tracking separator divides the toolbar into pane-aligned sections; it does not align the
    /// items inside one. Everything after `.inspectorTrackingSeparator` therefore lays out from
    /// that section's leading edge, which is the inspector divider, so the toggle walked inward as
    /// the pane opened and only looked right while the inspector was closed. The `.flexibleSpace`
    /// is what anchors it to the window's trailing edge, and it is the order Apple ships in
    /// WWDC23 session 10054. Keep the toggle last: ahead of the separator it lands in the content
    /// section and is wrong in both states.
    internal static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarToggle,
        .sidebarTrackingSeparator,
        backForwardGroup,
        connectionGroup,
        principal,
        .flexibleSpace,
        refreshSaveGroup,
        quickSwitcher,
        newTab,
        previewSQL,
        .inspectorTrackingSeparator,
        .flexibleSpace,
        inspector,
    ]

    internal static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = defaultItemIdentifiers + [
        results,
        exportImportGroup,
        dashboard,
        history,
    ]

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }
}

// MARK: - Sidebar Toggle

extension MainWindowToolbar {
    private static let sidebarSegmentTabs: [SidebarTab] = [.tables, .favorites]

    /// A one-of-N segmented toolbar control is `NSToolbarItemGroup` with `.selectOne`.
    /// Hand-building two `NSButton`s meant faking selection with border tricks and a
    /// deprecated bezel, and polling `@Observable` state to keep them in sync.
    ///
    /// The group must not be navigational. `isNavigational` lets AppKit lift an item out of its
    /// declared slot and pin it to the leading edge of the content title area, the way Finder
    /// places back and forward, which put this control past the sidebar divider no matter where
    /// `defaultItemIdentifiers` listed it. Without the flag it lays out in the sidebar's own
    /// titlebar strip, and follows the divider when the sidebar collapses.
    internal static func makeSidebarSegmentGroup(target: AnyObject?, action: Selector) -> NSToolbarItemGroup {
        let images = ["list.bullet", "star"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: sidebarToggle,
            images: images,
            selectionMode: .selectOne,
            labels: [String(localized: "Tables"), String(localized: "Favorites")],
            target: target,
            action: action
        )
        group.label = String(localized: "Sidebar")
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        return group
    }

    /// `sidebarGroup` is the one handle `syncSidebarSelection()` has on the live control, so only
    /// the item actually going into the toolbar may claim it. A Customize Toolbar palette copy
    /// that took the slot left every later sync writing into a discarded group, and the segments
    /// stopped following the sidebar until the window was reopened.
    internal func makeSidebarToggleItem(claimsSlot: Bool) -> NSToolbarItem {
        let group = Self.makeSidebarSegmentGroup(target: self, action: #selector(sidebarSegmentChanged(_:)))
        bindMenuForm(action: #selector(sidebarSegmentChanged(_:)), to: Self.sidebarToggle)
        guard claimsSlot else { return group }
        sidebarGroup = group
        syncSidebarSelection()
        return group
    }

    /// `@objc` does not type-check the sender, and this action is reachable from the overflow menu
    /// as well as from the control, where AppKit sends an `NSMenuItem`. A typed parameter would
    /// read `selectedIndex` off it and trap on `doesNotRecognizeSelector`.
    @objc fileprivate func sidebarSegmentChanged(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let index = group.selectedIndex
        guard Self.sidebarSegmentTabs.indices.contains(index) else { return }
        coordinator?.splitViewController?.setSidebarTab(Self.sidebarSegmentTabs[index])
    }

    /// Pushed from the split view controller whenever the sidebar tab or its collapsed
    /// state changes, instead of an observation loop watching for it.
    internal func syncSidebarSelection() {
        guard let group = sidebarGroup, let coordinator else { return }
        let sidebarState = SharedSidebarState.forConnection(coordinator.connectionId)
        let sidebarVisible = !(coordinator.splitViewController?.isSidebarCollapsed ?? true)
        group.selectedIndex = sidebarVisible
            ? (Self.sidebarSegmentTabs.firstIndex(of: sidebarState.selectedSidebarTab) ?? -1)
            : -1
        managedToolbar.validateVisibleItems()
    }
}
