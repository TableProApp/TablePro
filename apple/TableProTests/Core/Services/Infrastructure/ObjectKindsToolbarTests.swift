//
//  ObjectKindsToolbarTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

/// The optional Objects buttons: six top-level items that reach each kind of object in one click.
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

    /// The item the delegate vends, as Customize Toolbar and a restored arrangement ask for it.
    private static func item(
        _ identifier: NSToolbarItem.Identifier,
        of owner: MainWindowToolbar
    ) throws -> NSToolbarItem {
        try #require(
            owner.toolbar(owner.managedToolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)
        )
    }

    private static func items(of owner: MainWindowToolbar) throws -> [NSToolbarItem] {
        try MainWindowToolbar.objectKindItemIdentifiers.map { try item($0, of: owner) }
    }

    /// What a click does: the button's own action, sent to the button's own target.
    private static func press(_ identifier: NSToolbarItem.Identifier, on owner: MainWindowToolbar) throws {
        let item = try item(identifier, of: owner)
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

    // MARK: - The buttons

    /// An image item with no view is drawn by AppKit, so it dims, answers the display mode with a
    /// label under its icon, shows the toolbar's selection and goes to the overflow menu on its own.
    @Test("Each button is a named, borderless AppKit glyph routed to the toolbar")
    func buttonsAreDrawnByAppKit() throws {
        let owner = Self.owner()

        for item in try Self.items(of: owner) {
            let name = item.itemIdentifier.rawValue
            #expect(!(item is NSToolbarItemGroup), "\(name) must be a top-level item, or no label or selection draws")
            #expect(item.view == nil, "\(name) must not be view-backed")
            #expect(!item.label.isEmpty, "\(name) needs a label")
            #expect(item.image != nil, "\(name) names no symbol that exists")
            #expect(item.target === owner, "\(name) must route through the toolbar")
            #expect(item.action != nil, "\(name) has no action")
            #expect(
                item.visibilityPriority == MainWindowToolbar.visibilityPriority(for: item.itemIdentifier),
                "\(name) leaves the titlebar before the commands"
            )
            #expect(!item.isBordered, "\(name) must match the selectable buttons, which AppKit draws without a bezel")
        }
    }

    @Test("Query advertises its shortcut, and every button its name")
    func queryAdvertisesItsShortcut() throws {
        let owner = Self.owner()
        let query = try Self.item(MainWindowToolbar.objectQuery, of: owner)
        let tables = try Self.item(MainWindowToolbar.objectTables, of: owner)

        #expect(query.toolTip == AppSettingsManager.shared.keyboard.shortcutHint(String(localized: "Query"), for: .newTab))
        #expect(query.toolTip != String(localized: "Query"), "The hint adds the key that runs the command")
        #expect(tables.toolTip == String(localized: "Tables"))
    }

    /// AppKit validates an overflowed button as a menu item, so each entry has to resolve back to
    /// its own button's rule, or a disconnected window's entries stay live and do nothing.
    @Test("Each overflow entry validates as its own button")
    func overflowEntriesValidateAsTheirButtons() throws {
        let owner = Self.owner()
        for item in try Self.items(of: owner) {
            let entry = try #require(item.menuFormRepresentation)
            #expect(owner.itemIdentifier(forMenuFormAction: item.action) == item.itemIdentifier)
            #expect(!owner.validateMenuItem(entry), "\(item.itemIdentifier.rawValue) is live with no session")
        }
    }

    // MARK: - Selection

    /// AppKit draws the toolbar's selected item on a rounded highlight and reports it to VoiceOver as
    /// the toolbar's selected child, so the selected identifier is the whole visual state.
    @Test("The toolbar selects the button for the front tab's kind, and none once a query tab is in front")
    func theFrontKindIsSelected() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        let actions = Self.makeActions(for: fixture)
        let owner = Self.owner()
        owner.repoint(to: fixture.coordinator)

        // Users first: with a tab already open, Users & Roles opens through the window manager, which this fixture lacks.
        try Self.press(MainWindowToolbar.objectUsers, on: owner)
        owner.refreshObjectKindSelection()
        #expect(owner.managedToolbar.selectedItemIdentifier == MainWindowToolbar.objectUsers)

        try Self.press(MainWindowToolbar.objectViews, on: owner)
        owner.refreshObjectKindSelection()
        #expect(owner.managedToolbar.selectedItemIdentifier == MainWindowToolbar.objectViews)

        try Self.press(MainWindowToolbar.objectQuery, on: owner)
        owner.refreshObjectKindSelection()
        #expect(owner.managedToolbar.selectedItemIdentifier == nil, "Query starts something new, so nothing stays selected")
        withExtendedLifetime(actions) {}
    }

    @Test("With the setting off the toolbar selects nothing")
    func settingOffSelectsNothing() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .mysql))
        let owner = Self.owner(objectsOn: false)
        owner.repoint(to: fixture.coordinator)

        fixture.coordinator.showBrowsedObjects(.table)
        owner.refreshObjectKindSelection()

        #expect(owner.selectedObjectKindItem() == MainWindowToolbar.objectTables)
        #expect(owner.managedToolbar.selectedItemIdentifier == nil)
    }

    @Test("Only the four kinds a tab can show are selectable")
    func onlyTheKindsAreSelectable() {
        let owner = Self.owner()
        let selectable = owner.toolbarSelectableItemIdentifiers(owner.managedToolbar)

        #expect(selectable == [
            MainWindowToolbar.objectTables, MainWindowToolbar.objectViews,
            MainWindowToolbar.objectFunctions, MainWindowToolbar.objectUsers,
        ])
        #expect(!selectable.contains(MainWindowToolbar.objectQuery))
        #expect(!selectable.contains(MainWindowToolbar.objectBackup))
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

    // MARK: - Colors

    /// Each kind wears a system hue, so the run reads at a glance; every other control keeps the
    /// system's monochrome template glyph.
    @Test("Only the Objects buttons draw in color")
    func onlyTheObjectButtonsDrawInColor() throws {
        let owner = Self.owner()
        let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
        let vended = owner.toolbarAllowedItemIdentifiers(owner.managedToolbar)
            .filter { !$0.rawValue.hasPrefix("NSToolbar") }
            .compactMap { owner.toolbar(owner.managedToolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true) }
            .flatMap { item -> [NSToolbarItem] in [item] + ((item as? NSToolbarItemGroup)?.subitems ?? []) }

        #expect(objectKinds.isSubset(of: Set(vended.map { $0.itemIdentifier })))
        for item in vended {
            guard let image = item.image else { continue }
            let name = item.itemIdentifier.rawValue
            if objectKinds.contains(item.itemIdentifier) {
                #expect(!image.isTemplate, "\(name) should draw in its hue")
                #expect(MainWindowToolbar.objectKindTint(for: item.itemIdentifier) != nil, "\(name) has no hue")
            } else {
                #expect(image.isTemplate, "\(name) should stay a monochrome template")
                #expect(MainWindowToolbar.objectKindTint(for: item.itemIdentifier) == nil, "\(name) should have no hue")
            }
        }
    }

    @Test("Each kind has a hue of its own")
    func eachKindHasItsOwnHue() {
        let tints = MainWindowToolbar.objectKindItemIdentifiers.compactMap { MainWindowToolbar.objectKindTint(for: $0) }

        #expect(tints.count == MainWindowToolbar.objectKindItemIdentifiers.count)
        #expect(Set(tints).count == tints.count)
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

    /// Where Settings puts the buttons: what the toolbar's own facts are read for.
    private static func insertButtons(into owner: MainWindowToolbar) {
        for (index, identifier) in MainWindowToolbar.objectKindItemIdentifiers.enumerated() {
            owner.managedToolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    /// The context a toolbar pointed at a connection of this engine answers from. No driver is
    /// installed, so the engine's curated capabilities are what the context can see.
    private static func context(
        for type: DatabaseType,
        buttonsInToolbar: Bool = true,
        settingOn: Bool = true
    ) -> ToolbarContext {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: type))
        let actions = makeActions(for: fixture)
        let owner = owner()
        if buttonsInToolbar {
            insertButtons(into: owner)
        }
        owner.objectKindsEnabled = { settingOn }
        owner.repoint(to: fixture.coordinator)
        let context = owner.currentContext()
        withExtendedLifetime(actions) {}
        return context
    }

    @Test("With the buttons in the toolbar, the context reads what the engine supports")
    func contextReadsTheEngineWhileTheButtonsAreShown() {
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

    /// Nothing but the buttons read these, and the listing is a plugin call on every validation pass.
    /// The setting is not enough: buttons taken out with Customize Toolbar have nothing to validate.
    @Test("Without the buttons in the toolbar, the context asks the connection nothing for them", arguments: [true, false])
    func contextAsksNothingWithoutTheButtons(settingOn: Bool) {
        for type in [DatabaseType.postgresql, .mongodb] {
            let context = Self.context(for: type, buttonsInToolbar: false, settingOn: settingOn)
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
        Self.insertButtons(into: owner)
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
        insertButtons(into: owner)
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
        Self.insertButtons(into: owner)
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
    /// never autosaves. Built with the buttons allowed, so `extra` can hold them, then switched to the
    /// setting the case names. AppKit builds the sidebar tracking separator only over a split view
    /// in a window, so this arrangement has none; `separatorPlacesTheButtonsInAWindow` covers it.
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

    // The six buttons as a change of the setting inserts them, with the space that parts the kinds from the actions.
    static let insertedRun: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.objectTables, MainWindowToolbar.objectViews, MainWindowToolbar.objectFunctions,
        MainWindowToolbar.objectUsers, .space, MainWindowToolbar.objectQuery, MainWindowToolbar.objectBackup,
    ]

    private static func identifiers(of toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbar.items.map { $0.itemIdentifier }
    }

    private static func buttons(in toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
        return identifiers(of: toolbar).filter { objectKinds.contains($0) }
    }

    @Test("Turning the setting on puts the six buttons in once, in order")
    func turningOnInsertsTheButtonsOnce() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        #expect(!record.isApplied)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindItems()

        #expect(Self.buttons(in: toolbar) == MainWindowToolbar.objectKindItemIdentifiers)
        #expect(ToolbarObjectKindsRecord(defaults: storage.defaults).isApplied)
        let placed = Self.identifiers(of: toolbar)
        let query = try #require(placed.firstIndex(of: MainWindowToolbar.objectQuery))
        #expect(placed[query - 1] == .space, "A space parts the four kinds from Query and Backup")
        #expect(placed[query - 2] == MainWindowToolbar.objectUsers)

        let (laterOwner, laterToolbar) = Self.restoredToolbar(settingOn: true, record: record)
        laterOwner.reconcileObjectKindItems()
        #expect(Self.buttons(in: laterToolbar).isEmpty, "The change was already written into the arrangement")
    }

    /// An arrangement saved with the former group recorded it under the former key, so the buttons
    /// still arrive once in place of the group the delegate no longer vends.
    @Test("The record is not the former group's, so an arrangement that held the group gets the buttons")
    func theRecordIsTheButtonsOwn() throws {
        let storage = try EphemeralDefaults()
        storage.defaults.set(true, forKey: "com.TablePro.main.toolbar.v4.objectKinds")
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        #expect(!record.isApplied)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindItems()

        #expect(Self.buttons(in: toolbar) == MainWindowToolbar.objectKindItemIdentifiers)
    }

    @Test("Turning the setting off takes every button out")
    func turningOffRemovesTheButtons() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: MainWindowToolbar.objectKindItemIdentifiers,
            settingOn: false,
            record: record
        )
        #expect(Self.buttons(in: toolbar).count == 6)

        owner.reconcileObjectKindItems()

        #expect(Self.buttons(in: toolbar).isEmpty)
        #expect(!record.isApplied)
    }

    @Test("Turning the setting off takes out the space the buttons came with, and only that one")
    func turningOffRemovesOnlyTheButtonsSpace() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: [.space, MainWindowToolbar.objectTables, MainWindowToolbar.objectViews,
                        MainWindowToolbar.objectFunctions, MainWindowToolbar.objectUsers, .space,
                        MainWindowToolbar.objectQuery, MainWindowToolbar.objectBackup],
            settingOn: false,
            record: record
        )

        owner.reconcileObjectKindItems()

        #expect(Self.buttons(in: toolbar).isEmpty)
        #expect(Self.identifiers(of: toolbar).filter { $0 == .space }.count == 1, "The user's own space stays")
    }

    @Test("Query and Backup give way first, then the four kinds, before the connection and the commands")
    func objectButtonsGiveWayFirst() {
        func priority(_ identifier: NSToolbarItem.Identifier) -> Int {
            MainWindowToolbar.visibilityPriority(for: identifier).rawValue
        }
        #expect(priority(MainWindowToolbar.objectQuery) == NSToolbarItem.VisibilityPriority.low.rawValue)
        #expect(priority(MainWindowToolbar.objectBackup) == NSToolbarItem.VisibilityPriority.low.rawValue)
        for kind in MainWindowToolbar.selectableObjectKindItemIdentifiers {
            #expect(priority(kind) > priority(MainWindowToolbar.objectQuery))
            #expect(priority(kind) < NSToolbarItem.VisibilityPriority.standard.rawValue, "The connection stays longer")
        }
        #expect(priority(MainWindowToolbar.refresh) == NSToolbarItem.VisibilityPriority.high.rawValue)
    }

    @Test("Buttons the user took out with Customize Toolbar stay out")
    func removedButtonsStayRemoved() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: [MainWindowToolbar.objectTables, MainWindowToolbar.objectQuery],
            settingOn: true,
            record: record
        )

        owner.reconcileObjectKindItems()

        #expect(Self.buttons(in: toolbar) == [MainWindowToolbar.objectTables, MainWindowToolbar.objectQuery])
        #expect(record.isApplied)
    }

    @Test("With the setting off an arrangement is left exactly as it was")
    func settingOffLeavesTheArrangementAlone() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: false, record: record)
        let before = Self.identifiers(of: toolbar)

        owner.reconcileObjectKindItems()

        #expect(Self.identifiers(of: toolbar) == before)
        #expect(!record.isApplied)
        #expect(storage.defaults.object(forKey: ToolbarObjectKindsRecord.key) == nil, "Nothing is written while off")
    }

    /// AppKit throws when a second item with an identifier already in the toolbar is added.
    @Test("A button already in the arrangement is not added a second time", arguments: [
        [MainWindowToolbar.objectViews.rawValue],
        MainWindowToolbar.objectKindItemIdentifiers.map(\.rawValue),
    ])
    func presentButtonsAreNotInsertedAgain(present: [String]) throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(
            including: present.map { NSToolbarItem.Identifier($0) },
            settingOn: true,
            record: record
        )

        owner.reconcileObjectKindItems()

        #expect(Set(Self.buttons(in: toolbar)) == Set(MainWindowToolbar.objectKindItemIdentifiers))
        #expect(Self.buttons(in: toolbar).count == MainWindowToolbar.objectKindItemIdentifiers.count)
        #expect(record.isApplied)
    }

    /// The connection window's own toolbar, whose split view gives it the sidebar's divider.
    @Test("In a connection window the buttons start the content area, right after the sidebar's strip")
    func separatorPlacesTheButtonsInAWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
        defer { fixture.tearDown() }
        let storage = try EphemeralDefaults()
        let owner = fixture.toolbarOwner
        owner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
        owner.objectKindsEnabled = { true }

        owner.reconcileObjectKindItems()

        let identifiers = Self.identifiers(of: owner.managedToolbar)
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(Array(identifiers.dropFirst(separator + 1).prefix(7)) == Self.insertedRun)
        #expect(Self.buttons(in: owner.managedToolbar) == MainWindowToolbar.objectKindItemIdentifiers)
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
        owner.reconcileObjectKindItems()
        // AppKit places an inserted item at the next layout, and validates only what it has placed.
        fixture.window.layoutIfNeeded()
        let toolbar = try #require(fixture.window.toolbar)
        let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
        let buttons = toolbar.items.filter { objectKinds.contains($0.itemIdentifier) }
        #expect(buttons.count == objectKinds.count)
        let drawn = Set((toolbar.visibleItems ?? []).map { $0.itemIdentifier })
        #expect(objectKinds.isSubset(of: drawn), "A button went to the overflow menu")
        let state = try #require(owner.coordinator?.toolbarState)
        let enabled = { Set(buttons.filter { $0.isEnabled }.map { $0.itemIdentifier }) }

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

    @Test("Without the sidebar tracking separator the buttons go in at the leading edge")
    func insertsAtTheLeadingEdgeWithoutTheSeparator() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)

        owner.reconcileObjectKindItems()

        #expect(Array(Self.identifiers(of: toolbar).prefix(7)) == Self.insertedRun)
    }

    /// The pass a window update runs is what keeps the selection on the front tab's kind.
    @Test("A validation pass selects the front tab's kind")
    func aValidationPassSelectsTheFrontKind() throws {
        let fixture = try OffscreenConnectionWindow(
            size: CGSize(width: 1_512, height: 861),
            connectedTo: TestFixtures.makeConnection(name: "Objects selection", database: "shop", type: .mysql)
        )
        defer { fixture.tearDown() }
        let storage = try EphemeralDefaults()
        let owner = fixture.toolbarOwner
        owner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
        owner.objectKindsEnabled = { true }
        owner.reconcileObjectKindItems()
        fixture.window.layoutIfNeeded()
        let toolbar = try #require(fixture.window.toolbar)
        let coordinator = try #require(owner.coordinator)

        coordinator.showBrowsedObjects(.function)
        toolbar.validateVisibleItems()
        #expect(toolbar.selectedItemIdentifier == MainWindowToolbar.objectFunctions)

        coordinator.showBrowsedObjects(.table)
        toolbar.validateVisibleItems()
        #expect(toolbar.selectedItemIdentifier == MainWindowToolbar.objectTables)
    }

    /// Removing the buttons from a toolbar whose family held one toolbar left without its owner raised
    /// `_itemAtIndex` in AppKit's copy of the removal and took the unit host down.
    @Test("The buttons wait while another toolbar of the identifier is out of step")
    func outOfStepFamilyDefersTheButtons() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        record.record(true)
        let (owner, toolbar) = Self.restoredToolbar(
            including: MainWindowToolbar.objectKindItemIdentifiers,
            settingOn: false,
            record: record
        )
        let before = Self.identifiers(of: toolbar)
        owner.familyArrangements = { _ in [before, [.toggleSidebar]] }

        owner.reconcileObjectKindItems()
        #expect(Self.identifiers(of: toolbar) == before)
        #expect(record.isApplied, "Still recorded as in, so the next reconcile takes them out")

        owner.familyArrangements = { _ in [] }
        owner.reconcileObjectKindItems()
        #expect(Self.buttons(in: toolbar).isEmpty)
        #expect(!record.isApplied)
    }

    /// A change made while no connection window is open is left for the first window that opens,
    /// which restores its arrangement before it reconciles.
    @Test("A toolbar outside a window leaves the change for the next one")
    func noWindowLeavesTheChangeForTheNextOne() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarObjectKindsRecord(defaults: storage.defaults)
        let (owner, toolbar) = Self.restoredToolbar(settingOn: true, record: record)
        owner.isInWindow = { false }

        owner.reconcileObjectKindItems()
        #expect(Self.buttons(in: toolbar).isEmpty)
        #expect(!record.isApplied)

        owner.isInWindow = { true }
        owner.reconcileObjectKindItems()
        #expect(Self.buttons(in: toolbar) == MainWindowToolbar.objectKindItemIdentifiers)
        #expect(record.isApplied)
    }
}

