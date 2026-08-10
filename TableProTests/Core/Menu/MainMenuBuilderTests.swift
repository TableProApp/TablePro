//
//  MainMenuBuilderTests.swift
//  TableProTests
//
//  Pins the menu bar's structure: HIG menu order, title uniqueness (System
//  Settings binds an App Shortcut to a menu item's exact literal title), key
//  equivalent uniqueness (AppKit silently blanks the loser when two items claim
//  one combo), and complete coverage of every customizable shortcut.
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private func buildMenu(_ keyboard: KeyboardSettings = KeyboardSettings()) -> NSMenu {
    MainMenuBuilder.build(keyboard: keyboard)
}

/// Skips the Services submenu: assigning it to `NSApp.servicesMenu` hands it to
/// AppKit, which fills it with its own targeted items.
private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item -> [NSMenuItem] in
        guard let submenu = item.submenu, submenu !== NSApp.servicesMenu else { return [item] }
        return [item] + flatten(submenu)
    }
}

@Suite("Main menu structure")
@MainActor
struct MainMenuStructureTests {
    @Test("Top level order follows the macOS HIG")
    func topLevelOrder() {
        let titles = buildMenu().items.map(\.title)
        #expect(titles == [
            "TablePro",
            String(localized: "File"),
            String(localized: "Edit"),
            String(localized: "View"),
            String(localized: "Database"),
            String(localized: "Query"),
            String(localized: "Window"),
            String(localized: "Help")
        ])
    }

    @Test("Custom menus sit between View and Window")
    func customMenuPlacement() {
        let titles = buildMenu().items.map(\.title)
        let view = try? #require(titles.firstIndex(of: String(localized: "View")))
        let window = try? #require(titles.firstIndex(of: String(localized: "Window")))
        let database = try? #require(titles.firstIndex(of: String(localized: "Database")))
        #expect(view ?? 0 < database ?? 0)
        #expect(database ?? 0 < window ?? 0)
    }

    @Test("No two menu items share a title")
    func titlesAreUnique() {
        let titles = flatten(buildMenu())
            .filter { !$0.isSeparatorItem && $0.submenu == nil }
            .map(\.title)
        let duplicates = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "Duplicate menu titles break System Settings shortcut binding: \(duplicates)")
    }

    @Test("No two menu items claim the same key equivalent")
    func keyEquivalentsAreUnique() {
        let bound = flatten(buildMenu())
            .filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
        let duplicates = Dictionary(grouping: bound, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "AppKit blanks the loser when two items claim one combo: \(duplicates)")
    }

    @Test("Every menu item carries an action")
    func everyItemHasAnAction() {
        let dead = flatten(buildMenu())
            .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.action == nil }
            .map(\.title)
        #expect(dead.isEmpty, "Items without an action can never enable: \(dead)")
    }

    /// Only leaf commands are checked. AppKit points a submenu container at its own
    /// `submenuAction:`, and it owns Window and Help outright once they are assigned
    /// to `NSApp.windowsMenu` / `NSApp.helpMenu`.
    @Test("Every authored command leaves its target nil so the responder chain resolves it")
    func targetsAreNil() {
        let systemOwned = [String(localized: "Window"), String(localized: "Help")]
        let targeted = buildMenu().items
            .filter { !systemOwned.contains($0.title) }
            .compactMap(\.submenu)
            .flatMap(flatten)
            .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.target != nil }
            .map(\.title)
        #expect(targeted.isEmpty, "A fixed target bypasses responder-chain validation: \(targeted)")
    }
}

@Suite("Main menu shortcut coverage")
@MainActor
struct MainMenuShortcutCoverageTests {
    @Test("Every customizable action reaches exactly one menu item")
    func everyShortcutActionIsReachable() {
        let identifiers = flatten(buildMenu()).compactMap(\.identifier?.rawValue)
        for action in ShortcutAction.allCases {
            let expected = MenuItemFactory.identifier(for: action).rawValue
            let matches = identifiers.filter { $0 == expected }.count
            #expect(matches == 1, "\(action.rawValue) is bound to \(matches) menu items, expected 1")
        }
    }

    @Test("A rebound shortcut reaches the built menu")
    func reboundShortcutApplies() {
        let menu = buildMenu()
        var keyboard = KeyboardSettings()
        keyboard.shortcuts[ShortcutAction.executeQuery.rawValue] = .character("j", command: true, shift: true)
        MainMenuKeyEquivalentSync.apply(keyboard: keyboard, to: menu)

        let target = MenuItemFactory.identifier(for: .executeQuery)
        let item = flatten(menu).first { $0.identifier == target }
        #expect(item?.keyEquivalent == "j")
        #expect(item?.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test("Find keeps Cmd+F and the filter bar no longer competes for it")
    func findOwnsCommandF() {
        #expect(KeyboardSettings.defaultShortcuts[.toggleFilters] == .character("f", command: true, option: true))
        #expect(
            KeyboardSettings.defaultShortcuts[.focusSidebarSearch]
                == .character("f", command: true, option: true, control: true)
        )
        #expect(ShortcutAction.reservedAppShortcuts.contains { $0.key == .character("f", command: true) })
    }
}

