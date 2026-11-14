//
//  ResultRowsBuildOffMainTests.swift
//  TableProTests
//
//  A query's rows are built off the main actor, under the shape the tab will install them with. The main actor then
//  assigns the buffer, and only builds again when that shape changed while the rows were built.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct ResultRowsBuildOffMainTests {
    private static let columns = ["id", "email"]
    private static let types: [ColumnType] = [.integer(rawType: "int"), .text(rawType: "varchar")]
    private static let fetched: [[PluginCellValue]] = [[.text("1"), .text("jane@example.com")], [.text("2"), .text("john@example.com")]]

    private let fixture: CoordinatorFixture = {
        var connection = TestFixtures.makeConnection(database: "shop")
        connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email)]
        return CoordinatorFixture(connection: connection)
    }()

    private static func address(of rows: ContiguousArray<Row>) -> UnsafeRawPointer? {
        rows.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    private func addUsersTab() -> QueryTab {
        fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
    }

    private func load(_ prepared: TableRows.PreparedRows, into tab: QueryTab) -> TableRows {
        fixture.coordinator.applyPhase1Result(
            tabId: tab.id,
            columns: Self.columns,
            columnTypes: Self.types,
            rows: Self.fetched,
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            tableName: "users",
            isEditable: true,
            metadata: nil,
            hasSchema: false,
            read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
            sql: "SELECT * FROM users",
            connection: fixture.connection,
            prepared: prepared
        )
        return fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id)
    }

    @Test("A first page built off the main actor is installed without another pass over its rows")
    func firstPageAdoptsThePreparedRows() async {
        let tab = addUsersTab()
        let shape = fixture.coordinator.phase1RowShape(tabId: tab.id, tableName: "users", columns: Self.columns, columnTypes: Self.types)
        let prepared = await TableRows.preparing(Self.fetched, shape: shape)

        let installed = load(prepared, into: tab)

        #expect(Self.address(of: installed.rows) == Self.address(of: prepared.rows))
        #expect(installed.value(at: 0, column: 1) == .text("j•••@example.com"))
        #expect(installed.masks.isMasked(1))
    }

    @Test("A first page built before a masking rule was saved is built again under the rule")
    func firstPageRebuildsRowsBuiltForOtherMasks() async {
        let unmasked = TableRows.RowShape(columns: Self.columns, masks: .none, exportPolicy: .none, exportTable: "users")
        let prepared = await TableRows.preparing(Self.fetched, shape: unmasked)

        let installed = load(prepared, into: addUsersTab())

        #expect(Self.address(of: installed.rows) != Self.address(of: prepared.rows))
        #expect(installed.value(at: 0, column: 1) == .text("j•••@example.com"))
        #expect(installed.value(at: 1, column: 1) == .text("j•••@example.com"))
    }

    @Test("A Run All statement's rows built off the main actor become its result without another pass")
    func runAllStatementAdoptsBuiltRows() async throws {
        let tab = fixture.addTab(QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query))
        let runner: QueryExecutionCoordinator = fixture.coordinator.queryExecutionCoordinator
        let result = ScriptAnsweringDriver.resultSet(columns: Self.columns, rows: [["1", "jane@example.com"], ["2", "john@example.com"]])

        let build = await runner.buildStatementRows([(sql: "SELECT * FROM users", result: result)], tabId: tab.id)
        let built = try #require(build.statement(at: 0, readBy: fixture.coordinator.tableNameReading))
        let resultSet = runner.makeStatementResultSet(
            result: result, sql: "SELECT * FROM users", index: 0, baseQuery: nil, tabId: tab.id, built: built
        )

        #expect(built.tableName == fixture.coordinator.extractTableName(from: "SELECT * FROM users"))
        #expect(Self.address(of: resultSet.tableRows.rows) == Self.address(of: built.prepared.rows))
        #expect(resultSet.tableRows.value(at: 1, column: 1) == .text("j•••@example.com"))
        #expect(resultSet.tableRows.masks.isMasked(1))
    }

    @Test("A Run All statement built before a masking rule applied is built again under it")
    func runAllStatementRebuildsRowsBuiltForOtherMasks() async throws {
        let tab = fixture.addTab(QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query))
        let runner: QueryExecutionCoordinator = fixture.coordinator.queryExecutionCoordinator
        let result = ScriptAnsweringDriver.resultSet(columns: Self.columns, rows: [["1", "jane@example.com"]])
        let reading = fixture.coordinator.tableNameReading

        let build = await QueryExecutionCoordinator.statementRows(
            [(sql: "SELECT * FROM users", result: result)], reading: reading, policy: .none
        )
        let built = try #require(build.statement(at: 0, readBy: reading))
        let resultSet = runner.makeStatementResultSet(
            result: result, sql: "SELECT * FROM users", index: 0, baseQuery: nil, tabId: tab.id, built: built
        )

        #expect(Self.address(of: resultSet.tableRows.rows) != Self.address(of: built.prepared.rows))
        #expect(resultSet.tableRows.value(at: 0, column: 1) == .text("j•••@example.com"))
    }

    @Test("Table names read under another session schema are not used")
    func statementNamesNeedTheSameReading() async {
        let reading = TableNameReading(dialect: .generic, readings: .single(.ansi), browseSchema: "public")
        let moved = TableNameReading(dialect: .generic, readings: .single(.ansi), browseSchema: "sales")
        let result = ScriptAnsweringDriver.resultSet(columns: ["n"], rows: [["1"]])

        let build = await QueryExecutionCoordinator.statementRows(
            [(sql: "SELECT * FROM public.users", result: result)], reading: reading, policy: .none
        )

        #expect(build.statement(at: 0, readBy: reading)?.tableName == "users")
        #expect(build.statement(at: 0, readBy: moved) == nil)
        #expect(build.statement(at: 1, readBy: reading) == nil)
    }

    private func runBatch(answeredWith resultSets: [QueryResult]) async throws -> [ResultSet] {
        let connection = fixture.connection
        let driver = ScriptAnsweringDriver(connection: connection, answer: { _ in ScriptAnsweringDriver.batch(resultSets) })
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = fixture.addTab(QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query))
        let runner: QueryExecutionCoordinator = fixture.coordinator.queryExecutionCoordinator
        runner.executeBatches(runner.executionBatches(in: "SELECT * FROM users"), parameters: [], onTab: tab.id)
        let handle = try #require(fixture.coordinator.queryTasks.task(for: tab.id))
        await handle.value
        return try #require(fixture.tabManager.tabs.first { $0.id == tab.id }).display.resultSets
    }

    @Test("A batch's result set that maps to its query is named after its table and masked")
    func batchResultMappedToItsQuery() async throws {
        let users = ScriptAnsweringDriver.resultSet(columns: Self.columns, rows: [["1", "jane@example.com"], ["2", "john@example.com"]])

        let results = try await runBatch(answeredWith: [users])

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.label == "users")
        #expect(result.tableRows.rows.count == 2)
        #expect(result.tableRows.value(at: 1, column: 1) == .text("j•••@example.com"))
    }

    @Test("A batch's numbered result sets are each masked and keep their order")
    func batchNumberedResultsAreMasked() async throws {
        let first = ScriptAnsweringDriver.resultSet(columns: Self.columns, rows: [["1", "jane@example.com"]])
        let second = ScriptAnsweringDriver.resultSet(columns: Self.columns, rows: [["2", "john@example.com"], ["3", "ann@example.com"]])

        let results = try await runBatch(answeredWith: [first, second])

        #expect(results.map { $0.tableRows.rows.count } == [1, 2])
        #expect(results.map { $0.tableRows.value(at: 0, column: 0) } == [.text("1"), .text("2")])
        #expect(results.allSatisfy { $0.tableRows.value(at: 0, column: 1) != .text("jane@example.com") })
        #expect(results.last?.tableRows.value(at: 1, column: 1) == .text("a•••@example.com"))
    }

    @Test("Fetch All lands every row, masked the way the page it replaces is")
    func fetchAllMasksLikeTheHeldPage() async throws {
        let connection = fixture.connection
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in
            ScriptAnsweringDriver.resultSet(
                columns: ["id", "email"],
                rows: [["1", "jane@example.com"], ["2", "john@example.com"], ["3", "ann@example.com"]]
            )
        })
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let pageMasks = ColumnMasks(styles: [1: .full])
        let tab = fixture.addTab(
            QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query),
            rows: TableRows.from(queryRows: [Self.fetched[0]], columns: Self.columns, columnTypes: Self.types, masks: pageMasks)
        )

        fixture.coordinator.paginationCoordinator.performFetchAll(
            tabId: tab.id,
            baseQuery: "SELECT * FROM users",
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        )
        let handle = try #require(fixture.coordinator.queryTasks.task(for: tab.id))
        await handle.value

        let rows = fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id)
        let hidden = pageMasks.value(.text("jane@example.com"), column: 1)
        #expect(rows.rows.map { $0.id } == [.existing(0), .existing(1), .existing(2)])
        #expect(rows.rows.map { $0.values[0] } == [.text("1"), .text("2"), .text("3")])
        #expect(rows.rows.allSatisfy { $0.values[1] == hidden })
        #expect(rows.masks == pageMasks)
    }
}
