//
//  QuickSwitcherRecentIdentityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Open Quickly Recent identity")
@MainActor
struct QuickSwitcherRecentIdentityTests {
    private let connectionId = UUID()
    private let start = Date()

    private func makeDefaults() -> UserDefaults? {
        UserDefaults(suiteName: "QuickSwitcherRecentIdentityTests.\(UUID().uuidString)")
    }

    private func table(_ name: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: "public")
    }

    private func tables(_ names: [String], in database: String) -> [QuickSwitcherItem] {
        QuickSwitcherViewModel.makeTableItems(
            names.map { table($0) },
            database: database,
            connectionSwitchesDatabases: true,
            browseSchema: "public",
            openTables: []
        )
    }

    private func connectionTables(
        _ names: [String],
        in database: String,
        on connection: UUID? = nil
    ) -> [QuickSwitcherItem] {
        QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: names.map { table($0) },
            target: QuickSwitcherTarget(
                connectionId: connection ?? connectionId,
                connectionName: connection == nil ? "Primary" : "Replica",
                databaseName: database,
                schemaName: "public"
            ),
            connectionSwitchesDatabases: true
        )
    }

    private func execution(_ query: String, on connection: UUID? = nil, at offset: TimeInterval) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connection ?? connectionId,
            databaseName: "app",
            databaseType: .postgresql,
            source: .editor,
            executedAt: start.addingTimeInterval(offset),
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    private func queryTarget(for connection: UUID, named name: String) -> QuickSwitcherTarget {
        QuickSwitcherTarget(connectionId: connection, connectionName: name, databaseName: "app", schemaName: nil)
    }

    private func queryItems(
        _ entries: [QueryHistoryEntry],
        targets: [UUID: QuickSwitcherTarget]? = nil
    ) -> [QuickSwitcherItem] {
        QuickSwitcherViewModel.makeCrossConnectionQueryItems(
            favorites: [],
            historyEntries: entries,
            targets: targets ?? [connectionId: queryTarget(for: connectionId, named: "Primary")],
            currentConnectionId: connectionId
        )
    }

    private func pick(_ item: QuickSwitcherItem, at offset: TimeInterval = 0, defaults: UserDefaults) {
        QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: defaults)
            .recordSelection(item, at: start.addingTimeInterval(offset))
    }

    private func makeViewModel(
        scope: QuickSwitcherScope,
        defaults: UserDefaults,
        allItems: [QuickSwitcherItem] = [],
        connectionItems: [QuickSwitcherItem] = [],
        queryItems: [QuickSwitcherItem] = [],
        searchText: String = ""
    ) async -> QuickSwitcherViewModel {
        let viewModel = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: defaults)
        viewModel.allItems = allItems
        viewModel.crossConnectionItems = connectionItems
        viewModel.crossConnectionQueryItems = queryItems
        viewModel.scope = scope
        viewModel.searchText = searchText
        await viewModel.flushPendingFilter()
        return viewModel
    }

    private func recent(
        in scope: QuickSwitcherScope,
        defaults: UserDefaults,
        allItems: [QuickSwitcherItem] = [],
        connectionItems: [QuickSwitcherItem] = [],
        queryItems: [QuickSwitcherItem] = []
    ) async -> [QuickSwitcherItem] {
        let viewModel = await makeViewModel(
            scope: scope,
            defaults: defaults,
            allItems: allItems,
            connectionItems: connectionItems,
            queryItems: queryItems
        )
        return viewModel.groups.first { $0.id == "recent" }?.items ?? []
    }

    // MARK: - A statement that runs again

    @Test("A query picked from the Queries scope stays recent after it runs again")
    func queryStaysRecentAfterRerun() async throws {
        let defaults = try #require(makeDefaults())
        let firstRun = execution("SELECT * FROM users", at: 0)
        let picked = try #require(queryItems([firstRun]).first)
        pick(picked, defaults: defaults)

        let rerun = execution("SELECT * FROM users", at: 60)
        let listed = await recent(in: .queries, defaults: defaults, queryItems: queryItems([rerun, firstRun]))

        #expect(listed.map(\.name) == [firstRun.queryPreview])
    }

    @Test("Queries picked from the All scope stay recent after each one runs again")
    func allScopeQueriesStayRecentAfterReruns() async throws {
        let defaults = try #require(makeDefaults())
        let statements = ["SELECT 1", "SELECT 2", "SELECT 3"]
        let firstRuns = statements.enumerated().map { execution($1, at: TimeInterval($0)) }
        let picked = QuickSwitcherViewModel.makeHistoryItems(firstRuns.reversed())
        for (offset, item) in picked.enumerated() {
            pick(item, at: TimeInterval(10 + offset), defaults: defaults)
        }

        let reruns = statements.enumerated().map { execution($1, at: TimeInterval(100 + $0)) }
        let listed = await recent(
            in: .all,
            defaults: defaults,
            allItems: QuickSwitcherViewModel.makeHistoryItems(reruns.reversed() + firstRuns.reversed())
        )
        let payloads = Set(listed.compactMap { $0.payload })

        #expect(payloads == Set(statements))
    }

    @Test("One statement run on two connections keeps a row, and a Recent entry, for each")
    func statementOnTwoConnectionsKeepsBothRows() async throws {
        let defaults = try #require(makeDefaults())
        let other = UUID()
        let targets = [
            connectionId: queryTarget(for: connectionId, named: "Primary"),
            other: queryTarget(for: other, named: "Analytics")
        ]
        let here = execution("SELECT count(*) FROM events", at: 0)
        let picked = try #require(queryItems([here], targets: targets).first)
        pick(picked, defaults: defaults)

        let there = execution("SELECT count(*) FROM events", on: other, at: 60)
        let items = queryItems([there, here], targets: targets)
        let listed = await recent(in: .queries, defaults: defaults, queryItems: items)

        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(listed.map { $0.target?.connectionId } == [connectionId])
    }

    // MARK: - The database a table lives in

    @Test("A table picked in one database is not recent in another")
    func tableIsRecentOnlyInItsDatabase() async throws {
        let defaults = try #require(makeDefaults())
        let picked = try #require(tables(["users"], in: "app_prod").first)
        pick(picked, defaults: defaults)

        let inStaging = await recent(in: .tables, defaults: defaults, allItems: tables(["users"], in: "app_staging"))
        let inProduction = await recent(in: .tables, defaults: defaults, allItems: tables(["users"], in: "app_prod"))

        #expect(inStaging.isEmpty)
        #expect(inProduction.map(\.name) == ["users"])
    }

    @Test("A table opened from a tab is recent in its own database only")
    func tabOpenIsRecentOnlyInItsDatabase() async throws {
        let defaults = try #require(makeDefaults())
        QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: defaults).recordAccess(
            itemId: SharedSidebarState.tableFrecencyKey(
                database: "app_prod", schema: "public", name: "users", connectionSwitchesDatabases: true
            )
        )

        let inStaging = await recent(in: .all, defaults: defaults, allItems: tables(["users"], in: "app_staging"))
        let inProduction = await recent(in: .all, defaults: defaults, allItems: tables(["users"], in: "app_prod"))

        #expect(inStaging.isEmpty)
        #expect(inProduction.map(\.name) == ["users"])
    }

    @Test("A table earns its frecency boost only in its own database")
    func frecencyBoostStaysInItsDatabase() async throws {
        let defaults = try #require(makeDefaults())
        let picked = try #require(tables(["users_b"], in: "app_prod").first)
        pick(picked, defaults: defaults)

        let staging = await makeViewModel(
            scope: .tables, defaults: defaults, allItems: tables(["users_a", "users_b"], in: "app_staging"), searchText: "users"
        )
        let production = await makeViewModel(
            scope: .tables, defaults: defaults, allItems: tables(["users_a", "users_b"], in: "app_prod"), searchText: "users"
        )

        #expect(staging.flatItems.first?.name == "users_a")
        #expect(production.flatItems.first?.name == "users_b")
    }

    @Test("Recent in one database is not crowded out by tables opened in another")
    func recentIsNotCrowdedOutByAnotherDatabase() async throws {
        let defaults = try #require(makeDefaults())
        let orders = try #require(tables(["orders"], in: "app_staging").first)
        pick(orders, at: 0, defaults: defaults)
        for (offset, item) in tables((0..<12).map { "prod_\($0)" }, in: "app_prod").enumerated() {
            pick(item, at: TimeInterval(1 + offset), defaults: defaults)
        }

        let inStaging = await recent(in: .tables, defaults: defaults, allItems: tables(["orders"], in: "app_staging"))

        #expect(inStaging.map(\.name) == ["orders"])
    }

    @Test("A connection that reaches one database still finds what it recorded before databases qualified a key")
    func singleDatabaseConnectionKeepsEarlierEntries() async throws {
        let defaults = try #require(makeDefaults())
        QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: defaults).recordAccess(itemId: "table_public.users")
        let items = QuickSwitcherViewModel.makeTableItems(
            [table("users")],
            database: "/Users/me/app.sqlite",
            connectionSwitchesDatabases: false,
            browseSchema: "public",
            openTables: []
        )

        let listed = await recent(in: .tables, defaults: defaults, allItems: items)

        #expect(listed.map(\.name) == ["users"])
    }

    // MARK: - One entry across scopes

    @Test("A table picked in the Connections scope is recent in the Tables scope")
    func connectionsPickIsRecentInTablesScope() async throws {
        let defaults = try #require(makeDefaults())
        let picked = try #require(connectionTables(["users"], in: "app").first)
        pick(picked, defaults: defaults)

        let listed = await recent(in: .tables, defaults: defaults, allItems: tables(["users"], in: "app"))

        #expect(listed.map(\.name) == ["users"])
    }

    @Test("Ten tables picked across two scopes fill Recent in each")
    func tenPicksAcrossScopesFillBothRecents() async throws {
        let defaults = try #require(makeDefaults())
        let names = (0..<10).map { "table_\($0)" }
        let listed = tables(names, in: "app")
        let connected = connectionTables(names, in: "app")
        for index in names.indices {
            let item = index.isMultiple(of: 2) ? connected[index] : listed[index]
            pick(item, at: TimeInterval(index), defaults: defaults)
        }

        let inTables = await recent(in: .tables, defaults: defaults, allItems: listed)
        let inConnections = await recent(in: .connections, defaults: defaults, connectionItems: connected)

        let newestFirst = Array(names.reversed())
        #expect(inTables.map(\.name) == newestFirst)
        #expect(inConnections.map(\.name) == newestFirst)
    }

    @Test("Another connection's table of the same name is never this connection's Recent")
    func anotherConnectionsTableIsNotRecent() async throws {
        let defaults = try #require(makeDefaults())
        let picked = try #require(connectionTables(["users"], in: "app").first)
        pick(picked, defaults: defaults)

        let items = connectionTables(["users"], in: "app", on: UUID()) + connectionTables(["users"], in: "app")
        let listed = await recent(in: .connections, defaults: defaults, connectionItems: items)

        #expect(Set(items.map(\.id)).count == 2)
        #expect(listed.map { $0.target?.connectionId } == [connectionId])
    }

    @Test("Another connection's table of the same name earns no frecency boost here")
    func anotherConnectionsTableEarnsNoBoost() async throws {
        let defaults = try #require(makeDefaults())
        let picked = try #require(connectionTables(["users_b"], in: "app").first)
        pick(picked, defaults: defaults)

        let replica = await makeViewModel(
            scope: .connections,
            defaults: defaults,
            connectionItems: connectionTables(["users_a", "users_b"], in: "app", on: UUID()),
            searchText: "users"
        )

        #expect(replica.flatItems.first?.name == "users_a")
    }
}
