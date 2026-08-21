//
//  ViewMenuBuilder.swift
//  TablePro
//

import AppKit

/// Items whose title describes a two-state toggle are built with the "Show" variant.
/// `validateMenuItem(_:)` flips them, which is where AppKit documents a title swap
/// belongs.
@MainActor
enum ViewMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "View"), items: [
            MenuItemFactory.item(
                String(localized: "Show Sidebar"),
                action: #selector(NSSplitViewController.toggleSidebar(_:)),
                shortcut: .toggleTableBrowser,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Inspector"),
                action: #selector(MainSplitViewController.toggleInspector(_:)),
                shortcut: .toggleInspector,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Connections"),
                action: #selector(MainSplitViewController.toggleWorkspaceRail(_:)),
                shortcut: .toggleWorkspaceRail,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            sidebarLayoutSubmenu(),
            MenuItemFactory.item(
                String(localized: "Focus Sidebar Filter"),
                action: #selector(MainSplitViewController.focusSidebarFilter(_:)),
                shortcut: .focusSidebarSearch,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Filter Databases…"),
                action: #selector(MainSplitViewController.filterDatabases(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Show All Databases"),
                action: #selector(MainSplitViewController.showAllDatabases(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Filter Bar"),
                action: #selector(MainSplitViewController.toggleFilterBar(_:)),
                shortcut: .toggleFilters,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Query History"),
                action: #selector(MainSplitViewController.toggleQueryHistory(_:)),
                shortcut: .toggleHistory,
                keyboard: keyboard
            ),
            resultViewSubmenu(),
            MenuItemFactory.item(
                String(localized: "Show Results"),
                action: #selector(MainSplitViewController.toggleResults(_:)),
                shortcut: .toggleResults,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Previous Result"),
                action: #selector(MainSplitViewController.showPreviousResult(_:)),
                shortcut: .previousResultTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Next Result"),
                action: #selector(MainSplitViewController.showNextResult(_:)),
                shortcut: .nextResultTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Pin Result"),
                action: #selector(MainSplitViewController.pinResult(_:)),
                shortcut: .pinResultTab,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Close Result Tab"),
                action: #selector(MainSplitViewController.closeResultTab(_:)),
                shortcut: .closeResultTab,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Back"),
                action: #selector(MainSplitViewController.navigateBack(_:)),
                shortcut: .navigateBack,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Forward"),
                action: #selector(MainSplitViewController.navigateForward(_:)),
                shortcut: .navigateForward,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Previous Connection"),
                action: #selector(MainSplitViewController.showPreviousWorkspace(_:)),
                shortcut: .showPreviousWorkspace,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Next Connection"),
                action: #selector(MainSplitViewController.showNextWorkspace(_:)),
                shortcut: .showNextWorkspace,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Increase Text Size"),
                action: #selector(MainSplitViewController.increaseEditorTextSize(_:)),
                keyEquivalent: "=",
                modifiers: .command
            ),
            MenuItemFactory.item(
                String(localized: "Decrease Text Size"),
                action: #selector(MainSplitViewController.decreaseEditorTextSize(_:)),
                keyEquivalent: "-",
                modifiers: .command
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Show Toolbar"),
                action: #selector(NSWindow.toggleToolbarShown(_:)),
                keyEquivalent: "t",
                modifiers: [.command, .option]
            ),
            MenuItemFactory.item(
                String(localized: "Customize Toolbar…"),
                action: #selector(NSWindow.runToolbarCustomizationPalette(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Enter Full Screen"),
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.command, .control]
            )
        ])
    }

    private static func resultViewSubmenu() -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Result View"), items: allModes.map { mode in
            let item = MenuItemFactory.item(
                mode.displayName,
                action: #selector(MainSplitViewController.setResultView(_:))
            )
            item.representedObject = mode.rawValue
            return item
        })
    }

    private static let allModes: [ResultsViewMode] = [.data, .structure, .json, .chart]

    private static func sidebarLayoutSubmenu() -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Sidebar Layout"), items: [
            MenuItemFactory.item(
                String(localized: "Sidebar as List"),
                action: #selector(MainSplitViewController.useFlatSidebarLayout(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Sidebar as Tree"),
                action: #selector(MainSplitViewController.useTreeSidebarLayout(_:))
            )
        ])
    }
}
