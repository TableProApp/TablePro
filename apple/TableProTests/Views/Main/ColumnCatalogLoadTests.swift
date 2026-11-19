import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import TableProSQLGrammar
import Testing

@MainActor
private final class HeldCatalogTarget: CatalogChangeTarget {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    func refreshCatalog(for change: CatalogChange) async {
        isHolding = true
        await withCheckedContinuation { gate = $0 }
        isHolding = false
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private func services(applyingChangesWith catalogChanges: CatalogChangeService) -> AppServices {
    let live = AppServices.live
    return AppServices(
        appEvents: live.appEvents,
        appSettings: live.appSettings,
        appSettingsStorage: live.appSettingsStorage,
        connectionStorage: live.connectionStorage,
        databaseManager: live.databaseManager,
        pluginManager: live.pluginManager,
        schemaService: live.schemaService,
        schemaRefreshService: live.schemaRefreshService,
        schemaProviderRegistry: live.schemaProviderRegistry,
        catalogChangeService: catalogChanges,
        sqlFavoriteManager: live.sqlFavoriteManager,
        favoriteTablesStorage: live.favoriteTablesStorage,
        favoriteDatabasesStorage: live.favoriteDatabasesStorage,
        tableFolderStorage: live.tableFolderStorage,
        aiChatStorage: live.aiChatStorage,
        aiKeyStorage: live.aiKeyStorage,
        aiAccessApprovals: live.aiAccessApprovals,
        groupStorage: live.groupStorage,
        tagStorage: live.tagStorage,
        sshProfileStorage: live.sshProfileStorage,
        credentialProfileStorage: live.credentialProfileStorage,
        featureAccess: live.featureAccess,
        syncMetadataStorage: live.syncMetadataStorage,
        favoritesExpansionState: live.favoritesExpansionState,
        linkedFolderWatcher: live.linkedFolderWatcher,
        queryHistoryManager: live.queryHistoryManager,
        dateFormattingService: live.dateFormattingService,
        copilotService: live.copilotService,
        mcpServerManager: live.mcpServerManager,
        syncTracker: live.syncTracker,
        welcomeRouter: live.welcomeRouter,
        telemetry: live.telemetry
    )
}

extension GlobalStateSuites {
    @MainActor
    struct ColumnCatalogLoadTests {
        private static let users = TestFixtures.makeTableInfo(name: "users")

        private static func column(_ name: String, key: Bool = false) -> ColumnInfo {
            TestFixtures.makeColumnInfo(name: name, isPrimaryKey: key)
        }

        @MainActor
        private struct Harness {
            let fixture: CoordinatorFixture
            let driver: MockDatabaseDriver
            let scope: DatabaseScope
            let catalog: SQLSchemaProvider

            var coordinator: MainContentCoordinator { fixture.coordinator }
            var key: String { coordinator.schemaColumnsKey("users", scope: scope) }
            var tab: QueryTab { coordinator.tabManager.tabs[0] }
            var entry: SchemaColumnStore.Entry? { coordinator.schemaColumns.cached(key) }
            var notice: OutdatedPageNotice? { tab.outdatedPageNotice }
            var standing: CatalogPage.Standing? { coordinator.tabSessionRegistry.catalogPage(for: tab.id)?.standing }

            func addUsersTab(hiding hidden: Set<String> = [], configure: (inout QueryTab) -> Void = { _ in }) -> UUID {
                var tab = QueryTab(title: "users", query: "", tabType: .table)
                tab.tableContext.tableName = "users"
                tab.columnLayout.hiddenColumns = hidden
                configure(&tab)
                fixture.addTab(tab)
                return tab.id
            }

            func cataloged() async -> [String]? {
                await catalog.catalogColumns(forTable: "users", schema: nil)?.map(\.name)
            }

