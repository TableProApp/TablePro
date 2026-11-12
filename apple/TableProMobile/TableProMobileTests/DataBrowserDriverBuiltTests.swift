import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct DataBrowserDriverBuiltTests {
    private let columns = [
        ColumnInfo(name: "_id", typeName: "ObjectId", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
        ColumnInfo(name: "name", typeName: "String", ordinalPosition: 1),
        ColumnInfo(name: "photo", typeName: "BLOB", ordinalPosition: 2)
    ]

    private func browser(_ driver: MockQueryBuildingDriver) -> DataBrowserViewModel {
        driver.scriptedColumns = columns
        let viewModel = DataBrowserViewModel()
        viewModel.attach(
            session: ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "app", tables: []),
            table: TableInfo(name: "users"),
            databaseType: .mongodb,
            host: "db.example.com"
        )
        return viewModel
    }

    // A short page ends the table by itself, so only a full one asks for the count.
    private func fullPage(_ viewModel: DataBrowserViewModel) -> [[String?]] {
        Array(repeating: ["5f1d7f", "Ann", nil], count: viewModel.pagination.pageSize)
    }

    @Test("A driver that builds its own pages gets the page and the count, never SQL")
    func pageAndCountComeFromTheDriver() async throws {
        let driver = MockQueryBuildingDriver()
        driver.scriptedCount = 420
        let viewModel = browser(driver)
        driver.scriptedRows = fullPage(viewModel)

        await viewModel.load(isInitial: true)

        let page = try #require(driver.pageRequests.first)
        #expect(driver.executedQueries == ["PAGE \(viewModel.pagination.pageSize) 0"])
        #expect(page.request.table == "users")
        #expect(page.request.searchText == nil)
        #expect(driver.countRequests.count == 1)
        #expect(viewModel.pagination.totalRows == 420)
        #expect(viewModel.window.shownValues.count == viewModel.pagination.pageSize)
    }

    @Test("A page turn while the count runs keeps that count instead of starting another")
    func pageTurnKeepsTheRunningCount() async {
        let driver = MockQueryBuildingDriver()
        driver.scriptedCount = 5_000
        let counting = TestGate()
        driver.beforeCount = { await counting.enter() }
        let viewModel = browser(driver)
        driver.scriptedRows = fullPage(viewModel)

        let firstLoad = Task { await viewModel.load(isInitial: true) }
        await counting.waitUntilEntered()
        #expect(viewModel.isLoading == false)
        await viewModel.goToNextPage()
        #expect(viewModel.pagination.currentPage == 1)
        #expect(driver.countRequests.count == 1)

        await counting.open()
        await firstLoad.value
        #expect(viewModel.pagination.totalRows == 5_000)
        #expect(driver.countRequests.count == 1)
    }

    @Test("A page past the last row keeps the pager and sets no total, and the count still lands")
    func pagePastTheEndSetsNoTotal() async {
        let driver = MockQueryBuildingDriver()
        let counting = TestGate()
        driver.beforeCount = { await counting.enter() }
        let viewModel = browser(driver)
        let pageSize = viewModel.pagination.pageSize
        driver.scriptedCount = pageSize
        driver.scriptedRows = fullPage(viewModel)

        let firstLoad = Task { await viewModel.load(isInitial: true) }
        await counting.waitUntilEntered()
        driver.scriptedRows = []
        await viewModel.goToNextPage()

        #expect(viewModel.isPastTheEnd)
        #expect(viewModel.pagination.totalRows == nil)
        #expect(viewModel.showsPaginationBar)
        #expect(viewModel.canGoToPreviousPage)
        #expect(!viewModel.canGoToNextPage)

        await counting.open()
        await firstLoad.value
        #expect(viewModel.pagination.totalRows == pageSize)
    }

    @Test("Search and the enabled filters reach the driver; binary columns are not searched")
    func searchAndFiltersReachTheDriver() async throws {
        let driver = MockQueryBuildingDriver()
        let viewModel = browser(driver)
        driver.scriptedRows = fullPage(viewModel)
        await viewModel.load(isInitial: true)
        viewModel.filters = [
            TableFilter(columnName: "name", filterOperator: .equal, value: "Ann"),
            TableFilter(columnName: "name", filterOperator: .equal, value: "Bob", isEnabled: false)
        ]

        await viewModel.applySearch("an")

        let page = try #require(driver.pageRequests.last)
        #expect(page.request.searchText == "an")
        #expect(page.request.searchColumns == ["_id", "name"])
        #expect(page.request.filters.map { $0.value } == ["Ann"])
        #expect(driver.countRequests.last?.searchText == "an")
    }

    @Test("A cut-off value is read whole through the driver's own lookup by key and the row's locator")
    func fullValueComesFromTheDriver() async throws {
        let driver = MockQueryBuildingDriver()
        driver.scriptedValues = [.success("{\"a\": 1}")]
        let viewModel = browser(driver)
        let ref = CellRef(
            table: "users", column: "profile", primaryKey: [PrimaryKeyComponent(column: "_id", value: "5f1d7f")],
            locator: #"{"$oid":"5f1d7f"}"#
        )

        let value = try await viewModel.loadFullValue(driver: driver, ref: ref, databaseType: .mongodb, schema: nil)

        #expect(value == "{\"a\": 1}")
        let lookup = try #require(driver.lookups.first)
        #expect(lookup.column == "profile")
        #expect(lookup.key.map { $0.value } == ["5f1d7f"])
        #expect(lookup.locator == #"{"$oid":"5f1d7f"}"#)
        #expect(driver.executedQueries.isEmpty)
    }
}