extension GlobalStateSuites {
    /// The setting itself, flipped the way Settings flips it, reaching a connection window that is
    /// already open.
    @MainActor
    struct ObjectKindsSettingTests {
        @Test(
            "The General setting adds the buttons to an open window and takes them away",
            .appSettings { $0.general.showsObjectToolbar = false }
        )
        func settingReachesAnOpenWindow() throws {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
            defer { fixture.tearDown() }
            let storage = try EphemeralDefaults()
            fixture.toolbarOwner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
            let toolbar = try #require(fixture.window.toolbar)
            let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
            let buttons = { toolbar.items.filter { objectKinds.contains($0.itemIdentifier) } }
            #expect(buttons().isEmpty)

            AppSettingsManager.shared.general.showsObjectToolbar = true
            #expect(buttons().count == objectKinds.count, "Turning the setting on reaches the open window")
            let identifiers = toolbar.items.map { $0.itemIdentifier }
            let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
            #expect(Array(identifiers.dropFirst(separator + 1).prefix(7)) == ObjectKindsToolbarTests.insertedRun)
            // This window has no connection, so the buttons arrive dimmed rather than live until the next update.
            for button in buttons() {
                #expect(!button.isEnabled, "\(button.itemIdentifier.rawValue) is live with no connection")
            }

            AppSettingsManager.shared.general.showsObjectToolbar = false
            #expect(buttons().isEmpty, "Turning it off takes the buttons away")
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
