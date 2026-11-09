//
//  ObjectKindsToolbarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// The optional Objects group: six buttons that reach each kind of object in one click.
@MainActor
struct ObjectKindsToolbarTests {
    /// A private identifier with autosave off: the test host shares the app's defaults, so a toolbar
    /// named like the app's own would carry anything done to it into the next real launch.
    private static func owner(objectsOn: Bool = true) -> MainWindowToolbar {
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.objectKinds.\(UUID().uuidString)")
        toolbar.autosavesConfiguration = false
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        owner.objectKindsEnabled = { objectsOn }
        return owner
    }

    private static func group(from owner: MainWindowToolbar) throws -> NSToolbarItemGroup {
        try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.objectKindsGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )
    }

    private static func subitem(
        _ identifier: NSToolbarItem.Identifier,
        of owner: MainWindowToolbar
    ) throws -> NSToolbarItem {
        try #require(group(from: owner).subitems.first { $0.itemIdentifier == identifier })
    }

    /// What a click does: the button's own action, sent to the button's own target.
    private static func press(_ identifier: NSToolbarItem.Identifier, on owner: MainWindowToolbar) throws {
        let item = try subitem(identifier, of: owner)
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item), "\(identifier.rawValue) reached no target")
    }

    private static func makeActions(for fixture: CoordinatorFixture) -> MainContentCommandActions {
        let actions = MainContentCommandActions(
            coordinator: fixture.coordinator,
            connection: fixture.connection,
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            trailingPaneState: TrailingPaneState()
        )
        fixture.coordinator.commandActions = actions
        return actions
    }

    // MARK: - The group

    /// A group with real subitems and no view is drawn by AppKit, so it dims a button, answers the
    /// display mode and collapses into one overflow entry when the window narrows.
    @Test("Each button is a named AppKit glyph routed to the toolbar")
    func subitemsAreDrawnByAppKit() throws {
        let owner = Self.owner()
        let group = try Self.group(from: owner)

        #expect(group.label == String(localized: "Objects"))
        #expect(group.controlRepresentation == .automatic)
        #expect(group.visibilityPriority == .high)
        for item in group.subitems {
            let name = item.itemIdentifier.rawValue
            #expect(item.view == nil, "\(name) must not be view-backed")
            #expect(!item.label.isEmpty, "\(name) needs a label")
            #expect(item.image != nil, "\(name) names no symbol that exists")
            #expect(item.target === owner, "\(name) must route through the toolbar")
            #expect(item.action != nil, "\(name) has no action")
        }
    }

    @Test("Query advertises its shortcut, and every button its name")
    func queryAdvertisesItsShortcut() throws {
        let owner = Self.owner()
        let query = try Self.subitem(MainWindowToolbar.objectQuery, of: owner)
        let tables = try Self.subitem(MainWindowToolbar.objectTables, of: owner)

        #expect(query.toolTip == AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Query"), for: .newTab))
        #expect(query.toolTip != String(localized: "Query"), "The hint adds the key that runs the command")
        #expect(tables.toolTip == String(localized: "Tables"))
    }

    /// AppKit validates an overflowed button as a menu item, so each entry has to resolve back to
    /// its own button's rule, or a disconnected window's entries stay live and do nothing.
    @Test("Each overflow entry validates as its own button")
    func overflowEntriesValidateAsTheirButtons() throws {
        let owner = Self.owner()
        for item in try Self.group(from: owner).subitems {
            let entry = try #require(item.menuFormRepresentation)
            #expect(owner.itemIdentifier(forMenuFormAction: item.action) == item.itemIdentifier)
            #expect(!owner.validateMenuItem(entry), "\(item.itemIdentifier.rawValue) is live with no session")
        }
    }

    // MARK: - Routing

    @Test("Tables, Views and Functions open the browsed container's objects on their kind", arguments: [
        (MainWindowToolbar.objectTables.rawValue, SidebarObjectKind.table),
        (MainWindowToolbar.objectViews.rawValue, .view),
        (MainWindowToolbar.objectFunctions.rawValue, .function),
    ])
    func listingButtonsOpenTheirKind(identifier: String, kind: SidebarObjectKind) throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .mysql))
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)

        try Self.press(NSToolbarItem.Identifier(identifier), on: owner)

        let tab = try #require(fixture.tabManager.selectedTab)
        #expect(tab.tabType == .tableListing)
        #expect((tab.display.listingKind ?? .table) == kind)
        #expect(!tab.isPreview, "A click on a button keeps the tab")
        #expect(tab.tableContext.databaseName == fixture.coordinator.browseDatabaseName)
    }

    @Test("A second kind retargets the Objects tab already open")
    func aSecondKindRetargetsTheOpenTab() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .mysql))
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)

        try Self.press(MainWindowToolbar.objectTables, on: owner)
        try Self.press(MainWindowToolbar.objectViews, on: owner)

        let listings = fixture.tabManager.tabs.filter { $0.tabType == .tableListing }
        #expect(listings.count == 1)
        #expect(listings.first?.display.listingKind == .view)
    }

    @Test("Query opens a query tab, and Backup asks for the backup sheet")
    func queryAndBackupReachTheirCommands() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        let actions = Self.makeActions(for: fixture)
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)

        try Self.press(MainWindowToolbar.objectQuery, on: owner)
        #expect(fixture.tabManager.selectedTab?.tabType == .query)

        try Self.press(MainWindowToolbar.objectBackup, on: owner)
        if case .backupDatabase? = fixture.coordinator.activeSheet {} else {
            Issue.record("Backup did not ask for the backup sheet")
        }
        withExtendedLifetime(actions) {}
    }

    @Test("Users opens Users & Roles")
    func usersReachesItsCommand() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        let actions = Self.makeActions(for: fixture)
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)

        try Self.press(MainWindowToolbar.objectUsers, on: owner)

        #expect(fixture.tabManager.selectedTab?.tabType == .usersRoles)
        withExtendedLifetime(actions) {}
    }

    @Test("A button pressed with no connection behind the toolbar does nothing")
    func buttonsWithNoConnectionDoNothing() throws {
        let owner = Self.owner()
        for identifier in MainWindowToolbar.objectKindItemIdentifiers {
            try Self.press(identifier, on: owner)
        }
        #expect(owner.coordinator == nil)
    }
}