@Suite("Main menu validation")
@MainActor
struct MainMenuValidationTests {
    private func enabled(_ selector: Selector, _ context: MenuValidationContext) -> Bool {
        MainSplitViewController.isEnabled(selector, context: context)
    }

    @Test("Disconnected windows disable connection-scoped commands")
    func disconnectedDisablesCommands() {
        let context = MenuValidationContext()
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.refreshDatabase(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.exportTables(_:)), context))
    }

    @Test("Execute needs both a connection and query text")
    func executeNeedsQueryText() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
        context.hasQueryText = true
        #expect(enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
    }

    @Test("Save needs pending changes and a writable connection")
    func saveNeedsPendingChanges() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.hasPendingChanges = true
        #expect(enabled(#selector(MainSplitViewController.saveDocument(_:)), context))
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocument(_:)), context))
    }

    @Test("Read-only connections block destructive commands")
    func readOnlyBlocksMutations() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.isCurrentTabEditable = true
        context.hasTableSelection = true
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.addRow(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.truncateTable(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.createNewTable(_:)), context))
    }

    @Test("Cancel Query tracks execution, not connection")
    func cancelTracksExecution() {
        var context = MenuValidationContext()
        #expect(!enabled(#selector(MainSplitViewController.cancelQuery(_:)), context))
        context.isQueryExecuting = true
        #expect(enabled(#selector(MainSplitViewController.cancelQuery(_:)), context))
    }

    @Test("Filter bar is a table-tab command")
    func filterBarNeedsTableTab() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.toggleFilterBar(_:)), context))
        context.isTableTab = true
        #expect(enabled(#selector(MainSplitViewController.toggleFilterBar(_:)), context))
    }

    @Test("Capability flags gate driver-specific commands")
    func capabilitiesGateCommands() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.showServerDashboard(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.showUsersAndRoles(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.openContainerSwitcher(_:)), context))
        context.supportsServerDashboard = true
        context.supportsUserManagement = true
        context.supportsContainerSwitching = true
        #expect(enabled(#selector(MainSplitViewController.showServerDashboard(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.showUsersAndRoles(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.openContainerSwitcher(_:)), context))
    }

    @Test("An unknown selector stays enabled so the chain can answer for it")
    func unknownSelectorsFallThrough() {
        #expect(enabled(#selector(NSWindow.performClose(_:)), MenuValidationContext()))
    }

    @Test("Object commands need exactly one selected object")
    func objectCommandsNeedSingleSelection() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.showTableStructure(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
        context.canShowTableStructure = true
        #expect(enabled(#selector(MainSplitViewController.showTableStructure(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
        context.canEditViewDefinition = true
        #expect(enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
    }

    @Test("Maintenance stays disabled when the driver offers no operations")
    func maintenanceNeedsOperations() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.runMaintenanceOperation(_:)), context))
        context.hasMaintenanceOperations = true
        #expect(enabled(#selector(MainSplitViewController.runMaintenanceOperation(_:)), context))
    }

    @Test("New Database needs a driver that switches containers")
    func createDatabaseNeedsContainerSupport() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.createNewDatabase(_:)), context))
        context.canCreateDatabase = true
        #expect(enabled(#selector(MainSplitViewController.createNewDatabase(_:)), context))
    }
}

@Suite("Database menu commands")
@MainActor
struct DatabaseMenuCommandTests {
    private func databaseMenu() -> NSMenu? {
        buildMenu().items.first { $0.title == String(localized: "Database") }?.submenu
    }

    @Test("Every command deferred from the first pass is present")
    func deferredCommandsArePresent() {
        let titles = (databaseMenu()?.items ?? []).map(\.title)
        for expected in [
            String(localized: "New Database\u{2026}"),
            String(localized: "Show Table Structure"),
            String(localized: "Edit View Definition\u{2026}"),
            String(localized: "Table Maintenance"),
            String(localized: "Disconnect"),
            String(localized: "Reconnect")
        ] {
            #expect(titles.contains(expected), "Database menu is missing \(expected)")
        }
    }

    @Test("Table Maintenance fills itself when the submenu opens")
    func maintenanceSubmenuIsDelegateDriven() {
        let container = databaseMenu()?.items.first { $0.title == String(localized: "Table Maintenance") }
        let submenu = container?.submenu
        #expect(submenu?.delegate != nil, "Driver-specific operations must be built on menuNeedsUpdate")
        #expect(submenu?.items.isEmpty == true, "The submenu is filled when it opens, not at build time")
    }

    @Test("Disconnect and Reconnect route through the responder chain")
    func connectionCommandsUseTheResponderChain() {
        let items = (databaseMenu()?.items ?? []).filter {
            $0.title == String(localized: "Disconnect") || $0.title == String(localized: "Reconnect")
        }
        #expect(items.count == 2)
        for item in items {
            #expect(item.target == nil)
        }
        #expect(items.first { $0.title == String(localized: "Disconnect") }?.action
            == #selector(MainSplitViewController.requestDisconnect))
        #expect(items.first { $0.title == String(localized: "Reconnect") }?.action
            == #selector(MainSplitViewController.retryConnection))
    }
}
