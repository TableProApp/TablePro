//
//  QuickSwitcherViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QuickSwitcherViewModelTests {
    private func makeDefaults() -> UserDefaults {
        guard let suite = UserDefaults(suiteName: "QuickSwitcherTests.\(UUID().uuidString)") else {
            return .standard
        }
        return suite
    }

    private func makeViewModel(
        items: [QuickSwitcherItem],
        connectionId: UUID = UUID(),
        defaults: UserDefaults? = nil,
        services: AppServices? = nil
    ) -> QuickSwitcherViewModel {
        let suite = defaults ?? makeDefaults()
        let vm = QuickSwitcherViewModel(connectionId: connectionId, services: services ?? .live, defaults: suite)
        vm.allItems = items
        return vm
    }

    private func makeServices(
        databaseManager: DatabaseManager,
        schemaService: SchemaService,
        schemaRefreshService: SchemaRefreshService,
        sqlFavoriteManager: SQLFavoriteManager? = nil,
        queryHistoryManager: QueryHistoryManager? = nil
    ) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: live.connectionStorage,
            databaseManager: databaseManager,
            pluginManager: live.pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: SchemaProviderRegistry(),
            sqlFavoriteManager: sqlFavoriteManager ?? live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            groupStorage: live.groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager ?? live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            themeEngine: live.themeEngine,
            welcomeRouter: live.welcomeRouter
        )
    }

    private func sampleItems() -> [QuickSwitcherItem] {
        [
            QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "t2", name: "orders", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "v1", name: "active_users", kind: .view, subtitle: "View"),
            QuickSwitcherItem(id: "d1", name: "production", kind: .database, subtitle: "Database"),
            QuickSwitcherItem(id: "h1", name: "SELECT * FROM users;", kind: .queryHistory, subtitle: "mydb")
        ]
    }

    @Test("Empty search with the All scope shows only recents")
    func emptySearchShowsOnlyRecents() async {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        await vm.flushPendingFilter()
        #expect(vm.groups.isEmpty)

        vm.recordSelection(items[0])
        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        await vm2.flushPendingFilter()
        #expect(vm2.groups.count == 1)
        #expect(vm2.groups.first?.header == String(localized: "Recent"))
    }

    @Test("A browse scope lists every kind it covers")
    func browseScopeListsKinds() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        let kinds = vm.groups.compactMap { $0.header }
        #expect(kinds.contains(String(localized: "Tables")))
        #expect(kinds.contains(String(localized: "Views")))
        #expect(!kinds.contains(String(localized: "Databases")))
    }

    @Test("Connections scope lists objects from every connection")
    func connectionsScopeUsesCrossConnectionItems() async {
        let localConnectionId = UUID()
        let remoteConnectionId = UUID()
        let local = QuickSwitcherItem(id: "local", name: "users", kind: .table, subtitle: "")
        let remoteTarget = QuickSwitcherTarget(
            connectionId: remoteConnectionId,
            connectionName: "Analytics",
            databaseName: "warehouse",
            schemaName: "public"
        )
        let remote = QuickSwitcherItem(
            id: "remote",
            name: "events",
            kind: .table,
            subtitle: "Analytics / warehouse / public",
            target: remoteTarget
        )
        let vm = makeViewModel(items: [local], connectionId: localConnectionId)
        vm.crossConnectionItems = [remote]
        vm.scope = .connections
        await vm.flushPendingFilter()

        #expect(vm.flatItems.map(\.id) == ["remote"])
        #expect(vm.groups.first?.header == "Analytics")
    }

    @Test("Queries scope loads saved and recent queries from connected sessions")
    func queriesScopeLoadsConnectedSessions() async throws {
        let localConnection = TestFixtures.makeConnection(name: "Primary", database: "app")
        let remoteConnection = TestFixtures.makeConnection(name: "Analytics", database: "warehouse")
        let inactiveConnection = TestFixtures.makeConnection(name: "Offline", database: "archive")
        let databaseManager = DatabaseManager()
        let schemaService = SchemaService()
        let schemaRefreshService = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(),
            metadataDriverProvider: databaseManager,
            databaseManager: databaseManager
        )
        let favoriteStorage = SQLFavoriteStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-switcher-favorites-\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        let historyStorage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-switcher-history-\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        let favoriteManager = SQLFavoriteManager(storage: favoriteStorage)
        let historyManager = QueryHistoryManager(storage: historyStorage)
        let services = makeServices(
            databaseManager: databaseManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            sqlFavoriteManager: favoriteManager,
            queryHistoryManager: historyManager
        )

        for connection in [localConnection, remoteConnection] {
            var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
            session.status = .connected
            session.browseDatabase = connection.database
            databaseManager.injectSession(session, for: connection.id)
        }
        defer {
            databaseManager.removeSession(for: localConnection.id)
            databaseManager.removeSession(for: remoteConnection.id)
        }

        let globalFavorite = SQLFavorite(name: "Global health", query: "SELECT 1")
        let remoteFavorite = SQLFavorite(
            name: "Daily revenue",
            query: "SELECT SUM(total) FROM orders",
            keyword: "revenue",
            connectionId: remoteConnection.id
        )
        let inactiveFavorite = SQLFavorite(
            name: "Archived users",
            query: "SELECT * FROM users",
            connectionId: inactiveConnection.id
        )
        #expect(await favoriteStorage.addFavorite(globalFavorite))
        #expect(await favoriteStorage.addFavorite(remoteFavorite))
        #expect(await favoriteStorage.addFavorite(inactiveFavorite))

        let remoteHistory = QueryHistoryEntry(
            query: "SELECT * FROM events",
            connectionId: remoteConnection.id,
            databaseName: "reporting",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 0.025,
            rowCount: 12,
            wasSuccessful: true
        )
        let inactiveHistory = QueryHistoryEntry(
            query: "DELETE FROM audit_log",
            connectionId: inactiveConnection.id,
            databaseName: "archive",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 1,
            rowCount: 1,
            wasSuccessful: true
        )
        #expect(await historyStorage.record(remoteHistory))
        #expect(await historyStorage.record(inactiveHistory))

        let vm = makeViewModel(
            items: [QuickSwitcherItem(id: "stale", name: "stale", kind: .queryHistory, subtitle: "")],
            connectionId: localConnection.id,
            services: services
        )
        vm.scope = .queries
        await vm.loadCrossConnectionQueryItems()
        await vm.flushPendingFilter()

        #expect(Set(vm.flatItems.map(\.id)) == Set([
            "favorite_\(globalFavorite.id.uuidString)",
            "favorite_\(remoteFavorite.id.uuidString)",
            "history_\(remoteHistory.id.uuidString)"
        ]))
        #expect(vm.flatItems.contains { $0.id == "stale" } == false)
        let globalItem = vm.flatItems.first { $0.id.contains(globalFavorite.id.uuidString) }
        #expect(globalItem?.target?.connectionId == localConnection.id)
        let historyItem = try #require(vm.flatItems.first { $0.id.contains(remoteHistory.id.uuidString) })
        #expect(historyItem.target?.connectionId == remoteConnection.id)
        #expect(historyItem.target?.databaseName == "reporting")
        #expect(historyItem.subtitle.contains("Analytics / reporting"))
        #expect(historyItem.subtitle.contains("25 ms"))

        vm.searchText = "analytics"
        await vm.flushPendingFilter()
        #expect(Set(vm.flatItems.map(\.id)) == Set([
            "favorite_\(remoteFavorite.id.uuidString)",
            "history_\(remoteHistory.id.uuidString)"
        ]))
    }

    @Test("Invalidating cross-connection queries reloads storage changes")
    func invalidatingCrossConnectionQueriesReloadsChanges() async {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "app")
        let databaseManager = DatabaseManager()
        let schemaService = SchemaService()
        let schemaRefreshService = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(),
            metadataDriverProvider: databaseManager,
            databaseManager: databaseManager
        )
        let favoriteStorage = SQLFavoriteStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-switcher-refresh-\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        let services = makeServices(
            databaseManager: databaseManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            sqlFavoriteManager: SQLFavoriteManager(storage: favoriteStorage)
        )
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        databaseManager.injectSession(session, for: connection.id)
        defer { databaseManager.removeSession(for: connection.id) }

        let vm = makeViewModel(items: [], connectionId: connection.id, services: services)
        vm.scope = .queries
        await vm.loadCrossConnectionQueryItems()
        #expect(vm.crossConnectionQueryItems.isEmpty)

        let favorite = SQLFavorite(name: "Late arrival", query: "SELECT 2", connectionId: connection.id)
        #expect(await favoriteStorage.addFavorite(favorite))
        vm.invalidateCrossConnectionQueryItems()
        await vm.loadCrossConnectionQueryItems()

        #expect(vm.crossConnectionQueryItems.map(\.id) == ["favorite_\(favorite.id.uuidString)"])
    }

    @Test("Queries scope caps an oversized local catalog")
    func queriesScopeCapsLargeCatalog() async {
        let vm = makeViewModel(items: [])
        vm.crossConnectionQueryItems = (0..<300).map { index in
            QuickSwitcherItem(
                id: "favorite_\(index)",
                name: "Query \(index)",
                kind: .savedQuery,
                subtitle: "Primary / app"
            )
        }
        vm.scope = .queries
        await vm.flushPendingFilter()

        #expect(vm.flatItems.count == 200)
    }

    @Test("Connections scope replaces tables from a previous browse scope")
    func connectionsScopeReplacesStaleScopeTables() async throws {
        let connection = TestFixtures.makeConnection(database: "primary", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        let databaseManager = DatabaseManager()
        let schemaService = SchemaService()
        let schemaRefreshService = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(),
            metadataDriverProvider: databaseManager,
            databaseManager: databaseManager
        )
        let services = makeServices(
            databaseManager: databaseManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService
        )
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "primary"
        databaseManager.injectSession(session, for: connection.id)
        defer { databaseManager.removeSession(for: connection.id) }

        let firstScope = try #require(databaseManager.browseScope(for: connection.id))
        driver.tablesToReturn = [TableInfo(name: "legacy_orders", type: .table, rowCount: nil)]
        await schemaService.load(
            connectionId: connection.id,
            driver: driver,
            connection: connection,
            scope: firstScope
        )

        session.browseDatabase = "analytics"
        databaseManager.injectSession(session, for: connection.id)
        driver.tablesToReturn = [TableInfo(name: "events", type: .table, rowCount: nil)]

        let vm = makeViewModel(items: [], connectionId: connection.id, services: services)
        vm.scope = .connections
        await vm.loadCrossConnectionItems()
        await vm.flushPendingFilter()

        #expect(vm.flatItems.map(\.name) == ["events"])
        #expect(vm.flatItems.first?.target?.databaseName == "analytics")
        #expect(!vm.flatItems.contains { $0.name == "legacy_orders" })
    }

    @Test("A connection that cannot load its catalog is not refreshed again for the same state")
    func failedConnectionSettlesInsteadOfReloading() async throws {
        let connection = TestFixtures.makeConnection(database: "primary", type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.fetchTablesError = DatabaseError.connectionFailed("permission denied")
        let databaseManager = DatabaseManager()
        let schemaService = SchemaService()
        let schemaRefreshService = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(),
            metadataDriverProvider: databaseManager,
            databaseManager: databaseManager
        )
        let services = makeServices(
            databaseManager: databaseManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService
        )
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "primary"
        databaseManager.injectSession(session, for: connection.id)
        defer { databaseManager.removeSession(for: connection.id) }

        let vm = makeViewModel(items: [], connectionId: connection.id, services: services)
        vm.scope = .connections

        await vm.loadCrossConnectionItems()
        let callsAfterFirstLoad = driver.fetchTablesCallCount
        #expect(callsAfterFirstLoad > 0, "The first load must try the connection")

        await vm.loadCrossConnectionItems()

        #expect(
            driver.fetchTablesCallCount == callsAfterFirstLoad,
            "A connection that failed must not be refreshed again until something about it changes"
        )
        #expect(vm.flatItems.isEmpty)
    }

    @Test("A commit straight after typing uses the query that was typed")
    func pendingFilterCommitsBeforeSelectionIsRead() async {
        let vm = makeViewModel(items: sampleItems())
        await vm.flushPendingFilter()

        vm.searchText = "orders"
        await vm.flushPendingFilter()

        #expect(
            vm.selectedItem()?.name == "orders",
            "Return inside the refilter debounce must still commit the typed query"
        )
    }

    @Test("Connections scope matches a connection name")
    func connectionsScopeMatchesConnectionName() async throws {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Analytics",
            databaseName: "warehouse",
            schemaName: nil
        )
        let remote = QuickSwitcherItem(
            id: "remote",
            name: "events",
            kind: .table,
            subtitle: "Analytics / warehouse",
            target: target
        )
        let vm = makeViewModel(items: [])
        vm.crossConnectionItems = [remote]
        vm.scope = .connections
        vm.searchText = "analytics"
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.flatItems.first?.id == "remote")
        #expect(vm.flatItems.first?.target == target)
    }

    @Test("Changing the query selects the best match")
    func changingQuerySelectsBestMatch() async throws {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Chinook",
            databaseName: "sample.sqlite",
            schemaName: nil
        )
        let items = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [
                TableInfo(name: "Album", type: .table, rowCount: nil),
                TableInfo(name: "Track", type: .table, rowCount: nil)
            ],
            target: target
        )
        let vm = makeViewModel(items: [])
        vm.crossConnectionItems = items
        vm.scope = .connections
        vm.selectedItemId = items[0].id

        vm.searchText = "track"
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.flatItems.first?.name == "Track")
        #expect(vm.selectedItem()?.name == "Track")
    }

    /// The previous selection surviving the refilter is not evidence that it is still wanted. Here
    /// it survives on its own name, and in the Connections scope it survives on the connection path
    /// every subtitle carries, which is what shipped: the list ranked Invoice first while the
    /// highlight stayed on the row typed before it, and Return opened that one.
    @Test("A new query moves the selection off a row that still matches")
    func newQueryMovesSelectionOffAStillMatchingRow() async throws {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Chinook",
            databaseName: "sample.sqlite",
            schemaName: nil
        )
        let items = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [
                TableInfo(name: "Invoice", type: .table, rowCount: nil),
                TableInfo(name: "InvoiceLine", type: .table, rowCount: nil)
            ],
            target: target
        )
        let vm = makeViewModel(items: [])
        vm.crossConnectionItems = items
        vm.scope = .connections
        let stale = try #require(items.first { $0.name == "InvoiceLine" })
        vm.selectedItemId = stale.id

        vm.searchText = "invoice"
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.flatItems.contains { $0.id == stale.id })
        #expect(vm.flatItems.first?.name == "Invoice")
        #expect(vm.selectedItem()?.name == "Invoice")
    }

    /// The counterpart guard. A catalog that reloads underneath an open panel refilters with the
    /// same query, and taking the user's arrow keys back to the top of the list on every reload
    /// would make the panel unusable while connections are still loading.
    @Test("A refilter with the same query keeps the selection")
    func refilterWithSameQueryKeepsSelection() async throws {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Chinook",
            databaseName: "sample.sqlite",
            schemaName: nil
        )
        let tables = [
            TableInfo(name: "Invoice", type: .table, rowCount: nil),
            TableInfo(name: "InvoiceLine", type: .table, rowCount: nil)
        ]
        let vm = makeViewModel(items: [])
        vm.crossConnectionItems = QuickSwitcherViewModel.makeCrossConnectionItems(tables: tables, target: target)
        vm.scope = .connections
        vm.searchText = "invoice"
        try await Task.sleep(nanoseconds: 200_000_000)

        let chosen = try #require(vm.flatItems.first { $0.name == "InvoiceLine" })
        vm.selectedItemId = chosen.id
        vm.crossConnectionItems = QuickSwitcherViewModel.makeCrossConnectionItems(tables: tables, target: target)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.selectedItem()?.name == "InvoiceLine")
    }

    @Test("Cross-connection catalog keeps object location")
    func crossConnectionCatalogKeepsLocation() {
        let connectionId = UUID()
        let target = QuickSwitcherTarget(
            connectionId: connectionId,
            connectionName: "Primary",
            databaseName: "app",
            schemaName: "fallback"
        )
        let tables = [
            TableInfo(name: "users", type: .table, rowCount: nil, schema: "public"),
            TableInfo(name: "active_users", type: .view, rowCount: nil)
        ]

        let items = QuickSwitcherViewModel.makeCrossConnectionItems(tables: tables, target: target)

        #expect(items.count == 2)
        #expect(items[0].id.contains(connectionId.uuidString))
        #expect(items[0].target?.schemaName == "public")
        #expect(items[1].target?.schemaName == "fallback")
        #expect(items[1].kind == .view)
        #expect(items.allSatisfy { $0.subtitle.contains("Primary / app") })
    }

    @Test("File database paths are abbreviated in search results")
    func fileDatabasePathsAreAbbreviated() {
        let databasePath = NSHomeDirectory() + "/Databases/private.sqlite"
        let displayName = QuickSwitcherViewModel.databaseDisplayName(databasePath, pathFieldRole: .filePath)
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Local",
            databaseName: databasePath,
            schemaName: nil,
            databaseDisplayName: displayName
        )

        let item = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [TableInfo(name: "users", type: .table, rowCount: nil)],
            target: target
        )[0]

        #expect(displayName == "~/Databases/private.sqlite")
        #expect(!item.subtitle.contains(NSHomeDirectory()))
        #expect(item.target?.databaseName == databasePath)
    }

    @Test("Identical object names in different schemas keep unique identities")
    func duplicateNamesAcrossSchemasStayUnique() {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Primary",
            databaseName: "app",
            schemaName: nil
        )
        let tables = [
            TableInfo(name: "events", type: .table, rowCount: nil, schema: "public"),
            TableInfo(name: "events", type: .table, rowCount: nil, schema: "audit")
        ]

        let items = QuickSwitcherViewModel.makeCrossConnectionItems(tables: tables, target: target)

        #expect(Set(items.map(\.id)).count == 2)
        #expect(Set(items.compactMap(\.target?.schemaName)) == Set(["public", "audit"]))
    }

    @Test("Connections scope caps a hostile catalog")
    func connectionsScopeCapsLargeCatalog() async {
        let target = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Primary",
            databaseName: "app",
            schemaName: nil
        )
        let tables = (0..<300).map { index in
            TableInfo(name: "table_\(index)", type: .table, rowCount: nil)
        }
        let vm = makeViewModel(items: [])
        vm.crossConnectionItems = QuickSwitcherViewModel.makeCrossConnectionItems(tables: tables, target: target)
        vm.scope = .connections
        await vm.flushPendingFilter()

        #expect(vm.flatItems.count == 200)
    }

    @Test("Query-like input stays plain text")
    func queryLikeInputStaysPlainText() async throws {
        let vm = makeViewModel(items: [
            QuickSwitcherItem(id: "users", name: "users", kind: .table, subtitle: "Primary / app")
        ])

        vm.searchText = "users'; DROP TABLE audit; --"
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.flatItems.isEmpty)
        #expect(vm.allItems.map(\.name) == ["users"])
    }

    @Test("Structure action stays in the current connection")
    func structureActionStaysInCurrentConnection() {
        let connectionId = UUID()
        let vm = makeViewModel(items: [], connectionId: connectionId)
        let currentTarget = QuickSwitcherTarget(
            connectionId: connectionId,
            connectionName: "Primary",
            databaseName: nil,
            schemaName: nil
        )
        let remoteTarget = QuickSwitcherTarget(
            connectionId: UUID(),
            connectionName: "Analytics",
            databaseName: nil,
            schemaName: nil
        )

        #expect(vm.canOpenStructure(QuickSwitcherItem(
            id: "current",
            name: "users",
            kind: .table,
            subtitle: "",
            target: currentTarget
        )))
        #expect(!vm.canOpenStructure(QuickSwitcherItem(
            id: "remote",
            name: "events",
            kind: .table,
            subtitle: "",
            target: remoteTarget
        )))
    }

    @Test("Filtered search returns one headerless group of best matches")
    func filteredGroupHasNoHeader() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.header == nil)
        #expect(vm.flatItems.allSatisfy { $0.name.localizedCaseInsensitiveContains("u") })
    }

    @Test("Saved query is found by its keyword")
    func savedQueryFoundByKeyword() async throws {
        var items = sampleItems()
        items.append(QuickSwitcherItem(
            id: "favorite_1",
            name: "Daily Report",
            kind: .savedQuery,
            subtitle: "rpt",
            payload: "SELECT * FROM reports"
        ))
        let vm = makeViewModel(items: items)
        vm.searchText = "rpt"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains { $0.id == "favorite_1" }, "Typing the keyword must surface the saved query")
    }

    @Test("Browse scope caps at maxResults")
    func filterCaps() async {
        var items: [QuickSwitcherItem] = []
        for index in 0..<300 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.scope = .tables
        await vm.flushPendingFilter()
        #expect(vm.flatItems.count == 200)
    }

    @Test("moveSelection by 1 advances to next item")
    func moveDownAdvances() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        let first = vm.flatItems.first?.id
        #expect(vm.selectedItemId == first)
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == vm.flatItems[1].id)
    }

    @Test("moveSelection clamps at the bounds")
    func moveSelectionClamps() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        vm.selectedItemId = vm.flatItems.first?.id
        vm.moveSelection(by: -1)
        #expect(vm.selectedItemId == vm.flatItems.first?.id)
        vm.selectedItemId = vm.flatItems.last?.id
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == vm.flatItems.last?.id)
    }

    @Test("moveSelection on empty list yields nil")
    func moveSelectionOnEmpty() {
        let vm = makeViewModel(items: [])
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == nil)
    }

    @Test("selectedItem returns the current selection")
    func selectedItemReturnsCurrent() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        let target = vm.flatItems[2]
        vm.selectedItemId = target.id
        #expect(vm.selectedItem()?.id == target.id)
    }

    @Test("selectedItem is nil when no selection")
    func selectedItemNilWhenNone() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        vm.selectedItemId = nil
        #expect(vm.selectedItem() == nil)
    }

    @Test("recordSelection inserts MRU and Recent group appears next time")
    func recordSelectionAddsRecent() async {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        let chosen = items[1]
        vm.recordSelection(chosen)

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        await vm2.flushPendingFilter()
        let recentGroup = vm2.groups.first { $0.header == String(localized: "Recent") }
        #expect(recentGroup?.items.first?.id == chosen.id)
    }

    @Test("Recent group caps at 10 entries, newest first")
    func recentGroupCapsAtLimit() async {
        let suite = makeDefaults()
        let connectionId = UUID()
        var items: [QuickSwitcherItem] = []
        for index in 0..<15 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        for (index, item) in items.enumerated() {
            vm.recordSelection(item, at: Date(timeIntervalSinceNow: TimeInterval(index)))
        }

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        await vm2.flushPendingFilter()
        let recentGroup = vm2.groups.first { $0.header == String(localized: "Recent") }
        #expect(recentGroup?.items.count == 10)
        #expect(recentGroup?.items.first?.id == items.last?.id)
    }

    @Test("Filtered results carry matched character indices")
    func filteredResultsCarryMatchedIndices() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "usr"
        try await Task.sleep(nanoseconds: 200_000_000)
        let users = vm.flatItems.first { $0.id == "t1" }
        #expect(users?.matchedIndices == [0, 1, 3])
    }

    @Test("Frecency boosts a previously opened item over an equal match")
    func frecencyBoostsPreviouslyOpenedItem() async throws {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = [
            QuickSwitcherItem(id: "ta", name: "users_a", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "tb", name: "users_b", kind: .table, subtitle: "")
        ]
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.id == "ta")

        vm.recordSelection(items[1])
        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        vm2.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm2.flatItems.first?.id == "tb")
    }

    @Test("Saved queries get their own section in the queries browse scope")
    func savedQueriesGetOwnSection() async {
        var items = sampleItems()
        items.append(QuickSwitcherItem(
            id: "f1",
            name: "Monthly revenue",
            kind: .savedQuery,
            subtitle: "rev",
            payload: "SELECT SUM(total) FROM orders GROUP BY month;"
        ))
        let vm = makeViewModel(items: items)
        vm.crossConnectionQueryItems = items
        vm.scope = .queries
        await vm.flushPendingFilter()
        let headers = vm.groups.compactMap(\.header)
        #expect(headers.contains(String(localized: "Saved Queries")))
    }

    @Test("Payload survives filtering")
    func payloadSurvivesFiltering() async throws {
        let items = [QuickSwitcherItem(
            id: "f1",
            name: "Monthly revenue",
            kind: .savedQuery,
            subtitle: "",
            payload: "SELECT SUM(total) FROM orders GROUP BY month;"
        )]
        let vm = makeViewModel(items: items)
        vm.searchText = "revenue"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.payload == "SELECT SUM(total) FROM orders GROUP BY month;")
    }

    @Test("Scope limits the empty-query view to its kinds")
    func scopeLimitsEmptyQueryView() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        #expect(vm.flatItems.allSatisfy { [.table, .view, .systemTable].contains($0.kind) })
        vm.scope = .queries
        await vm.flushPendingFilter()
        #expect(vm.flatItems.allSatisfy { [.savedQuery, .queryHistory].contains($0.kind) })
    }

    @Test("Scope limits filtered results to its kinds")
    func scopeLimitsFilteredResults() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .containers
        vm.searchText = "r"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.allSatisfy { [.database, .schema].contains($0.kind) })
        #expect(vm.flatItems.contains { $0.id == "d1" })
    }

    @Test("A table already open in a tab outranks an equal match")
    func openTabOutranksEqualMatch() async throws {
        let items = [
            QuickSwitcherItem(id: "ta", name: "users_a", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "tb", name: "users_b", kind: .table, subtitle: "", isOpenInTab: true)
        ]
        let vm = makeViewModel(items: items)
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.id == "tb")
    }

    @Test("Query matching only the subtitle still surfaces the item")
    func subtitleMatchSurfacesItem() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "mydb"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains { $0.id == "h1" })
        #expect(vm.flatItems.first { $0.id == "h1" }?.matchedIndices.isEmpty == true)
    }

    @Test("Search keeps selection if still in results")
    func searchKeepsSelectionWhenPresent() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "t1"
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == "t1" }))
        #expect(vm.selectedItemId == "t1")
    }

    @Test("Search resets selection when previous selection is filtered out")
    func searchResetsSelectionWhenAbsent() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "d1"
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == "d1" }) == false)
        #expect(vm.selectedItemId == vm.flatItems.first?.id)
    }

    @Test("listHeight is zero when there are no items")
    func listHeightZeroWhenEmpty() async {
        let vm = makeViewModel(items: [])
        await vm.flushPendingFilter()
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 0)
    }

    @Test("listHeight for a single filtered result is one row")
    func listHeightSingleFilteredRow() async throws {
        let vm = makeViewModel(items: [QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: "")])
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.groups.first?.header == nil)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 30)
    }

    @Test("listHeight at the row cap shows every row")
    func listHeightAtCap() async throws {
        var items: [QuickSwitcherItem] = []
        for index in 0..<9 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "tbl_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.searchText = "tbl"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.count == 9)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("listHeight caps at maxVisibleRows when results overflow")
    func listHeightCapsWhenOverflowing() async throws {
        var items: [QuickSwitcherItem] = []
        for index in 0..<20 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "tbl_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.searchText = "tbl"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.count == 20)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("listHeight for a browse scope counts section headers")
    func listHeightCountsSectionHeaders() async {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        await vm.flushPendingFilter()
        #expect(vm.groups.filter { $0.header != nil }.count == 2)
        #expect(vm.flatItems.count == 3)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 146)
    }

    @Test("A recorded selection adds a Recent header and row to the empty-query view")
    func listHeightIncludesRecentHeader() async {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        await vm.flushPendingFilter()
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 100) == 0)
        vm.recordSelection(items[0])

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        await vm2.flushPendingFilter()
        #expect(vm2.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 100) == 58)
    }

    @Test("listHeight clamps to the cap when sections and rows overflow")
    func listHeightClampsWithHeaders() async {
        var items: [QuickSwitcherItem] = []
        for index in 0..<30 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
            items.append(QuickSwitcherItem(id: "v\(index)", name: "view_\(index)", kind: .view, subtitle: "View"))
        }
        let vm = makeViewModel(items: items)
        vm.scope = .tables
        await vm.flushPendingFilter()
        #expect(vm.groups.filter { $0.header != nil }.count >= 2)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("isLoading is true until the first load finishes")
    func isLoadingStartsTrue() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        #expect(vm.isLoading)
    }

    /// The panel used to state `No results for "us"` for the whole catalog fetch, because
    /// `isLoading` had no reader and an empty result set reads the same either way.
    @Test("A search typed before the catalog arrives reports loading, not no results")
    func searchDuringInitialLoadReportsLoading() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        vm.searchText = "us"
        #expect(vm.isLoading)
        #expect(vm.isLoadingResults)
    }

    /// The All scope with an empty search shows only Recent, which is resolved against the catalog,
    /// and the user has not asked for anything yet, so a spinner there would fire on every
    /// presentation for a list nobody is waiting on.
    @Test("An empty search in the All scope reports no loading while the catalog arrives")
    func emptySearchInAllScopeReportsNoLoading() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        #expect(vm.isLoading)
        #expect(!vm.isLoadingResults)
    }

    /// A scope other than All lists its whole contents with an empty search, so it does wait.
    /// Every narrowed scope, not just the first one: the carve-out is All's alone, and nothing else
    /// would catch a future change that special-cases another scope beside it.
    @Test("An empty search in a narrowed scope reports loading")
    func emptySearchInNarrowedScopeReportsLoading() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        for scope in [QuickSwitcherScope.tables, .containers] {
            vm.scope = scope
            #expect(vm.isLoadingResults, "\(scope) must report the first load")
        }
    }

    /// Whitespace is not a search. Trimming has to happen before the emptiness test or a stray
    /// space opens the result surface with a spinner in it.
    @Test("A whitespace-only search in the All scope reports no loading")
    func whitespaceSearchInAllScopeReportsNoLoading() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        vm.searchText = "   "
        #expect(!vm.isLoadingResults)
    }

    /// Ranking runs off the main actor behind a debounce, so the catalog arriving is not the same
    /// moment the results do. That gap showed the same wrong "no results" message.
    @Test("The sort that follows the catalog is still reported as loading")
    func filteringAfterCatalogArrivesReportsLoading() async {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "user"
        #expect(vm.isFiltering)
        #expect(vm.isLoadingResults)

        await vm.flushPendingFilter()
        #expect(!vm.isFiltering)
        #expect(!vm.isLoadingResults)
        /// Without this the assertions after the flush are the same as the genuine-miss test below,
        /// so the case would pass vacuously if `sampleItems()` ever stopped matching "user".
        #expect(!vm.flatItems.isEmpty, "the query this test is about does match something")
    }

    @Test("A search that genuinely matches nothing reports no loading once it has run")
    func settledEmptyResultReportsNoLoading() async {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "no-such-object-anywhere"
        await vm.flushPendingFilter()
        #expect(vm.flatItems.isEmpty)
        #expect(!vm.isLoadingResults)
    }

    @Test("A large first section does not delete the sections after it")
    func largeSectionKeepsLaterSections() async {
        var items: [QuickSwitcherItem] = []
        for index in 0..<250 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        for index in 0..<40 {
            items.append(QuickSwitcherItem(id: "v\(index)", name: "view_\(index)", kind: .view, subtitle: "View"))
        }
        let vm = makeViewModel(items: items)
        vm.scope = .tables
        await vm.flushPendingFilter()

        let headers = vm.groups.compactMap(\.header)
        #expect(headers.contains(String(localized: "Tables")))
        #expect(headers.contains(String(localized: "Views")))
        #expect(vm.groups.first { $0.header == String(localized: "Views") }?.items.count == 40)
    }

    @Test("A busy connection does not crowd another out of the history list")
    func historyInterleavesAcrossConnections() {
        let busy = UUID()
        let quiet = UUID()
        let now = Date()
        let busyEntries = (0..<200).map { index in
            QueryHistoryEntry(
                query: "SELECT \(index)",
                connectionId: busy,
                databaseName: "app",
                databaseType: .postgresql,
                source: .editor,
                executedAt: now.addingTimeInterval(-Double(index)),
                executionTime: 0.01,
                rowCount: 1,
                wasSuccessful: true
            )
        }
        let quietEntries = [
            QueryHistoryEntry(
                query: "SELECT yesterday",
                connectionId: quiet,
                databaseName: "warehouse",
                databaseType: .postgresql,
                source: .editor,
                executedAt: now.addingTimeInterval(-86_400),
                executionTime: 0.01,
                rowCount: 1,
                wasSuccessful: true
            )
        ]

        let merged = QuickSwitcherViewModel.interleaveByConnection(
            [busyEntries, quietEntries],
            limit: 200
        )

        #expect(merged.count == 200)
        #expect(merged.contains { $0.connectionId == quiet })
    }

    @Test("A keyword outranks a connection name in a saved query subtitle")
    func keywordOutranksConnectionPath() async {
        let keyworded = QuickSwitcherItem(
            id: "favorite_keyworded",
            name: "Daily totals",
            kind: .savedQuery,
            subtitle: "prod · Analytics / warehouse",
            keyword: "prod",
            payload: "SELECT 1"
        )
        let pathOnly = QuickSwitcherItem(
            id: "favorite_path",
            name: "Customer churn",
            kind: .savedQuery,
            subtitle: "Production / app",
            payload: "SELECT 2"
        )
        let vm = makeViewModel(items: [pathOnly, keyworded])
        vm.searchText = "prod"
        await vm.flushPendingFilter()

        #expect(vm.flatItems.first?.id == "favorite_keyworded")
    }

    @Test("Selecting another connection's result records it against that connection")
    func frecencyRecordsAgainstOwningConnection() {
        let suite = makeDefaults()
        let localConnectionId = UUID()
        let remoteConnectionId = UUID()
        let vm = makeViewModel(items: [], connectionId: localConnectionId, defaults: suite)
        let remote = QuickSwitcherItem(
            id: "history_remote",
            name: "SELECT * FROM events",
            kind: .queryHistory,
            subtitle: "Analytics / warehouse",
            payload: "SELECT * FROM events",
            target: QuickSwitcherTarget(
                connectionId: remoteConnectionId,
                connectionName: "Analytics",
                databaseName: "warehouse",
                schemaName: nil
            )
        )

        vm.recordSelection(remote)

        let localStore = QuickSwitcherFrecencyStore(connectionId: localConnectionId, defaults: suite)
        let remoteStore = QuickSwitcherFrecencyStore(connectionId: remoteConnectionId, defaults: suite)
        #expect(localStore.recentItemIds(limit: 10).isEmpty)
        #expect(remoteStore.recentItemIds(limit: 10) == ["history_remote"])
    }
}
