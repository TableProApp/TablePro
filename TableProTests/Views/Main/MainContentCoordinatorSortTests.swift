//
//  MainContentCoordinatorSortTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator handleSortStateChanged", .serialized)
@MainActor
struct MainContentCoordinatorSortTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "Q1", query: "SELECT id, name, email FROM users", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager, tab.id)
    }

    private func seedRows(
        _ coordinator: MainContentCoordinator,
        for tabId: UUID,
        columns: [String] = ["id", "name", "email"],
        rowCount: Int = 5
    ) {
        let rows = (0..<rowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    private func sortState(_ columns: [(Int, SortDirection)]) -> SortState {
        var state = SortState()
        state.columns = columns.map { SortColumn(columnIndex: $0.0, direction: $0.1) }
        return state
    }

    @Test("Applying a single-column ascending state writes it to the tab")
    func appliesSingleColumnAscending() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(1, .ascending)]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending)
        ])
        #expect(tabManager.tabs[idx].hasUserInteraction == true)
    }

    @Test("Applying a different state replaces the previous one")
    func replacesPreviousState() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        coordinator.handleSortStateChanged(sortState([(2, .descending)]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 2, direction: .descending)
        ])
    }

    @Test("Applying a multi-column state writes all columns in order")
    func appliesMultiColumnState() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([
            (0, .ascending),
            (2, .descending)
        ]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending),
            SortColumn(columnIndex: 2, direction: .descending)
        ])
    }

    @Test("Applying an empty state clears the sort")
    func emptyStateClearsSort() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        coordinator.handleSortStateChanged(SortState())

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    @Test("Applying the same state twice is a no-op")
    func sameStateIsNoOp() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        let state = sortState([(0, .ascending)])

        coordinator.handleSortStateChanged(state)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let firstInteractionTimestamp = tabManager.tabs[idx].hasUserInteraction
        coordinator.handleSortStateChanged(state)

        #expect(tabManager.tabs[idx].sortState.columns == state.columns)
        #expect(tabManager.tabs[idx].hasUserInteraction == firstInteractionTimestamp)
    }


    @Test("Sorting a paginated query result does not overwrite the editor query")
    func paginatedSortPreservesContentQuery() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        #expect(tabManager.tabs[idx].content.query == originalQuery)
    }

    @Test("Sorting a file-backed paginated query tab does not mark it dirty")
    func paginatedSortKeepsFileTabClean() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].content.sourceFileURL = URL(fileURLWithPath: "/tmp/query.sql")
        tabManager.tabs[idx].content.savedFileContent = originalQuery
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(sortState([(1, .descending)]))

        #expect(tabManager.tabs[idx].content.query == originalQuery)
        #expect(tabManager.tabs[idx].content.isFileDirty == false)
    }

    @Test("Clearing sort on a paginated query tab keeps the editor query intact")
    func clearingSortPaginatedPreservesContentQuery() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].sortState = sortState([(0, .ascending)])
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(SortState())

        #expect(tabManager.tabs[idx].content.query == originalQuery)
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    /// A SQL Server batch can return a result no single statement stands behind. Re-sorting it on the server would
    /// mean re-sending the whole script with `ORDER BY` on the end, writes included, so it is ordered in place.
    @Test("A result with no query to run again is sorted in place, never by re-running the editor text")
    func resultWithoutReplayableQuerySortsInPlace() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        let script = "INSERT INTO audit_log (msg) VALUES ('x');\nSELECT msg FROM audit_log"
        let rows = TableRows.from(
            queryRows: [["b"], ["c"], ["a"]].map { row in row.map(PluginCellValue.fromOptional) },
            columns: ["msg"],
            columnTypes: [.text(rawType: nil)]
        )
        let idx = try #require(tabManager.tabs.firstIndex(where: { $0.id == tabId }))
        tabManager.tabs[idx].content.query = script
        let batchResult = ResultSet(label: "Result 1", tableRows: rows)
        tabManager.mutate(at: idx) { $0.display.replaceUnpinnedResults(with: [batchResult]) }
        coordinator.setActiveTableRows(rows, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        #expect(tabManager.tabs[idx].content.query == script)
        #expect(tabManager.tabs[idx].sortState.columns == [SortColumn(columnIndex: 0, direction: .ascending)])
        let sorted = coordinator.tabSessionRegistry.tableRows(for: tabId).rows.map { $0[0].asText }
        #expect(sorted == ["a", "b", "c"])

        coordinator.handleSortStateChanged(SortState())

        let restored = coordinator.tabSessionRegistry.tableRows(for: tabId).rows.map { $0[0].asText }
        #expect(restored == ["b", "c", "a"])
    }

    // MARK: - Results produced with query parameters

    /// The sort used to re-run the whole editor text whenever the result carried bound values, so the INSERT ran a
    /// second time before the SELECT came back sorted.
    @Test("A parameterized result of a multi-statement run sorts by re-running its own statement alone")
    func parameterizedMultiStatementResultSortsByItsOwnStatement() async throws {
        let harness = try await ParameterizedRunHarness.running(
            query: "INSERT INTO audit (msg) VALUES (:m);\nSELECT id, msg FROM audit WHERE msg = :m",
            parameterValue: "hello"
        ) { coordinator in coordinator.runAllStatements() }
        defer { harness.tearDown() }
        #expect(harness.driver.sentSQL.contains { $0.hasPrefix("INSERT") })

        let sorted = try await harness.sort(byColumn: 1)

        #expect(sorted.map(\.sql).allSatisfy { !$0.contains("INSERT") })
        let rerun = try #require(ParameterizedRunHarness.onlyRerun(in: sorted))
        #expect(rerun.sql.hasPrefix("SELECT id, msg FROM audit WHERE msg = ? ORDER BY `msg` ASC"))
        #expect(rerun.parameters == ["hello"])
    }

    @Test("A parameterized statement run on its own from a multi-statement editor sorts by that statement alone")
    func parameterizedStatementAtCursorSortsByItsOwnStatement() async throws {
        let statement = "SELECT id, msg FROM audit WHERE msg = :m"
        let editorText = "DELETE FROM audit WHERE msg = :m;\n\(statement)"
        let harness = try await ParameterizedRunHarness.running(query: editorText, parameterValue: "hello") { coordinator in
            coordinator.runStatement(statement, sourceOffset: (editorText as NSString).range(of: statement).location)
        }
        defer { harness.tearDown() }
        #expect(harness.driver.sentSQL.allSatisfy { !$0.contains("DELETE") })

        let sorted = try await harness.sort(byColumn: 1)

        #expect(sorted.map(\.sql).allSatisfy { !$0.contains("DELETE") })
        let rerun = try #require(ParameterizedRunHarness.onlyRerun(in: sorted))
        #expect(rerun.sql.hasPrefix("SELECT id, msg FROM audit WHERE msg = ? ORDER BY `msg` ASC"))
        #expect(rerun.parameters == ["hello"])
    }

    /// A sort orders the rows the result already has, so a value typed into the panel after the run belongs to the
    /// next run, not to this one.
    @Test("Sorting a parameterized result binds the values it ran with, not the panel's current ones")
    func parameterizedSortBindsTheValuesTheResultRanWith() async throws {
        let harness = try await ParameterizedRunHarness.running(
            query: "SELECT id, msg FROM audit WHERE msg = :m",
            parameterValue: "hello"
        ) { coordinator in coordinator.runStatement("SELECT id, msg FROM audit WHERE msg = :m") }
        defer { harness.tearDown() }
        harness.tabManager.mutate(tabId: harness.tabId) {
            $0.content.queryParameters = [QueryParameter(name: "m", value: "typed later")]
        }

        let sorted = try await harness.sort(byColumn: 1)

        let rerun = try #require(ParameterizedRunHarness.onlyRerun(in: sorted))
        #expect(rerun.parameters == ["hello"])
    }

    /// The ORDER BY a sort replaces can hold a placeholder of its own. Rewriting the driver's positional form would
    /// drop that `?` and leave its value in the list, one more value than the statement has places for.
    @Test("A parameter in the statement's own ORDER BY leaves with that ORDER BY when the grid sorts")
    func parameterInReplacedOrderByIsNotBound() async throws {
        let statement = "SELECT id, msg FROM audit WHERE msg = :m ORDER BY CASE WHEN id = :pinned THEN 0 ELSE 1 END"
        let harness = try await ParameterizedRunHarness.running(
            query: statement,
            parameters: [QueryParameter(name: "m", value: "hello"), QueryParameter(name: "pinned", value: "2")]
        ) { coordinator in coordinator.runStatement(statement) }
        defer { harness.tearDown() }

        let sorted = try await harness.sort(byColumn: 1)

        let rerun = try #require(ParameterizedRunHarness.onlyRerun(in: sorted))
        #expect(rerun.sql.hasPrefix("SELECT id, msg FROM audit WHERE msg = ? ORDER BY `msg` ASC"))
        #expect(rerun.parameters == ["hello"])
    }

    /// A result stays on screen, headers and all, while the next run is in flight, and a re-run cannot start until
    /// that run ends. The click used to leave its re-run on the tab, and the next Run sent it in place of the
    /// statement at the caret, bound to the values of the result that was clicked rather than the panel's.
    @Test("A header click while the tab runs is dropped, and the next Run binds the panel's values", arguments: [
        InFlightRunEnding.stopped,
        InFlightRunEnding.settled
    ])
    func headerClickDuringRunLeavesNothingForTheNextRun(ending: InFlightRunEnding) async throws {
        let statement = "SELECT id, msg FROM audit WHERE msg = :m"
        let harness = try await ParameterizedRunHarness.running(query: statement, parameterValue: "hello") { coordinator in
            coordinator.runStatement(statement)
        }
        defer { harness.tearDown() }
        let alreadySent = harness.driver.sent.count
        let inFlight = harness.coordinator.beginTabExecution(for: harness.tabId).claim

        harness.coordinator.handleSortStateChanged(sortState([(1, .ascending)]))

        #expect(harness.driver.sent.count == alreadySent)
        let idx = try #require(harness.tabManager.tabs.firstIndex { $0.id == harness.tabId })
        #expect(harness.tabManager.tabs[idx].sortState.columns.isEmpty)
        ending.end(inFlight, in: harness.coordinator)
        harness.tabManager.mutate(tabId: harness.tabId) {
            $0.content.queryParameters = [QueryParameter(name: "m", value: "bye")]
        }

        let sent = try await harness.runAtCaret()

        let run = try #require(ParameterizedRunHarness.onlyRerun(in: sent))
        #expect(run.sql.hasPrefix("SELECT id, msg FROM audit WHERE msg = ?"))
        #expect(!run.sql.contains("ORDER BY"))
        #expect(run.parameters == ["bye"])
    }

    /// Fetch All clears the pagination copy of the query once every row is in, and the sort used to fall back from
    /// that copy to the whole editor text.
    @Test("After Fetch All, sorting a result re-runs its own statement alone", arguments: [
        "INSERT INTO audit (msg) VALUES ('x');\nSELECT id, msg FROM audit WHERE msg = 'hello'",
        "INSERT INTO audit (msg) VALUES (:m);\nSELECT id, msg FROM audit WHERE msg = :m"
    ])
    func sortAfterFetchAllRerunsItsOwnStatement(script: String) async throws {
        let harness = try await ParameterizedRunHarness.running(query: script, parameterValue: "hello") { coordinator in
            coordinator.runAllStatements()
        }
        defer { harness.tearDown() }
        try await harness.fetchAll()

        let sorted = try await harness.sort(byColumn: 1)

        #expect(sorted.map(\.sql).allSatisfy { !$0.contains("INSERT") })
        let rerun = try #require(ParameterizedRunHarness.onlyRerun(in: sorted))
        #expect(rerun.sql.contains("ORDER BY `msg` ASC"))
    }

    /// A positional `?` sent without its value binds NULL on SQLite and matches nothing, silently.
    @Test("A result holding positional values with no statement beside them is sorted in place")
    func positionalValuesWithoutTheirStatementSortInPlace() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        let rows = TableRows.from(
            queryRows: [["b"], ["c"], ["a"]].map { row in row.map(PluginCellValue.fromOptional) },
            columns: ["msg"],
            columnTypes: [.text(rawType: nil)]
        )
        let idx = try #require(tabManager.tabs.firstIndex(where: { $0.id == tabId }))
        let result = ResultSet(label: "audit", tableRows: rows)
        result.baseQuery = "SELECT msg FROM audit WHERE msg = ?"
        result.baseQueryParameterValues = ["hello"]
        tabManager.mutate(at: idx) { $0.display.replaceUnpinnedResults(with: [result]) }
        coordinator.setActiveTableRows(rows, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        let sorted = coordinator.tabSessionRegistry.tableRows(for: tabId).rows.map { $0[0].asText }
        #expect(sorted == ["a", "b", "c"])
    }

    @Test("Sort resets pagination on the active tab")
    func sortResetsPagination() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[idx].pagination.currentPage = 5
        tabManager.tabs[idx].pagination.currentOffset = 4_000

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        #expect(tabManager.tabs[idx].pagination.currentPage == 1)
        #expect(tabManager.tabs[idx].pagination.currentOffset == 0)
    }

    private func makeTableCoordinator(
        pageSize: Int,
        tableName: String = "users"
    ) -> (MainContentCoordinator, QueryTabManager, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: tableName, query: "SELECT * FROM \(tableName)", tabType: .table)
        tab.tableContext.tableName = tableName
        tab.pagination = PaginationState(totalRowCount: 100, pageSize: pageSize, currentPage: 1)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let columns = ["id", "name"]
        let rows = (0..<pageSize).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(
            queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)
        return (coordinator, tabManager, tab.id)
    }

    @Test("Table tab keeps the rows-per-page LIMIT through ascending, descending, and cleared sort")
    func tableTabSortPreservesPageSize() {
        let (coordinator, tabManager, tabId) = makeTableCoordinator(pageSize: 10)
        func query() -> String { tabManager.tabs.first { $0.id == tabId }?.content.query ?? "" }
        func pagination() -> PaginationState? { tabManager.tabs.first { $0.id == tabId }?.pagination }

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        #expect(query().contains("LIMIT 10 OFFSET 0"))
        #expect(query().localizedCaseInsensitiveContains("ORDER BY"))

        coordinator.handleSortStateChanged(sortState([(0, .descending)]))
        #expect(query().contains("LIMIT 10 OFFSET 0"))
        #expect(query().localizedCaseInsensitiveContains("ORDER BY"))

        coordinator.handleSortStateChanged(SortState())
        #expect(query().contains("LIMIT 10 OFFSET 0"))
        #expect(!query().localizedCaseInsensitiveContains("ORDER BY"))
        #expect(pagination()?.pageSize == 10)
        #expect(pagination()?.currentOffset == 0)
    }

    @Test("Sorting a table whose name contains a SQL keyword keeps the identifier intact")
    func tableTabSortDoesNotSplitKeywordTableName() {
        let (coordinator, tabManager, tabId) = makeTableCoordinator(pageSize: 10, tableName: "user_rate_limits")

        coordinator.handleSortStateChanged(sortState([(0, .descending)]))

        let sql = tabManager.tabs.first { $0.id == tabId }?.content.query ?? ""
        #expect(sql.contains("user_rate_limits"))
        #expect(!sql.contains("user_rate_ "))
        #expect(sql.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(sql.contains("LIMIT 10 OFFSET 0"))
    }
}

