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

    // MARK: - What the connection supports

    /// The context a toolbar pointed at a connection of this engine answers from. No driver is
    /// installed, so the engine's curated capabilities are what the context can see.
    private static func context(for type: DatabaseType, objectsOn: Bool) -> ToolbarContext {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: type))
        let actions = makeActions(for: fixture)
        let owner = owner(objectsOn: objectsOn)
        owner.repoint(to: fixture.coordinator)
        let context = owner.currentContext()
        withExtendedLifetime(actions) {}
        return context
    }

    @Test("While the group is on, the context reads what the engine supports")
    func contextReadsTheEngineWhileTheGroupIsOn() {
        let postgres = Self.context(for: .postgresql, objectsOn: true)
        #expect(postgres.supportsRoutines)
        #expect(postgres.supportsBackup)
        #expect(!postgres.canListObjects, "With no driver the engine builds no listing")
        #expect(!postgres.supportsUserManagement, "With no driver there is no capability to read")

        #expect(Self.context(for: .mongodb, objectsOn: true).canListObjects, "MongoDB lists through its own command")
        #expect(!Self.context(for: .sqlite, objectsOn: true).supportsRoutines)
    }

    /// Nothing but the group reads these, and the listing is a plugin call on every validation pass.
    @Test("While the group is off, the context asks the connection nothing for it")
    func contextAsksNothingWhileTheGroupIsOff() {
        for type in [DatabaseType.postgresql, .mongodb] {
            let context = Self.context(for: type, objectsOn: false)
            #expect(!context.canListObjects, "\(type.rawValue)")
            #expect(!context.supportsRoutines, "\(type.rawValue)")
            #expect(!context.supportsUserManagement, "\(type.rawValue)")
            #expect(!context.supportsBackup, "\(type.rawValue)")
        }
    }

    @Test("A button pressed with no connection behind the toolbar does nothing")
    func buttonsWithNoConnectionDoNothing() throws {
        let owner = Self.owner()
        for identifier in MainWindowToolbar.objectKindItemIdentifiers {
            try Self.press(identifier, on: owner)
        }
        #expect(owner.coordinator == nil)
    }

    // MARK: - Insert and remove

    /// A restored arrangement: the app's own items, without spaces, on a private identifier that
    /// never autosaves. Built with the group allowed, so `extra` can hold it, then switched to the
    /// setting the case names. AppKit builds the sidebar tracking separator only over a split view
    /// in a window, so this arrangement has none; `separatorPlacesTheGroupInAWindow` covers it.
    private static func restoredToolbar(
        including extra: [NSToolbarItem.Identifier] = [],
        settingOn: Bool,
        record: ToolbarObjectKindsRecord
    ) -> (owner: MainWindowToolbar, toolbar: NSToolbar) {
        let owner = owner(objectsOn: true)
        let toolbar = owner.managedToolbar
        owner.objectKindsRecord = record
        owner.isInWindow = { true }
        let placed = [NSToolbarItem.Identifier.toggleSidebar] + extra
            + [MainWindowToolbar.connection, MainWindowToolbar.refresh, MainWindowToolbar.actions]
        for identifier in placed {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }
        owner.objectKindsEnabled = { settingOn }
        return (owner, toolbar)
    }

    private static func identifiers(of toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbar.items.map { $0.itemIdentifier }
    }

    private static func groupCount(in toolbar: NSToolbar) -> Int {
        identifiers(of: toolbar).filter { $0 == MainWindowToolbar.objectKindsGroup }.count
    }

    @Test("Turning the setting on puts the group in once")
    func turningOnInsertsTheGroupOnce() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        #expect(!record.isApplied)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindsGroup()

        #expect(Self.groupCount(in: toolbar) == 1)
        #expect(ToolbarObjectKindsRecord(defaults: storage.defaults).isApplied)

        let (laterOwner, laterToolbar) = Self.restoredToolbar(settingOn: true, record: record)
        laterOwner.reconcileObjectKindsGroup()
        #expect(Self.groupCount(in: laterToolbar) == 0, "The change was already written into the arrangement")
    }

    @Test("Turning the setting off takes the group out")
    func turningOffRemovesTheGroup() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: [MainWindowToolbar.objectKindsGroup],
            settingOn: false,
            record: record
        )
        #expect(Self.groupCount(in: toolbar) == 1)

        owner.reconcileObjectKindsGroup()

        #expect(Self.groupCount(in: toolbar) == 0)
        #expect(!record.isApplied)
    }

    @Test("A group the user took out with Customize Toolbar stays out")
    func aRemovedGroupStaysRemoved() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindsGroup()

        #expect(Self.groupCount(in: toolbar) == 0)
        #expect(record.isApplied)
    }

    @Test("With the setting off an arrangement is left exactly as it was")
    func settingOffLeavesTheArrangementAlone() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: false, record: record)
        let before = Self.identifiers(of: toolbar)

        owner.reconcileObjectKindsGroup()

        #expect(Self.identifiers(of: toolbar) == before)
        #expect(!record.isApplied)
        #expect(storage.defaults.object(forKey: ToolbarObjectKindsRecord.key) == nil, "Nothing is written while off")
    }

    /// AppKit throws when a second item with an identifier already in the toolbar is added.
    @Test("A group already in the arrangement is not added a second time")
    func presentGroupIsNotInsertedAgain() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(
            including: [MainWindowToolbar.objectKindsGroup],
            settingOn: true,
            record: record
        )
        #expect(Self.groupCount(in: toolbar) == 1)

        owner.reconcileObjectKindsGroup()

        #expect(Self.groupCount(in: toolbar) == 1)
        #expect(record.isApplied)
    }

    /// The connection window's own toolbar, whose split view gives it the sidebar's divider.
    @Test("In a connection window the group starts the content area, right after the sidebar's strip")
    func separatorPlacesTheGroupInAWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
        defer { fixture.tearDown() }
        let storage = try EphemeralDefaults()
        let owner = fixture.toolbarOwner
        owner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
        owner.objectKindsEnabled = { true }

        owner.reconcileObjectKindsGroup()

        let identifiers = Self.identifiers(of: owner.managedToolbar)
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(identifiers.dropFirst(separator + 1).first == MainWindowToolbar.objectKindsGroup)
        #expect(Self.groupCount(in: owner.managedToolbar) == 1)
    }

    @Test("Without the sidebar tracking separator the group goes in at the leading edge")
    func insertsAtTheLeadingEdgeWithoutTheSeparator() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindsGroup()

        #expect(toolbar.items.first?.itemIdentifier == MainWindowToolbar.objectKindsGroup)
        #expect(Self.groupCount(in: toolbar) == 1)
    }

    /// A change made while no connection window is open is left for the first window that opens,
    /// which restores its arrangement before it reconciles.
    @Test("A toolbar outside a window leaves the change for the next one")
    func noWindowLeavesTheChangeForTheNextOne() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)
        owner.isInWindow = { false }

        owner.reconcileObjectKindsGroup()
        #expect(Self.groupCount(in: toolbar) == 0)
        #expect(!record.isApplied)

        owner.isInWindow = { true }
        owner.reconcileObjectKindsGroup()
        #expect(Self.groupCount(in: toolbar) == 1)
        #expect(record.isApplied)
    }
}

extension GlobalStateSuites {
    /// The setting itself, flipped the way Settings flips it, reaching a connection window that is
    /// already open.
    @MainActor
    struct ObjectKindsSettingTests {
        @Test(
            "The General setting adds the group to an open window and takes it away",
            .appSettings { $0.general.showsObjectToolbar = false }
        )
        func settingReachesAnOpenWindow() throws {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
            defer { fixture.tearDown() }
            let storage = try EphemeralDefaults()
            fixture.toolbarOwner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
            let toolbar = try #require(fixture.window.toolbar)
            let hasGroup = { toolbar.items.contains { $0.itemIdentifier == MainWindowToolbar.objectKindsGroup } }
            #expect(!hasGroup())

            AppSettingsManager.shared.general.showsObjectToolbar = true
            #expect(hasGroup(), "Turning the setting on reaches the open window")
            let identifiers = toolbar.items.map { $0.itemIdentifier }
            let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
            #expect(identifiers.dropFirst(separator + 1).first == MainWindowToolbar.objectKindsGroup)

            AppSettingsManager.shared.general.showsObjectToolbar = false
            #expect(!hasGroup(), "Turning it off takes the group away")
        }
    }
}
