//
//  ViewMenuBuilder.swift
//  TablePro
//

import AppKit
import TableProConnectionLibrary

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
                String(localized: "Show Assistant"),
                action: #selector(MainSplitViewController.toggleAssistant(_:)),
                shortcut: .toggleAssistant,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Show Connections"),
                action: #selector(MainSplitViewController.toggleWorkspaceRail(_:)),
                shortcut: .toggleWorkspaceRail,
                keyboard: keyboard
            ),
            modeSubmenu(keyboard: keyboard),
            MenuItemFactory.separator,
            /// The segmented control in the toolbar was the only route to either of these, so a
            /// window whose toolbar was narrow, hidden or customized could not switch what the
            /// sidebar lists. The HIG asks that every toolbar item also be a menu-bar command.
            MenuItemFactory.item(
                String(localized: "Show Tables"),
                action: #selector(MainSplitViewController.showTablesSidebarTab(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Show Favorites"),
                action: #selector(MainSplitViewController.showFavoritesSidebarTab(_:))
            ),
            connectionSortSubmenu(),
            MenuItemFactory.separator,
            sidebarLayoutSubmenu(),
            focusSubmenu(keyboard: keyboard),
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
                String(localized: "Highlight Rules…"),
                action: #selector(MainSplitViewController.showHighlightRules(_:))
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
                String(localized: "Zoom In"),
                action: #selector(ZoomCommandResponding.zoomIn(_:)),
                keyEquivalent: "=",
                modifiers: .command
            ),
            MenuItemFactory.item(
                String(localized: "Zoom Out"),
                action: #selector(ZoomCommandResponding.zoomOut(_:)),
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

    /// Browse and Agent as a checked pair sharing one selector, the shape the Result View submenu
    /// already uses. The toolbar control is the pointer affordance; the HIG asks that every toolbar
    /// item also be a menu-bar command, and it is also the only route a UI test can drive, because a
    /// synthetic click on a segment inside an `NSToolbarItemGroup` is measured not to select it.
    private static func modeSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        let items = ConnectionWorkspaceContentMode.allCases.map { mode -> NSMenuItem in
            let item = MenuItemFactory.item(
                mode.localizedTitle,
                action: #selector(MainSplitViewController.setContentModeFromMenu(_:))
            )
            item.representedObject = mode.rawValue
            return item
        }
        /// The shortcut lives on the container so one chord toggles rather than naming one arm of a
        /// radio pair, which would leave the other arm unreachable from the keyboard.
        let container = MenuItemFactory.submenu(String(localized: "Mode"), items: items)
        let toggle = MenuItemFactory.item(
            String(localized: "Toggle Agent Mode"),
            action: #selector(MainSplitViewController.toggleContentModeFromMenu(_:)),
            shortcut: .toggleAgentMode,
            keyboard: keyboard
        )
        container.submenu?.addItem(.separator())
        container.submenu?.addItem(toggle)
        return container
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

    /// Driven from the enum rather than from a hand copy of its cases, so a mode cannot reach the
    /// status-bar switcher while having no menu item and therefore no keyboard route.
    private static let allModes: [ResultsViewMode] = ResultsViewMode.allCases

    private static func connectionSortSubmenu() -> NSMenuItem {
        MenuItemFactory.submenu(
            String(localized: "Sort Connections By"),
            items: WelcomeSortOption.allCases.map { option in
                let item = MenuItemFactory.item(
                    option.title,
                    action: #selector(WelcomeWindowController.sortConnectionList(_:))
                )
                item.representedObject = option.mode.rawValue
                return item
            }
        )
    }

    /// Where the keyboard goes, as opposed to what is on screen, which is what the rest of this menu
    /// settles. Tab walks the window's panes in reading order and is the macOS mechanism for this;
    /// these name a pane directly, for the jump Tab makes long, and for the SQL editor, which keeps
    /// Tab for itself the way every code editor does and so cannot be left with it.
    private static func focusSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Focus"), items: [
            MenuItemFactory.item(
                String(localized: "Focus Sidebar Filter"),
                action: #selector(MainSplitViewController.focusSidebarFilter(_:)),
                shortcut: .focusSidebarSearch,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Focus Object List"),
                action: #selector(MainSplitViewController.focusObjectList(_:)),
                shortcut: .focusObjectList,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Focus Editor"),
                action: #selector(MainSplitViewController.focusEditor(_:)),
                shortcut: .focusEditor,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Focus Results"),
                action: #selector(MainSplitViewController.focusResults(_:)),
                shortcut: .focusResults,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Focus Inspector"),
                action: #selector(MainSplitViewController.focusInspector(_:)),
                shortcut: .focusInspector,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Focus Assistant"),
                action: #selector(MainSplitViewController.focusAssistant(_:)),
                shortcut: .focusAssistant,
                keyboard: keyboard
            )
        ])
    }

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