            func runUntilSettled(_ tabId: UUID, queries: Int) async throws {
                try await waitUntil {
                    driver.executedUserQueries.count == queries
                        && !coordinator.tabExecution.isExecuting(tabId)
                        && (coordinator.tabManager.tabs[0].execution.lastExecutedAt != nil
                            || coordinator.tabManager.tabs[0].execution.errorMessage != nil)
                }
            }

            func open(_ tabId: UUID) async throws {
                await coordinator.openTableTabQuery(tabId: tabId)
                try await runUntilSettled(tabId, queries: driver.executedUserQueries.count + 1)
            }
        }

        private func makeHarness(
            cataloged: [ColumnInfo],
            current: [ColumnInfo],
            services: AppServices = .live
        ) async throws -> Harness {
            AppSettingsManager.shared.dataGrid.defaultSortBehavior = .primaryKey
            let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
            let driver = MockDatabaseDriver(connection: connection)
            driver.bulkColumnReadIsComplete = true
            driver.tablesToReturn = [Self.users]
            driver.allColumnsToReturn = ["users": cataloged]
            driver.columnsToReturn = ["users": current]
            let fixture = CoordinatorFixture(connection: connection, driver: driver, services: services)
            let scope = try #require(fixture.coordinator.browseScope)
            let catalog = SchemaProviderRegistry.shared.getOrCreate(for: scope)
            await catalog.resetForDatabase("db", tables: [Self.users], driver: driver)
            await catalog.seedColumnCatalog()
            await catalog.waitForEagerColumnLoad()
            return Harness(fixture: fixture, driver: driver, scope: scope, catalog: catalog)
        }

        private func tearDown(_ harness: Harness, restoring behavior: DefaultSortBehavior) {
            SchemaProviderRegistry.shared.clear(for: harness.fixture.connection.id)
            AppSettingsManager.shared.dataGrid.defaultSortBehavior = behavior
        }

        @Test("A catalog hit runs its page beside the column read, installs it once the read confirms it, and reads once")
        func catalogHitRunsThePageBesideTheColumnRead() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(cataloged: listed, current: listed)
            defer { tearDown(harness, restoring: behavior) }
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate
            let tabId = harness.addUsersTab()

            await harness.coordinator.openTableTabQuery(tabId: tabId)
            try await waitUntil { harness.driver.executedUserQueries.count == 1 && harness.driver.fetchColumnsCallCount == 1 }

            #expect(harness.driver.executedUserQueries[0].contains("ORDER BY \"id\""))
            #expect(harness.tab.execution.lastExecutedAt == nil)
            #expect(harness.coordinator.tabExecution.isExecuting(tabId))

            await gate.open()
            try await harness.runUntilSettled(tabId, queries: 1)
            #expect(harness.notice == nil)
            #expect(harness.standing == nil)
            #expect(harness.entry?.columns == ["id", "name"])
            try await waitUntil { harness.coordinator.phase2Works[tabId] == nil }
            #expect(harness.driver.fetchColumnsCallCount == 1)
            #expect(await harness.cataloged() == ["id", "name"])
        }

        @Test("A temporary table and a restored view read their columns before the page", arguments: [true, false])
        func sessionBoundOrRestoredViewReadsFirst(isTemporary: Bool) async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(cataloged: listed, current: listed)
            defer { tearDown(harness, restoring: behavior) }
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate
            let tabId = harness.addUsersTab { tab in
                if isTemporary {
                    tab.tableContext.isTemporary = true
                } else {
                    tab.pendingRestoredSort = [PersistedSortColumn(columnName: "name", direction: .ascending)]
                    tab.restoredSortSource = .user
                }
            }

            let opening = Task { await harness.coordinator.openTableTabQuery(tabId: tabId) }
            try await waitUntil { harness.driver.fetchColumnsCallCount == 1 }
            #expect(harness.driver.executedUserQueries.isEmpty)

            await gate.open()
            await opening.value
            try await harness.runUntilSettled(tabId, queries: 1)
            #expect(harness.coordinator.tabSessionRegistry.catalogPage(for: tabId) == nil)
            #expect(harness.notice == nil)
        }

