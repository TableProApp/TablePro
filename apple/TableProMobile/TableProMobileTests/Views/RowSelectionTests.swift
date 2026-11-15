import Foundation
import SwiftUI
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProQuery
import Testing

struct RowSelectionTests {
    @Test("Rows are picked only in Select mode, and leaving it drops them")
    func selectModeOwnsThePick() {
        var selection = RowSelection()
        selection.toggle(1)
        #expect(selection.rows.isEmpty)
        #expect(selection.editMode == .inactive)

        selection.begin()
        selection.toggle(1)
        selection.toggle(3)
        selection.toggle(1)
        #expect(selection.rows == [3])
        #expect(selection.editMode == .active)

        selection.end()
        #expect(selection.isActive == false)
        #expect(selection.rows.isEmpty)
    }

    @Test("Outside Select mode no row reads as picked and a row opens its detail; in it a tap picks the row")
    func pickStateFollowsSelectMode() {
        var selection = RowSelection()
        #expect(selection.pick(of: 0) == nil)
        #expect(selection.opensRowDetail)

        selection.begin()
        selection.toggle(0)
        #expect(selection.pick(of: 0) == true)
        #expect(selection.pick(of: 1) == false)
        #expect(selection.opensRowDetail == false)

        selection.end()
        #expect(selection.pick(of: 0) == nil)
        #expect(selection.opensRowDetail)
    }

    @Test("Select All picks every loaded row, and says so only while all are picked")
    func selectAll() {
        var selection = RowSelection()
        selection.begin()
        selection.selectAll(count: 4)
        #expect(selection.count == 4)
        #expect(selection.selectsAll(of: 4))

        selection.toggle(2)
        #expect(selection.selectsAll(of: 4) == false)
        #expect(selection.selectsAll(of: 0) == false)
    }

    @Test("The picked rows come back in page order, without rows the page no longer holds")
    func indicesWithinThePage() {
        var selection = RowSelection()
        selection.begin()
        selection.replace(with: [7, 2, 0, 12])
        #expect(selection.indices(within: 8) == [0, 2, 7])
    }
}

nonisolated enum PageChange: CaseIterable, Sendable {
    case nextPage
    case reload
    case filter
    case sort
    case search
    case memoryTrim
}

@MainActor
struct RowSelectionClearingTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
        ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
    ]

    private func page(_ viewModel: DataBrowserViewModel, from start: Int = 0) -> Result<QueryResult, Error> {
        let rows = (start..<start + viewModel.pagination.pageSize).map { [String($0), "name \($0)"] as [String?] }
        return .success(QueryResult(columns: columns, rows: rows, rowsAffected: 0, executionTime: 0))
    }

    private func browserWithEveryRowPicked() async -> (DataBrowserViewModel, MockDatabaseDriver) {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        let viewModel = DataBrowserViewModel()
        driver.scriptedExecuteResults = [
            page(viewModel),
            .success(QueryResult(columns: [], rows: [["5000"]], rowsAffected: 0, executionTime: 0))
        ]
        viewModel.attach(
            session: ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "test", tables: []),
            table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost"
        )
        await viewModel.load(isInitial: true)
        viewModel.selection.begin()
        viewModel.selection.selectAll(count: viewModel.window.count)
        return (viewModel, driver)
    }

    @Test("Anything that replaces the page clears the picked rows and stays in Select mode", arguments: PageChange.allCases)
    func pageChangeClearsThePick(_ change: PageChange) async {
        let (viewModel, driver) = await browserWithEveryRowPicked()
        #expect(viewModel.selection.count == viewModel.pagination.pageSize)

        driver.scriptedExecuteResults = [page(viewModel)]
        switch change {
        case .nextPage:
            await viewModel.goToNextPage()
        case .reload:
            await viewModel.load()
        case .filter:
            viewModel.filters = [TableFilter(columnName: "name", value: "name 1")]
            await viewModel.applyFilters()
        case .sort:
            viewModel.sortState.columns = [SortColumn(name: "name", ascending: false)]
            await viewModel.applySort()
        case .search:
            await viewModel.applySearch("name")
        case .memoryTrim:
            await viewModel.handlePressure(.warning)
        }

        #expect(viewModel.selection.rows.isEmpty)
        #expect(viewModel.selection.isActive)
    }

    @Test("A new run or a cleared query leaves Select mode in the query results")
    func queryResultsLeaveSelectMode() {
        let viewModel = QueryEditorViewModel()
        viewModel.selection.begin()
        viewModel.selection.selectAll(count: 3)

        viewModel.reset()
        #expect(viewModel.selection.isActive == false)
        #expect(viewModel.selection.rows.isEmpty)
    }
}
