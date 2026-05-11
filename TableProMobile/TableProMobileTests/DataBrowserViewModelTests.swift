import Foundation
import Testing
import TableProDatabase
import TableProModels
import TableProQuery
@testable import TableProMobile

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
}
