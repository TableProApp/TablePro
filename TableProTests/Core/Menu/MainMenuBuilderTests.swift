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

    /// #2172: `paste:` had no window-level implementation at all, so with focus anywhere that does
    /// not paste, AppKit disabled the item, and a disabled item still owns its key equivalent, so
    /// Command+V was swallowed for the whole window. Adding the handler without an explicit arm
    /// here would have been just as wrong in the other direction: `isEnabled` ends in
    /// `default: return true`, which would have shipped Paste permanently lit.
    @Test("Paste needs a connection and somewhere for the rows to land")
    func pasteNeedsSomewhereToLand() {
        var context = MenuValidationContext()
        context.canPasteRows = true
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
        context.isConnected = true
        #expect(enabled(#selector(MainSplitViewController.paste(_:)), context))
        context.canPasteRows = false
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
    }

    /// A database view opens as a `.table` tab with `tableContext.isEditable` false, so tab type
    /// alone would light Paste over content the row paste must never write to.
    @Test("Paste needs the tab to be editable, not merely a table tab")
    func pasteNeedsAnEditableTab() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.canPasteRows = false
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
    }

    @Test("Paste is answered by its own arm, never by the default that enables everything else")
    func pasteIsNotAnsweredByTheDefaultArm() {
        let context = MenuValidationContext(hasSelectedWorkspace: true, isConnected: true)
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
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

    /// Both handlers return at their first guard in states the old validation called enabled, so
    /// the item stayed lit and the click did nothing at all.
    @Test("Save As needs a query tab, not just a connection")
    func saveAsNeedsAQueryTab() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
        context.isQueryTab = true
        #expect(enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
    }

    @Test("Export Results needs rows to export")
    func exportResultsNeedsRows() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
        context.hasResultRows = true
        #expect(enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
    }

    @Test("Neither survives losing the connection")
    func bothStillNeedAConnection() {
        var context = MenuValidationContext()
        context.isQueryTab = true
        context.hasResultRows = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
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

    @Test("Filter bar needs an active table result grid")
    func filterBarNeedsTableResultGrid() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.toggleFilterBar(_:)), context))
        context.canUseTableResultCommands = true
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

    /// Everything a connection-scoped command could also need is switched on, so `isConnected`
    /// is the only thing left that can disable them.
    private func capableContext(phase: ConnectionWindowPhase, pane: ConnectionWindowPane) -> MenuValidationContext {
        var context = capableContext()
        context.isConnected = MainSplitViewController.isConnected(phase: phase, pane: pane)
        return context
    }

    private func capableContext() -> MenuValidationContext {
        var context = MenuValidationContext()
        context.canUseTableResultCommands = true
        context.isQueryTab = true
        context.hasResultRows = true
        context.hasQueryText = true
        context.hasPendingChanges = true
        context.hasDataPendingChanges = true
        context.hasImportFormats = true
        context.supportsBackup = true
        context.supportsRestore = true
        context.supportsContainerSwitching = true
        context.supportsServerDashboard = true
        context.supportsUserManagement = true
        context.isCurrentTabEditable = true
        context.hasTableSelection = true
        context.canShowTableStructure = true
        context.canEditViewDefinition = true
        context.hasMaintenanceOperations = true
        return context
    }

    /// A window whose coordinator is alive is exactly the case the old `coordinator != nil`
    /// check got wrong, so every phase is resolved with a renderable session behind it.
    private func livePane(for phase: ConnectionWindowPhase) -> ConnectionWindowPane {
        ConnectionWindowPaneResolver.pane(phase: phase, hasConnection: true, hasRenderableSession: true)
    }

    private var connectionScopedSelectors: [Selector] {
        [
            #selector(MainSplitViewController.refreshDatabase(_:)),
            #selector(MainSplitViewController.exportTables(_:)),
            #selector(MainSplitViewController.openQuickSwitcher(_:)),
            #selector(MainSplitViewController.goToNextPage(_:)),
            #selector(MainSplitViewController.saveDocument(_:)),
            #selector(MainSplitViewController.saveDocumentAs(_:)),
            #selector(MainSplitViewController.importData(_:)),
            #selector(MainSplitViewController.backupDatabase(_:)),
            #selector(MainSplitViewController.restoreDatabase(_:)),
            #selector(MainSplitViewController.executeQuery(_:)),
            #selector(MainSplitViewController.previewSQL(_:)),
            #selector(MainSplitViewController.createNewTable(_:)),
            #selector(MainSplitViewController.openContainerSwitcher(_:)),
            #selector(MainSplitViewController.showServerDashboard(_:)),
            #selector(MainSplitViewController.showUsersAndRoles(_:)),
            #selector(MainSplitViewController.toggleFilterBar(_:))
        ]
    }

    /// Gated on a grid, a tab or a sidebar selection the coordinator keeps across a lost session,
    /// so each one needs the connection too or it stays lit over the unavailable pane.
    private var contentScopedSelectors: [Selector] {
        [
            #selector(MainSplitViewController.addRow(_:)),
            #selector(MainSplitViewController.duplicateRow(_:)),
            #selector(MainSplitViewController.truncateTable(_:)),
            #selector(MainSplitViewController.delete(_:)),
            #selector(MainSplitViewController.showTableStructure(_:)),
            #selector(MainSplitViewController.editViewDefinition(_:)),
            #selector(MainSplitViewController.runMaintenanceOperation(_:))
        ]
    }

    @Test("A stale selection does not keep content commands enabled without a connection")
    func contentCommandsNeedTheConnection() {
        var context = capableContext()
        context.isConnected = false
        for selector in contentScopedSelectors {
            #expect(!enabled(selector, context), "\(selector) stayed enabled without a connection")
        }
        context.isConnected = true
        for selector in contentScopedSelectors {
            #expect(enabled(selector, context), "\(selector) stayed disabled while connected")
        }
    }

    @Test("Only a connected phase enables connection-scoped commands")
    func onlyConnectedPhaseEnablesCommands() {
        let disabled: [ConnectionWindowPhase] = [
            .idle,
            .connecting,
            .unavailable(.notConnected),
            .unavailable(.cancelled),
            .unavailable(.disconnected(nil)),
            .unavailable(.disconnectedByUser),
            .unavailable(.failed(ConnectionFailureInfo(message: "connection refused"))),
            .unavailable(.pluginMissing(ConnectionFailureInfo(message: "plugin missing"))),
            .closing
        ]
        let gated = connectionScopedSelectors + contentScopedSelectors
        for phase in disabled {
            let context = capableContext(phase: phase, pane: livePane(for: phase))
            for selector in gated {
                #expect(!enabled(selector, context), "\(selector) stayed enabled in phase \(phase)")
            }
        }

        let connected = capableContext(phase: .connected, pane: livePane(for: .connected))
        for selector in gated {
            #expect(enabled(selector, connected), "\(selector) stayed disabled while connected")
        }
    }

    @Test("A connected phase with nothing renderable enables nothing")
    func connectedWithoutRenderableSessionStaysDisabled() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .connected,
            hasConnection: true,
            hasRenderableSession: false
        )
        let context = capableContext(phase: .connected, pane: pane)
        #expect(!context.isConnected)
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
    }

    @Test("Connection state comes from the phase, not from a surviving object graph")
    func connectionStateFollowsPhase() {
        #expect(MainSplitViewController.isConnected(phase: .connected, pane: .content))
        #expect(!MainSplitViewController.isConnected(phase: .connecting, pane: .connecting))
        #expect(!MainSplitViewController.isConnected(phase: .idle, pane: .content))
        #expect(!MainSplitViewController.isConnected(phase: .closing, pane: .empty))
        #expect(!MainSplitViewController.isConnected(
            phase: .unavailable(.disconnectedByUser),
            pane: .unavailable(.disconnectedByUser)
        ))
    }

    @Test("Find needs an editor or a mounted data grid, not merely a result that can be filtered")
    func findNeedsAnEditor() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findNext(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findPrevious(_:)), context))
        context.canUseTableResultCommands = true
        #expect(!enabled(#selector(MainSplitViewController.performFind(_:)), context))
        context.canUseGridFindCommands = true
        #expect(enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findNext(_:)), context))
        context.canUseTableResultCommands = false
        context.canUseGridFindCommands = false
        context.hasEditorForFind = true
        #expect(enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.findNext(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.findPrevious(_:)), context))
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
            String(localized: "New Database..."),
            String(localized: "Show Table Structure"),
            String(localized: "Edit View Definition..."),
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