        @Test("A catalog change still being applied makes the open read its columns before the page")
        func catalogChangeInFlightReadsFirst() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let target = HeldCatalogTarget()
            let catalogChanges = CatalogChangeService(targets: [target], isSessionLive: { _ in true })
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(
                cataloged: listed, current: listed, services: services(applyingChangesWith: catalogChanges)
            )
            defer { tearDown(harness, restoring: behavior) }
            let connectionId = harness.fixture.connection.id
            catalogChanges.record(.changed(CatalogChange(connectionId: connectionId, kinds: .tables)))
            try await waitUntil { target.isHolding }
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate
            let tabId = harness.addUsersTab()

            let opening = Task { await harness.coordinator.openTableTabQuery(tabId: tabId) }
            try await waitUntil { harness.driver.fetchColumnsCallCount == 1 }
            #expect(harness.driver.executedUserQueries.isEmpty)

            await gate.open()
            await opening.value
            try await harness.runUntilSettled(tabId, queries: 1)
            #expect(harness.coordinator.tabSessionRegistry.catalogPage(for: tabId) == nil)
            target.release()
            await catalogChanges.waitUntilIdle(connectionId: connectionId)
        }

        @Test("A page the confirmed list builds differently keeps its rows, shows a notice on that page and never runs again")
        func confirmedDifferentShowsANoticeAndNeverReruns() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])

            try await harness.open(tabId)

            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(harness.driver.executedUserQueries[0].contains("email") == false)
            let notice = try #require(harness.notice)
            #expect(notice.resultSetId == harness.tab.display.activeResultSet?.id)
            #expect(harness.tab.shownOutdatedPageNotice == notice)
            #expect(harness.standing == .outdated)
            #expect(harness.entry?.columns == ["id", "name", "email"])
            try await waitUntil { await harness.cataloged() == nil }

            harness.coordinator.executeTableTabQueryDirectly(onTab: tabId, trigger: .autoRefresh, viewport: .keepPlace)
            try await harness.runUntilSettled(tabId, queries: 2)
            #expect(harness.driver.executedUserQueries[1] == harness.driver.executedUserQueries[0])
            let moved = try #require(harness.notice)
            #expect(moved.resultSetId != notice.resultSetId)
            #expect(moved.resultSetId == harness.tab.display.activeResultSet?.id)
        }

        @Test("A rerun of the catalog-built query is judged as it ran, even when the tab changed before rebuilding it")
        func rerunIsJudgedByTheSQLThatRan() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            let first = try #require(harness.notice)

            harness.coordinator.tabManager.mutate(tabId: tabId) { $0.columnLayout.hiddenColumns = [] }
            harness.coordinator.executeTableTabQueryDirectly(onTab: tabId, trigger: .autoRefresh, viewport: .keepPlace)
            try await harness.runUntilSettled(tabId, queries: 2)

            #expect(harness.driver.executedUserQueries[1] == harness.driver.executedUserQueries[0])
            let moved = try #require(harness.tab.shownOutdatedPageNotice)
            #expect(moved.resultSetId != first.resultSetId)
            #expect(harness.standing == .outdated)
        }

        @Test("A rerun of an outdated page whose columns cannot be read keeps the notice on the new page")
        func unconfirmedRerunKeepsAKnownVerdict() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            let first = try #require(harness.notice)
            harness.coordinator.schemaColumns.removeAll()
            harness.driver.fetchColumnsError = DatabaseError.queryFailed("connection lost")

            harness.coordinator.executeTableTabQueryDirectly(onTab: tabId, trigger: .autoRefresh, viewport: .keepPlace)
            try await harness.runUntilSettled(tabId, queries: 2)

            let kept = try #require(harness.tab.shownOutdatedPageNotice)
            #expect(kept.resultSetId != first.resultSetId)
            #expect(harness.standing == .outdated)
        }

        @Test("An unconfirmed page under a sort the user picked drops the notice, since nothing on it came from the catalog list")
        func unconfirmedUserSortedPageDropsTheNotice() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code"), Self.column("name")],
                current: [Self.column("id"), Self.column("code", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab()
            try await harness.open(tabId)
            #expect(harness.notice != nil)
            harness.coordinator.schemaColumns.removeAll()
            harness.driver.fetchColumnsError = DatabaseError.queryFailed("connection lost")

            harness.coordinator.tabManager.mutate(tabId: tabId) {
                $0.sortState = SortState(columns: [SortColumn(columnIndex: 2, direction: .ascending, columnName: "name")], source: .user)
            }
            harness.coordinator.reloadTableTab(tabId)
            try await harness.runUntilSettled(tabId, queries: 2)

            #expect(harness.notice == nil)
            #expect(harness.standing == .outdated)
        }

        @Test("A page that lands while its columns cannot be read stays as built, unconfirmed, until a later run confirms it")
        func unreadableColumnsLeaveThePageUnconfirmed() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(cataloged: listed, current: listed)
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.fetchColumnsError = DatabaseError.queryFailed("permission denied for pg_attribute")
            let tabId = harness.addUsersTab()

            try await harness.open(tabId)

            #expect(harness.tab.execution.errorMessage == nil)
            #expect(harness.notice == nil)
            #expect(harness.standing == .awaiting)
            #expect(harness.entry == nil)

            harness.driver.fetchColumnsError = nil
            harness.coordinator.reloadTableTab(tabId)
            try await harness.runUntilSettled(tabId, queries: 2)
            #expect(harness.standing == nil)
            #expect(harness.notice == nil)
        }

        @Test("A page refused on a list the read confirms shows the error as today and keeps the catalog")
        func failureOnAConfirmedListIsShownAsToday() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(cataloged: listed, current: listed)
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.failsStatementContaining = ("users", DatabaseError.queryFailed("permission denied for table users"))
            let tabId = harness.addUsersTab()

            try await harness.open(tabId)

            #expect(harness.tab.execution.errorMessage != nil)
            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(harness.notice == nil)
            #expect(harness.standing == nil)
            #expect(await harness.cataloged() == ["id", "name"])
        }

        @Test("A page refused on an outdated list shows the error and a Reload that loads the current columns, never by itself")
        func failureOnAnOutdatedListOffersReload() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("gone"), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.failsStatementContaining = ("gone", DatabaseError.queryFailed("column \"gone\" does not exist"))
            let tabId = harness.addUsersTab(hiding: ["name"])

            try await harness.open(tabId)

            #expect(harness.tab.execution.errorMessage != nil)
            #expect(harness.driver.executedUserQueries.count == 1)
            let notice = try #require(harness.tab.shownOutdatedPageNotice)
            #expect(notice.resultSetId == nil)
            try await waitUntil { await harness.cataloged() == nil }

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            try await harness.runUntilSettled(tabId, queries: 2)
            #expect(harness.driver.executedUserQueries[1].contains("gone") == false)
            #expect(harness.tab.execution.errorMessage == nil)
            #expect(harness.notice == nil)
            #expect(harness.standing == nil)
        }

        @Test("A page refused while its columns cannot be read shows the error and drops the catalog list")
        func failureWithUnreadableColumnsDropsTheList() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("gone"), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.failsStatementContaining = ("gone", DatabaseError.queryFailed("column \"gone\" does not exist"))
            harness.driver.fetchColumnsError = DatabaseError.queryFailed("connection lost")
            let tabId = harness.addUsersTab(hiding: ["name"])

            try await harness.open(tabId)

            #expect(harness.tab.execution.errorMessage != nil)
            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(harness.notice == nil)
            #expect(harness.standing == .awaiting)
            try await waitUntil { await harness.cataloged() == nil }
        }

        @Test("A later page keeps the notice while it carries the old default sort, and a sort the user picks clears it")
        func laterPageKeepsTheNoticeWhileTheOldSortHolds() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code"), Self.column("name")],
                current: [Self.column("id"), Self.column("code", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab()

            try await harness.open(tabId)
            let first = try #require(harness.notice)

            harness.coordinator.reloadTableTab(tabId)
            try await harness.runUntilSettled(tabId, queries: 2)
            #expect(harness.driver.executedUserQueries[1].contains("ORDER BY \"id\""))
            let kept = try #require(harness.tab.shownOutdatedPageNotice)
            #expect(kept.resultSetId != first.resultSetId)

            harness.coordinator.tabManager.mutate(tabId: tabId) {
                $0.sortState = SortState(columns: [SortColumn(columnIndex: 2, direction: .ascending, columnName: "name")], source: .user)
            }
            harness.coordinator.reloadTableTab(tabId)
            try await harness.runUntilSettled(tabId, queries: 3)
            #expect(harness.notice == nil)
            #expect(harness.standing == nil)
        }

        @Test("A rerun of a query built on the catalog list folds the byte lengths of that list")
        func rerunFoldsTheListItWasBuiltOn() {
            let tabManager = QueryTabManager()
            let coordinator = MainContentCoordinator(
                connection: TestFixtures.makeConnection(type: .mysql),
                tabManager: tabManager,
                toolbarState: ConnectionToolbarState()
            )
            defer { coordinator.teardown() }
            var tab = QueryTab(title: "files", query: "", tabType: .table)
            tab.tableContext.tableName = "files"
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id
            let types: [String: ColumnType] = [
                "id": .integer(rawType: "INT"), "data": .blob(rawType: "LONGBLOB"), "more": .blob(rawType: "LONGBLOB")
            ]
            let catalogList = SchemaColumnStore.Entry(columns: ["id", "data"], primaryKeys: ["id"], columnTypes: types)
            coordinator.filterCoordinator.rebuildTableQuery(at: 0, builtOn: catalogList)
            coordinator.noteCatalogPage(catalogList, ofTab: tab.id)
            coordinator.schemaColumns.store(
                SchemaColumnStore.Entry(columns: ["id", "data", "more"], primaryKeys: ["id"], columnTypes: types),
                for: coordinator.schemaColumnsKey("files", scope: coordinator.selectedTabScope)
            )
            let stored = tabManager.tabs[0]

            #expect(coordinator.unloadedValueLengthColumns(for: stored, sql: stored.content.query).count == 1)
            #expect(coordinator.unloadedValueLengthColumns(for: stored, sql: "SELECT * FROM `files`").count == 2)
        }

        @Test("Reload sorts by the confirmed key, built on the confirmed columns rather than the rows on screen")
        func reloadSortsByTheConfirmedKey() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code"), Self.column("name")],
                current: [Self.column("id"), Self.column("code", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.userQueryColumns = ["id", "name"]
            let tabId = harness.addUsersTab(hiding: ["code"])

            try await harness.open(tabId)
            #expect(harness.notice != nil)
            #expect(harness.tab.sortState.columns.compactMap(\.columnName) == ["id"])

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            try await harness.runUntilSettled(tabId, queries: 2)

            #expect(harness.notice == nil)
            #expect(harness.standing == nil)
            #expect(harness.tab.sortState.columns.compactMap(\.columnName) == ["code"])
            #expect(harness.driver.executedUserQueries[1].contains("ORDER BY \"code\""))
        }

        @Test("A key the catalog list did not have gets the notice, and Reload sorts by it")
        func newKeyOnAnUnsortedPageOffersReload() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id"), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab()

            try await harness.open(tabId)
            #expect(harness.driver.executedUserQueries[0].contains("ORDER BY") == false)
            #expect(harness.tab.shownOutdatedPageNotice != nil)

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            try await harness.runUntilSettled(tabId, queries: 2)
            #expect(harness.driver.executedUserQueries[1].contains("ORDER BY \"id\""))
            #expect(harness.notice == nil)
        }

        @Test("A Reload that fails leaves the notice over the page still on screen")
        func failedReloadKeepsTheNotice() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code")],
                current: [Self.column("id"), Self.column("code", key: true)]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab()
            try await harness.open(tabId)
            let notice = try #require(harness.notice)
            harness.driver.failsStatementContaining = ("ORDER BY \"code\"", DatabaseError.queryFailed("canceling statement due to lock timeout"))

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            try await harness.runUntilSettled(tabId, queries: 2)

            #expect(harness.tab.execution.errorMessage != nil)
            #expect(harness.tab.shownOutdatedPageNotice == notice)
            #expect(harness.standing == .outdated)
        }

        @Test("A tab moved to another table while Reload reads the columns ends the Reload and the notice")
        func retargetDuringReloadEndsIt() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            #expect(harness.notice != nil)
            harness.coordinator.schemaColumns.removeAll()
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            try await waitUntil { harness.driver.fetchColumnsCallCount == 2 }
            let reload = try #require(harness.coordinator.catalogPageReloads[tabId]?.task)
            try harness.coordinator.tabManager.replaceTabContent(tableName: "orders", databaseType: .duckdb, databaseName: "db")
            harness.coordinator.discardRowsForRetarget(ofTab: tabId)
            await gate.open()
            await reload.value
            await harness.coordinator.queryTasks.task(for: tabId)?.value

            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(harness.notice == nil)
            #expect(harness.coordinator.tabSessionRegistry.catalogPage(for: tabId) == nil)
        }

        @Test("A run stopped before its page lands withdraws from the column read it started")
        func stoppedRunWithdrawsItsColumnRead() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let listed = [Self.column("id", key: true), Self.column("name")]
            let harness = try await makeHarness(cataloged: listed, current: listed)
            defer { tearDown(harness, restoring: behavior) }
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate
            harness.driver.pausesNextUserQuery = true
            let tabId = harness.addUsersTab()

            await harness.coordinator.openTableTabQuery(tabId: tabId)
            try await waitUntil {
                harness.driver.isHoldingUserQuery && harness.coordinator.schemaColumns.waiterCount(for: harness.key) == 1
            }
            let run = try #require(harness.coordinator.queryTasks.task(for: tabId))

            harness.coordinator.stopExecution(for: tabId)
            harness.driver.resumeUserQuery()
            await run.value

            try await waitUntil { harness.coordinator.schemaColumns.waiterCount(for: harness.key) == 0 }
            await gate.open()
        }

        @Test("A tab moved to another window keeps its notice, and Reload there loads the current columns")
        func movedTabKeepsItsNoticeAndReload() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            #expect(harness.notice != nil)

            let destination = CoordinatorFixture(connection: harness.fixture.connection)
            destination.addTab(harness.coordinator.enrichedForPersistence(harness.tab))
            let session = try #require(harness.coordinator.tabSessionRegistry.session(for: tabId))
            destination.coordinator.tabSessionRegistry.register(session)
            harness.coordinator.tabSessionRegistry.unregister(id: tabId)
            harness.coordinator.tabManager.closeTab(id: tabId)

            #expect(destination.coordinator.tabSessionRegistry.catalogPage(for: tabId)?.standing == .outdated)
            #expect(destination.tabManager.tabs[0].shownOutdatedPageNotice != nil)

            destination.coordinator.reloadOutdatedPage(tabId: tabId)
            try await waitUntil {
                harness.driver.executedUserQueries.count == 2
                    && !destination.coordinator.tabExecution.isExecuting(tabId)
                    && destination.tabManager.tabs[0].outdatedPageNotice == nil
            }
            #expect(harness.driver.executedUserQueries[1].contains("email"))
        }

        @Test("A Reload asked for just before the tab moves to another table never runs or re-sorts it")
        func retargetBeforeReloadStartsEndsIt() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code")],
                current: [Self.column("id"), Self.column("code", key: true)]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab()
            try await harness.open(tabId)
            #expect(harness.notice != nil)
            #expect(harness.entry != nil)

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            let reload = try #require(harness.coordinator.catalogPageReloads[tabId]?.task)
            try harness.coordinator.tabManager.replaceTabContent(tableName: "orders", databaseType: .duckdb, databaseName: "db")
            harness.coordinator.discardRowsForRetarget(ofTab: tabId)
            await reload.value
            await harness.coordinator.queryTasks.task(for: tabId)?.value

            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(harness.tab.sortState == SortState())
            #expect(harness.tab.tableContext.tableName == "orders")
        }

        @Test("An edit made while Reload reads the columns is asked about, and kept when the answer is no")
        func editDuringReloadReadIsAskedAbout() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            #expect(harness.notice != nil)
            harness.coordinator.schemaColumns.removeAll()
            let gate = AsyncGate()
            harness.driver.fetchColumnsGate = gate

            harness.coordinator.reloadOutdatedPage(tabId: tabId)
            let reload = try #require(harness.coordinator.catalogPageReloads[tabId]?.task)
            try await waitUntil { harness.driver.fetchColumnsCallCount == 2 }
            let manager = harness.coordinator.changeManager(forTab: tabId)
            manager.recordCellChange(
                rowID: .existing(0), columnIndex: 0, columnName: "id", oldValue: "1", newValue: "2", originalRow: ["1"]
            )
            harness.coordinator.isShowingConfirmAlert = true
            await gate.open()
            await reload.value
            await harness.coordinator.queryTasks.task(for: tabId)?.value
            harness.coordinator.isShowingConfirmAlert = false

            #expect(harness.driver.executedUserQueries.count == 1)
            #expect(manager.hasChanges)
            #expect(harness.notice != nil)
        }

        @Test("A dismissed notice stays down for later pages of the same query")
        func dismissedNoticeStaysDown() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("name")],
                current: [Self.column("id", key: true), Self.column("name"), Self.column("email")]
            )
            defer { tearDown(harness, restoring: behavior) }
            let tabId = harness.addUsersTab(hiding: ["name"])
            try await harness.open(tabId)
            #expect(harness.notice != nil)

            harness.coordinator.dismissOutdatedPageNotice(tabId: tabId)
            #expect(harness.notice == nil)
            harness.coordinator.executeTableTabQueryDirectly(onTab: tabId, trigger: .autoRefresh, viewport: .keepPlace)
            try await harness.runUntilSettled(tabId, queries: 2)

            #expect(harness.notice == nil)
            #expect(harness.standing == .dismissed)
        }

        @Test("A run another run superseded never touches the notice of the page that replaced it")
        func supersededRunCannotTouchTheNotice() async throws {
            let behavior = AppSettingsManager.shared.dataGrid.defaultSortBehavior
            let harness = try await makeHarness(
                cataloged: [Self.column("id", key: true), Self.column("code"), Self.column("name")],
                current: [Self.column("id"), Self.column("code", key: true), Self.column("name")]
            )
            defer { tearDown(harness, restoring: behavior) }
            harness.driver.pausesNextUserQuery = true
            let tabId = harness.addUsersTab()

            await harness.coordinator.openTableTabQuery(tabId: tabId)
            try await waitUntil { harness.driver.isHoldingUserQuery }
            let first = try #require(harness.coordinator.queryTasks.task(for: tabId))
            harness.coordinator.reloadTableTab(tabId)
            harness.driver.resumeUserQuery()
            await first.value
            try await harness.runUntilSettled(tabId, queries: 2)

            let notice = try #require(harness.notice)
            #expect(notice.resultSetId == harness.tab.display.activeResultSet?.id)
            #expect(harness.tab.display.resultSets.count == 1)
        }
    }
}