/// How a run in flight ends without applying a result of its own.
enum InFlightRunEnding: Sendable {
    /// Stop, or `Cmd+.`.
    case stopped
    /// A failure, or a result past the row cap, which ends the claim and leaves pagination as it was.
    case settled

    @MainActor
    func end(_ claim: TabExecutionClaim, in coordinator: MainContentCoordinator) {
        switch self {
        case .stopped:
            coordinator.stopExecution(for: claim.tabId)
        case .settled:
            _ = coordinator.tabExecution.settle(claim)
        }
    }
}

/// One statement as it reached the driver, with the values bound to it.
private struct SentStatement: Equatable {
    let sql: String
    let parameters: [String?]?
}

/// A query tab on a live session, holding the result of one parameterized run whose statements were all recorded.
@MainActor
private struct ParameterizedRunHarness {
    static let resultPrefix = "SELECT id, msg"

    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    let driver: StatementRecordingDriver
    let connection: DatabaseConnection
    let tabId: UUID

    static func running(
        query: String,
        parameterValue: String,
        run: (MainContentCoordinator) -> Void
    ) async throws -> Self {
        try await running(query: query, parameters: [QueryParameter(name: "m", value: parameterValue)], run: run)
    }

    static func running(
        query: String,
        parameters: [QueryParameter],
        run: (MainContentCoordinator) -> Void
    ) async throws -> Self {
        let connection = TestFixtures.makeConnection()
        let driver = StatementRecordingDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "Query", query: query, tabType: .query)
        tab.content.queryParameters = parameters
        tab.content.isParameterPanelVisible = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let harness = Self(
            coordinator: coordinator,
            tabManager: tabManager,
            driver: driver,
            connection: connection,
            tabId: tab.id
        )
        run(coordinator)
        try await harness.waitUntilIdle {
            coordinator.tabSessionRegistry.tableRows(for: tab.id).columns == ["id", "msg"]
        }
        return harness
    }

    /// The one statement that re-ran the result. Anything else a click sends, such as a row count, is not a re-run.
    static func onlyRerun(in statements: [SentStatement]) -> SentStatement? {
        let reruns = statements.filter { $0.sql.hasPrefix(resultPrefix) }
        return reruns.count == 1 ? reruns.first : nil
    }

    /// Clicks the column's header once and returns every statement the click sent.
    func sort(byColumn column: Int) async throws -> [SentStatement] {
        let alreadySent = driver.sent.count
        var state = SortState()
        state.columns = [SortColumn(columnIndex: column, direction: .ascending)]
        coordinator.handleSortStateChanged(state)
        try await waitUntilIdle {
            driver.sent.dropFirst(alreadySent).contains { $0.sql.hasPrefix(Self.resultPrefix) }
        }
        return Array(driver.sent.dropFirst(alreadySent))
    }

    /// Presses Run with the caret where it is and returns every statement the run sent.
    func runAtCaret() async throws -> [SentStatement] {
        let alreadySent = driver.sent.count
        coordinator.runQuery(viewport: .firstRow)
        try await waitUntilIdle {
            driver.sent.dropFirst(alreadySent).contains { $0.sql.hasPrefix(Self.resultPrefix) }
        }
        return Array(driver.sent.dropFirst(alreadySent))
    }

    /// Fetches every row of the result on screen, the way the Fetch All button does once the user confirms.
    func fetchAll() async throws {
        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        let baseQuery = try #require(tab.pagination.baseQueryForMore)
        let alreadySent = driver.sent.count
        coordinator.paginationCoordinator.performFetchAll(
            tabId: tabId,
            baseQuery: baseQuery,
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        )
        try await waitUntilIdle {
            driver.sent.count > alreadySent
                && tabManager.tabs.first { $0.id == tabId }?.pagination.isLoadingMore == false
        }
    }

    func tearDown() {
        coordinator.cancelAllQueryTasks()
        coordinator.teardown()
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func waitUntilIdle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition(), !coordinator.tabExecution.isExecuting(tabId) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The run never settled. Sent: \(driver.sent.map(\.sql))")
    }
}

/// Records every statement it is asked to run and answers a SELECT with two rows.
private final class StatementRecordingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var statements: [SentStatement] = []

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var sent: [SentStatement] {
        lock.withLock { statements }
    }

    var sentSQL: [String] {
        sent.map(\.sql)
    }

    private func record(_ query: String, parameters: [Any?]?) -> QueryResult {
        let bound = parameters.map { values in values.map { $0 as? String } }
        lock.withLock { statements.append(SentStatement(sql: query, parameters: bound)) }
        guard query.uppercased().hasPrefix("SELECT") else {
            return QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 1, executionTime: 0, error: nil)
        }
        return QueryResult(
            columns: ["id", "msg"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            rows: [["2", "hello"], ["1", "hello"]].map { row in row.map(PluginCellValue.fromOptional) },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    func execute(query: String) async throws -> QueryResult { record(query, parameters: nil) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        record(query, parameters: parameters)
    }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        record(query, parameters: parameters)
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}
