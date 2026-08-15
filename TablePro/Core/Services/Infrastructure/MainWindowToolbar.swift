//
//  MainWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    internal static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let toolbarIdentifier = NSToolbar.Identifier("com.TablePro.main.toolbar.v2")

    /// Which connection the toolbar is about. Every item reads through this rather than capturing
    /// a coordinator, so a switch repoints one reference instead of rebuilding eight items, two
    /// `NSHostingController`s and the window's whole titlebar.
    internal let subject = ToolbarSubject()

    internal var coordinator: MainContentCoordinator? { subject.coordinator }

    internal let managedToolbar: NSToolbar

    /// Retain hosting controllers per item identifier. NSHostingController is not retained by NSToolbarItem,
    /// so without this its view orphans and the toolbar item collapses to zero width.
    internal var hostingControllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]
    private(set) var sidebarGroup: NSToolbarItemGroup?

    override internal init() {
        self.managedToolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        super.init()
        self.managedToolbar.delegate = self
        self.managedToolbar.displayMode = .iconOnly
        self.managedToolbar.allowsUserCustomization = true
        self.managedToolbar.autosavesConfiguration = true
        self.managedToolbar.centeredItemIdentifiers = [Self.principal]
    }

    /// `@Observable` generates no equality check, so assigning the same coordinator still fires
    /// every observer. `windowDidBecomeKey` runs on activation with the connection unchanged, so
    /// without this guard the window would pay for a switch every time it came forward.
    internal func repoint(to coordinator: MainContentCoordinator?) {
        guard subject.coordinator !== coordinator else { return }
        subject.coordinator = coordinator
        refreshConnectionScopedItems()
        syncSidebarSelection()
        managedToolbar.validateVisibleItems()
    }

    func invalidate() {
        sidebarGroup = nil
        hostingControllers.removeAll()
        subject.coordinator = nil
    }

    /// Three items carry text derived from the connection's database type, and none of them can be
    /// repointed by validation: a subitem of a view-backed group is never sent `validate()`, and a
    /// menu built at construction keeps whatever it was built with. They are pushed here instead.
    private func refreshConnectionScopedItems() {
        for item in allItems() {
            switch item.itemIdentifier {
            case Self.database:
                apply(label: containerEntityName, to: item)
                item.toolTip = String(format: String(localized: "Open %@"), containerEntityName)
            case Self.previewSQL:
                item.toolTip = previewDescription
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

    // MARK: - NSToolbarDelegate

    /// Items ahead of `.sidebarTrackingSeparator` lay out in the sidebar's own titlebar strip,
    /// so the control that switches what the sidebar shows sits over the pane it drives.
    internal static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarToggle,
        .sidebarTrackingSeparator,
        connectionGroup,
        principal,
        .flexibleSpace,
        refreshSaveGroup,
        quickSwitcher,
        newTab,
        previewSQL,
        .inspectorTrackingSeparator,
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

    internal func makeSidebarToggleItem() -> NSToolbarItem {
        let group = Self.makeSidebarSegmentGroup(target: self, action: #selector(sidebarSegmentChanged(_:)))
        sidebarGroup = group
        syncSidebarSelection()
        return group
    }

    @objc fileprivate func sidebarSegmentChanged(_ sender: NSToolbarItemGroup) {
        let index = sender.selectedIndex
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
