import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProQuery
import Testing

@MainActor
@Suite("DataBrowserViewModel")
struct DataBrowserViewModelTests {
    private func makeSession(driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(
            connectionId: UUID(),
            driver: driver,
            activeDatabase: "test",
            tables: []
        )
    }

    private func makeColumns() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
    }

    @Test("load without session sets loadError")
    func loadWithoutSessionSetsError() async {
        let vm = DataBrowserViewModel()
        vm.attach(session: nil, table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.loadError != nil)
        #expect(vm.isLoading == false)
    }

    @Test("load with session populates columns and rows")
    func loadPopulates() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(
                columns: makeColumns(),
                rows: [["1", "Alice"], ["2", "Bob"]],
                rowsAffected: 0,
                executionTime: 0.01
            )),
            .success(QueryResult(columns: [], rows: [["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.columnDetails.count == 2)
        #expect(vm.hasPrimaryKeys == true)
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("hasActiveSearch reflects activeSearchText")
    func searchFlagsTrack() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        #expect(vm.hasActiveSearch == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.applySearch("alice")
        #expect(vm.hasActiveSearch == true)
        #expect(vm.activeSearchText == "alice")

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.clearSearch()
        #expect(vm.hasActiveSearch == false)
        #expect(vm.activeSearchText == "")
    }

    @Test("clearSearch with existing rows replaces them without leaving loading flags stuck")
    func clearSearchReplacesRowsCleanly() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)
        #expect(vm.legacyRows.count == 1)
        #expect(vm.isLoading == false)
        #expect(vm.isPageLoading == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"], ["2", "Bob"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["2"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.clearSearch()

        #expect(vm.isLoading == false)
        #expect(vm.isPageLoading == false)
        #expect(vm.legacyRows.count == 2)
    }

    @Test("pagination prev/next clamps at boundaries")
    func paginationClamps() async {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        #expect(vm.pagination.currentPage == 0)
        await vm.goToPreviousPage()
        #expect(vm.pagination.currentPage == 0, "previous on page 0 should not underflow")
    }

    @Test("The page range reads in the app's language")
    func pageRangeLabelIsLocalized() throws {
        #expect(DataBrowserViewModel.pageRangeLabel(start: 1, end: 100, total: 3_503) == "1-100 of 3503")

        let path = try #require(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vietnamese = try #require(Bundle(path: path))
        let label = DataBrowserViewModel.pageRangeLabel(start: 1, end: 100, total: 3_503, bundle: vietnamese)
        #expect(label == "1-100 trên 3503")
    }

    @Test("primaryKeyValues returns only PK columns from row")
    func primaryKeyExtraction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["42", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        let pks = vm.primaryKeyValues(for: ["42", "Alice"])
        #expect(pks.count == 1)
        #expect(pks.first?.column == "id")
        #expect(pks.first?.value == "42")
    }

    @Test("deleteRow returns true on success and runs DELETE SQL")
    func deleteSuccess() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(vm.operationError == nil)
        #expect(driver.executedQueries.contains(where: { $0.uppercased().hasPrefix("DELETE") }))
    }

    @Test("deleteRow returns false and sets operationError on driver failure")
    func deleteFailure() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == false)
        #expect(vm.operationError != nil)
    }

    @Test("deleteRow on an idle session opens a read-write transaction and commits it")
    func deleteWrapsIdleSession() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(driver.beganTransactionModes == [.readWrite])
        #expect(driver.didCommitTransaction)
    }

    @Test("a failed delete rolls the transaction back")
    func deleteFailureRollsBack() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == false)
        #expect(driver.didRollbackTransaction)
        #expect(!driver.didCommitTransaction)
    }

    @Test("deleteRow joins a transaction the session already holds")
    func deleteJoinsOpenTransaction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .explicitTransaction
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(!driver.didBeginTransaction)
        #expect(!driver.didCommitTransaction)
    }

    @Test("changePageSize resets currentPage and totalRows")
    func changePageSizeResets() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        await vm.changePageSize(50)
        #expect(vm.pagination.pageSize == 50)
        #expect(vm.pagination.currentPage == 0)
    }

    private func emptyResult() -> Result<QueryResult, Error> {
        .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0))
    }

    @Test("The page bar stays hidden for an empty table and shows once rows load")
    func pageBarFollowsRows() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        #expect(vm.showsPaginationBar == false)

        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)
        #expect(vm.showsPaginationBar == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.load(isInitial: true)
        #expect(vm.showsPaginationBar)
    }

    @Test("The page bar stays up when a search finds nothing, so the search can be paged back out of")
    func pageBarSurvivesEmptySearch() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [emptyResult()]
        await vm.applySearch("nobody")

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.showsPaginationBar)
    }

    @Test("The page bar stays up when an enabled filter matches nothing")
    func pageBarSurvivesEmptyFilter() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)

        vm.filters = [TableFilter(columnName: "name", value: "nobody")]
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.applyFilters()

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.showsPaginationBar)
    }

    @Test("Page steps are offered only where a page exists")
    func pageStepsFollowPosition() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        #expect(vm.canGoToPreviousPage == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"], ["2", "Bob"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["3"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.changePageSize(2)
        #expect(vm.pagination.totalRows == 3)
        #expect(vm.canGoToPreviousPage == false)
        #expect(vm.canGoToNextPage)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["3", "Carol"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.goToNextPage()
        #expect(vm.pagination.currentPage == 1)
        #expect(vm.canGoToPreviousPage)
        #expect(vm.canGoToNextPage == false)
    }

    private func keyPage(from start: Int, count: Int, total: Int) -> KeyContentsPage {
        let columns = [
            ColumnInfo(name: "index", typeName: "integer", ordinalPosition: 0),
            ColumnInfo(name: "element", typeName: "string", ordinalPosition: 1)
        ]
        let rows: [[String?]] = (start ..< start + count).map { [String($0), "e\($0)"] }
        return KeyContentsPage(
            result: QueryResult(columns: columns, rows: rows, rowsAffected: 0, executionTime: 0),
            totalCount: total
        )
    }

    @Test("a key browse sends no SQL and pages by offset")
    func keyBrowsePagesByOffset() async {
        let driver = MockKeyContentsDriver()
        let vm = DataBrowserViewModel()
        let pageSize = vm.pagination.pageSize
        driver.scriptedPages = [
            .success(keyPage(from: 0, count: pageSize, total: pageSize * 3)),
            .success(keyPage(from: pageSize, count: pageSize, total: pageSize * 3))
        ]
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "queue"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)
        await vm.goToNextPage()

        #expect(driver.pageRequests == [
            MockKeyContentsDriver.PageRequest(key: "queue", limit: pageSize, offset: 0),
            MockKeyContentsDriver.PageRequest(key: "queue", limit: pageSize, offset: pageSize)
        ])
        #expect(driver.executedQueries.isEmpty)
        #expect(driver.fetchColumnsCalls == 0)
        #expect(driver.fetchForeignKeysCalls == 0)
        #expect(vm.pagination.totalRows == pageSize * 3)
        #expect(vm.columnDetails.map(\.name) == ["index", "element"])
        #expect(vm.hasPrimaryKeys == false)
        #expect(vm.legacyRows.first == [String(pageSize), "e\(pageSize)"])
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("a key read overtaken by a newer one leaves the newer page on screen")
    func overtakenKeyReadIsDropped() async {
        let driver = MockKeyContentsDriver()
        let vm = DataBrowserViewModel()
        let pageSize = vm.pagination.pageSize
        driver.scriptedPages = [
            .success(keyPage(from: 0, count: pageSize, total: pageSize * 3)),
            .success(keyPage(from: pageSize, count: pageSize, total: pageSize * 3))
        ]
        driver.holdsFirstRequest = true
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "queue"), databaseType: .redis, host: "localhost")

        let overtaken = Task { await vm.load(isInitial: true) }
        while !driver.isHoldingRequest {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await vm.load()
        driver.releaseHeldRequest()
        await overtaken.value

        #expect(driver.pageRequests.count == 2)
        #expect(vm.legacyRows.first == [String(pageSize), "e\(pageSize)"])
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("a short key page with no count settles the total from what arrived")
    func shortKeyPageSettlesTotal() async {
        let driver = MockKeyContentsDriver()
        driver.scriptedPages = [
            .success(KeyContentsPage(
                result: QueryResult(
                    columns: [ColumnInfo(name: "member", typeName: "string", ordinalPosition: 0)],
                    rows: [["x"], ["y"]],
                    rowsAffected: 0,
                    executionTime: 0
                ),
                totalCount: nil
            ))
        ]
        let vm = DataBrowserViewModel()
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "tags"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.pagination.totalRows == 2)
        #expect(vm.canGoToNextPage == false)
    }

    @Test("a key that cannot be read shows the error instead of rows")
    func unreadableKeyShowsError() async {
        let driver = MockKeyContentsDriver()
        driver.scriptedPages = [.failure(RedisError.keyNotFound("gone"))]
        let vm = DataBrowserViewModel()
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "gone"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.loadError?.title == String(localized: "Key Not Found"))
        #expect(vm.legacyRows.isEmpty)
        #expect(vm.isLoading == false)
        #expect(driver.executedQueries.isEmpty)
    }
}
