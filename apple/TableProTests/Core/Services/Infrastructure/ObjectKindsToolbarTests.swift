//
//  ObjectKindsToolbarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
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

    // MARK: - Selection

    @Test("The button for the front tab's kind draws in the accent color and the others stay template glyphs")
    func frontKindDrawsInAccent() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .mysql))
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)
        let group = try Self.group(from: owner)

        try Self.press(MainWindowToolbar.objectViews, on: owner)
        group.subitems.forEach { $0.validate() }

        func image(_ identifier: NSToolbarItem.Identifier) -> NSImage? {
            group.subitems.first { $0.itemIdentifier == identifier }?.image
        }
        #expect(owner.selectedObjectKindItem() == MainWindowToolbar.objectViews)
        #expect(image(MainWindowToolbar.objectViews)?.isTemplate == false)
        #expect(image(MainWindowToolbar.objectTables)?.isTemplate == true)
        #expect(image(MainWindowToolbar.objectFunctions)?.isTemplate == true)
    }

    @Test("The selected button is the kind the front tab shows, and none for a tab no button opens")
    func selectionFollowsTheFrontTab() {
        let select = MainWindowToolbar.selectedObjectKindItem
        #expect(select(.tableListing, nil) == MainWindowToolbar.objectTables)
        #expect(select(.tableListing, .table) == MainWindowToolbar.objectTables)
        #expect(select(.tableListing, .view) == MainWindowToolbar.objectViews)
        #expect(select(.tableListing, .function) == MainWindowToolbar.objectFunctions)
        #expect(select(.tableListing, .procedure) == nil)
        #expect(select(.usersRoles, nil) == MainWindowToolbar.objectUsers)
        #expect(select(.query, nil) == nil)
        #expect(select(nil, nil) == nil)
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

    /// Where Settings puts the group: what the toolbar's own facts are read for.
    private static func insertGroup(into owner: MainWindowToolbar) {
        owner.managedToolbar.insertItem(withItemIdentifier: MainWindowToolbar.objectKindsGroup, at: 0)
    }

    /// The context a toolbar pointed at a connection of this engine answers from. No driver is
    /// installed, so the engine's curated capabilities are what the context can see.
    private static func context(
        for type: DatabaseType,
        groupInToolbar: Bool = true,
        settingOn: Bool = true
    ) -> ToolbarContext {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: type))
        let actions = makeActions(for: fixture)
        let owner = owner()
        if groupInToolbar {
            insertGroup(into: owner)
        }
        owner.objectKindsEnabled = { settingOn }
        owner.repoint(to: fixture.coordinator)
        let context = owner.currentContext()
        withExtendedLifetime(actions) {}
        return context
    }

    @Test("With the group in the toolbar, the context reads what the engine supports")
    func contextReadsTheEngineWhileTheGroupIsShown() {
        let postgres = Self.context(for: .postgresql)
        #expect(postgres.supportsBackup)
        #expect(!postgres.canListTables, "With no driver the engine builds no listing")
        #expect(!postgres.supportsUserManagement, "With no driver there is no capability to read")
        #expect(!postgres.offersFunctions, "No routine list is loaded for the browsed schema")

        let mongo = Self.context(for: .mongodb)
        #expect(mongo.canListTables, "MongoDB lists through its own command")
        #expect(!mongo.offersViews, "A table listing says nothing about views")
        #expect(!Self.context(for: .sqlite).offersFunctions)
    }

    /// Nothing but the group reads these, and the listing is a plugin call on every validation pass.
    /// The setting is not enough: a group taken out with Customize Toolbar has no button to validate.
    @Test("Without the group in the toolbar, the context asks the connection nothing for it", arguments: [true, false])
    func contextAsksNothingWithoutTheGroup(settingOn: Bool) {
        for type in [DatabaseType.postgresql, .mongodb] {
            let context = Self.context(for: type, groupInToolbar: false, settingOn: settingOn)
            #expect(!context.canListTables, "\(type.rawValue)")
            #expect(!context.offersViews, "\(type.rawValue)")
            #expect(!context.offersFunctions, "\(type.rawValue)")
            #expect(!context.supportsUserManagement, "\(type.rawValue)")
            #expect(!context.supportsBackup, "\(type.rawValue)")
        }
    }

    /// A validation pass runs on every window update, keystrokes included, and the listing is a
    /// plugin call that builds the whole statement for a yes or no.
    @Test("A pass with nothing changed builds no listing, and a switch or a reconnect builds one again")
    func listingIsAskedOncePerContainerAndSession() {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let plugin = CountingListingDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: plugin)
        )
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let fixture = CoordinatorFixture(connection: connection)
        let owner = Self.owner()
        Self.insertGroup(into: owner)
        owner.repoint(to: fixture.coordinator)

        #expect(owner.currentContext().canListTables)
        let asked = plugin.listings
        #expect(asked > 0)
        _ = owner.currentContext()
        _ = owner.currentContext()
        #expect(plugin.listings == asked, "Nothing moved, so nothing is asked again")

        DatabaseManager.shared.updateSession(connection.id) { $0.browseSchema = "sales" }
        _ = owner.currentContext()
        _ = owner.currentContext()
        #expect(plugin.listings == asked + 1, "A schema switch asks once")

        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "archive" }
        _ = owner.currentContext()
        _ = owner.currentContext()
        #expect(plugin.listings == asked + 2, "A database switch asks once")

        let reconnected = CountingListingDriver()
        DatabaseManager.shared.updateSession(connection.id) {
            $0.driver = PluginDriverAdapter(connection: connection, pluginDriver: reconnected)
        }
        _ = owner.currentContext()
        _ = owner.currentContext()
        #expect(reconnected.listings == 1, "A reconnect's driver is asked once")
        withExtendedLifetime(fixture) {}
    }

    // MARK: - What the browsed container offers

    /// An engine with no table listing that fetches routines and keeps every read on the session's
    /// own driver, as PGlite does: the shape Trino and Snowflake take for these buttons.
    private static func registerListlessEngine() -> DatabaseType {
        let typeId = "ObjectKindsToolbarListless-\(UUID().uuidString)"
        let defaults = PluginMetadataSnapshot.CapabilityFlags.defaults
        var capabilities = PluginMetadataSnapshot.CapabilityFlags(
            supportsSchemaSwitching: true,
            supportsImport: defaults.supportsImport,
            supportsExport: defaults.supportsExport,
            supportsSSH: defaults.supportsSSH,
            supportsSSL: defaults.supportsSSL,
            supportsCascadeDrop: defaults.supportsCascadeDrop,
            supportsForeignKeyDisable: defaults.supportsForeignKeyDisable,
            supportsReadOnlyMode: defaults.supportsReadOnlyMode,
            supportsQueryProgress: defaults.supportsQueryProgress,
            requiresReconnectForDatabaseSwitch: defaults.requiresReconnectForDatabaseSwitch,
            supportsDropDatabase: defaults.supportsDropDatabase
        )
        capabilities.supportsRoutines = true
        capabilities.supportsConnectionPooling = false
        let snapshot = PluginMetadataSnapshot(
            displayName: typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "objectkindslistless", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["objectkindslistless"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId)
        return DatabaseType(rawValue: typeId)
    }

    /// A live session browsing `shop.public`, whose lists the sidebar has already read.
    private static func browsing(
        tables: [TableInfo],
        routines: [RoutineInfo],
        on engine: DatabaseType
    ) async -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: "shop", type: engine)
        let driver = MockDatabaseDriver(connection: connection)
        driver.schemaTablesToReturn = ["public": tables]
        driver.schemaRoutinesToReturn = ["public": routines]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tree = DatabaseTreeMetadataService.shared
        await tree.loadTables(connectionId: connection.id, database: "shop", schema: "public")
        await tree.loadRoutines(connectionId: connection.id, database: "shop", schema: "public")
        return connection
    }

    private static func leave(_ connection: DatabaseConnection) async {
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private static func enabledButtons(browsing connection: DatabaseConnection) -> Set<NSToolbarItem.Identifier> {
        let fixture = CoordinatorFixture(connection: connection)
        fixture.coordinator.toolbarState.connectionState = .connected
        let owner = owner()
        insertGroup(into: owner)
        owner.repoint(to: fixture.coordinator)
        let context = withExtendedLifetime(fixture) { owner.currentContext() }
        return Set(MainWindowToolbar.objectKindItemIdentifiers.filter { identifier in
            ToolbarContextResolver.isEnabled(identifier, context: context)
        })
    }

    /// The sidebar offers Show Objects on a Views or Functions group from its own lists, so the
    /// buttons do too, on an engine that builds no table listing.
    @Test("Views and Functions open from the sidebar's lists on an engine with no table listing")
    func viewsAndFunctionsFollowTheSidebarsLists() async {
        let engine = Self.registerListlessEngine()
        let connection = await Self.browsing(
            tables: [
                TestFixtures.makeTableInfo(name: "orders", schema: "public"),
                TestFixtures.makeTableInfo(name: "open_orders", type: .view, schema: "public"),
            ],
            routines: [RoutineInfo(name: "order_total", kind: .function, schema: "public")],
            on: engine
        )

        let enabled = Self.enabledButtons(browsing: connection)

        #expect(enabled.contains(MainWindowToolbar.objectViews))
        #expect(enabled.contains(MainWindowToolbar.objectFunctions))
        #expect(!enabled.contains(MainWindowToolbar.objectTables), "Tables still need the engine's listing")
        await Self.leave(connection)
        PluginMetadataRegistry.shared.unregister(typeId: engine.rawValue)
    }

    /// The Objects tab offers a kind only where the container holds some, so a button that opened
    /// an empty list of a kind the sidebar never shows stays dim.
    @Test("A container with no views or functions dims Views and Functions")
    func emptyKindsDimTheirButtons() async {
        let engine = Self.registerListlessEngine()
        let connection = await Self.browsing(
            tables: [TestFixtures.makeTableInfo(name: "orders", schema: "public")],
            routines: [RoutineInfo(name: "archive_orders", kind: .procedure, schema: "public")],
            on: engine
        )

        let enabled = Self.enabledButtons(browsing: connection)

        #expect(!enabled.contains(MainWindowToolbar.objectViews))
        #expect(!enabled.contains(MainWindowToolbar.objectFunctions), "A procedure is not a function")
        #expect(enabled.contains(MainWindowToolbar.objectQuery))
        await Self.leave(connection)
        PluginMetadataRegistry.shared.unregister(typeId: engine.rawValue)
    }

    /// The facts are kept between passes, so a list the sidebar reads again has to reach them.
    @Test("A view the container's next read brings lights Views")
    func aReloadedListReachesTheButtons() async throws {
        let engine = Self.registerListlessEngine()
        let connection = await Self.browsing(
            tables: [TestFixtures.makeTableInfo(name: "orders", schema: "public")],
            routines: [],
            on: engine
        )
        let fixture = CoordinatorFixture(connection: connection)
        fixture.coordinator.toolbarState.connectionState = .connected
        let owner = Self.owner()
        Self.insertGroup(into: owner)
        owner.repoint(to: fixture.coordinator)
        #expect(!owner.currentContext().offersViews)

        let driver = try #require(DatabaseManager.shared.driver(for: connection.id) as? MockDatabaseDriver)
        driver.schemaTablesToReturn = ["public": [
            TestFixtures.makeTableInfo(name: "orders", schema: "public"),
            TestFixtures.makeTableInfo(name: "open_orders", type: .view, schema: "public"),
        ]]
        let tree = DatabaseTreeMetadataService.shared
        tree.markListsStale(connectionId: connection.id)
        await tree.loadTables(connectionId: connection.id, database: "shop", schema: "public")

        #expect(owner.currentContext().offersViews)
        withExtendedLifetime(fixture) {}
        await Self.leave(connection)
        PluginMetadataRegistry.shared.unregister(typeId: engine.rawValue)
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

    /// The resolver answering is not enough: AppKit has to ask it for each subitem and write the
    /// answer. This is the pass a window update runs, through the window's own toolbar.
    @Test("A validation pass writes each button's enabled state")
    func aValidationPassWritesEachButton() throws {
        let fixture = try OffscreenConnectionWindow(
            size: CGSize(width: 1_512, height: 861),
            connectedTo: TestFixtures.makeConnection(name: "Objects validation", type: .sqlite)
        )
        defer { fixture.tearDown() }
        let storage = try EphemeralDefaults()
        let owner = fixture.toolbarOwner
        owner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
        owner.objectKindsEnabled = { true }
        owner.reconcileObjectKindsGroup()
        // AppKit places an inserted item at the next layout, and validates only what it has placed.
        fixture.window.layoutIfNeeded()
        let toolbar = try #require(fixture.window.toolbar)
        let group = try #require(
            toolbar.items.first { $0.itemIdentifier == MainWindowToolbar.objectKindsGroup } as? NSToolbarItemGroup
        )
        let drawn = (toolbar.visibleItems ?? []).map { $0.itemIdentifier }
        #expect(drawn.contains(MainWindowToolbar.objectKindsGroup), "The group went to the overflow menu")
        let state = try #require(owner.coordinator?.toolbarState)
        let enabled = { Set(group.subitems.filter { $0.isEnabled }.map { $0.itemIdentifier }) }

        state.connectionState = .disconnected
        toolbar.validateVisibleItems()
        #expect(enabled().isEmpty, "A dropped session dims every button")

        // SQLite's test session has no listing and no views or functions loaded, so the pass writes both answers.
        state.connectionState = .connected
        toolbar.validateVisibleItems()
        let answered = owner.currentContext()
        let expected = Set(MainWindowToolbar.objectKindItemIdentifiers.filter { identifier in
            ToolbarContextResolver.isEnabled(identifier, context: answered)
        })
        #expect(enabled() == expected)
        #expect(enabled().contains(MainWindowToolbar.objectQuery))
        #expect(!enabled().contains(MainWindowToolbar.objectTables))
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
            // This window has no connection, so the group arrives dimmed rather than live until the next update.
            let group = try #require(
                toolbar.items.first { $0.itemIdentifier == MainWindowToolbar.objectKindsGroup } as? NSToolbarItemGroup
            )
            #expect(!group.subitems.isEmpty)
            for subitem in group.subitems {
                #expect(!subitem.isEnabled, "\(subitem.itemIdentifier.rawValue) is live with no connection")
            }

            AppSettingsManager.shared.general.showsObjectToolbar = false
            #expect(!hasGroup(), "Turning it off takes the group away")
        }
    }
}

/// Counts the listing statements asked for, which is the plugin call a validation pass would repeat.
private final class CountingListingDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var listings = 0

    func allTablesMetadataSQL(schema: String?) -> String? {
        listings += 1
        return "LIST \(schema ?? "-")"
    }

    func ping() async throws {}
}
