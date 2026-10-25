//
//  DataGridValueFilterTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Holds the work instead of running it, standing in for a reader who has not answered the alert yet.
@MainActor
private final class DeferringOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changeState: AnyChangeManager
    private(set) var askedCount = 0
    private var pending: (@MainActor () -> Void)?

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
        changeState = AnyChangeManager(DataChangeManager())
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool { false }

    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        askedCount += 1
        pending = apply
    }

    func confirm() {
        let work = pending
        pending = nil
        work?()
    }

    func discard() {
        pending = nil
    }
}

@MainActor
struct DataGridValueFilterTests {
    private static let statuses = TableRows(
        rows: [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
            Row(id: .existing(3), values: [.null, .text("d")]),
        ],
        columns: ["status", "name"],
        columnTypes: [.text(rawType: nil), .text(rawType: nil)]
    )

    private static func filter(
        _ values: Set<String>,
        includesNull: Bool = false,
        column: Int,
        named name: String,
        onto base: GridValueFilterState = GridValueFilterState()
    ) -> GridValueFilterState {
        var state = base
        state.set(ColumnValueFilter(selectedValues: values, includesNull: includesNull), columnName: name, forColumn: column)
        return state
    }

    private static let onlyActive = filter(["active"], column: 0, named: "status")

    private func makeModel(
        dataSource: any DataGridDataSource,
        actions: (any DataGridActions)?
    ) -> DataGridModel {
        let model = DataGridModel()
        model.dataSource = dataSource
        model.actions = actions
        model.reloadRows()
        return model
    }

    private func makeModel(_ owner: GridTestOwner) -> DataGridModel {
        makeModel(dataSource: owner, actions: owner)
    }

    // MARK: - Narrowing

    @Test("A value filter narrows the rows shown and keeps them in storage order")
    func filterNarrowsRows() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)

        model.setValueFilter(Self.onlyActive)

        #expect(model.order.filteredIDs == [.existing(0), .existing(2)])
        #expect(model.rowCount == 2)
        #expect(model.rowID(at: 0) == .existing(0))
        #expect(model.rowID(at: 1) == .existing(2))
        #expect(model.order.storageIndex(at: 1, in: model.rows) == 2)
    }

    @Test("Both tables count the filtered rows")
    func tablesCountFilteredRows() {
        let grid = HostedDataGrid(rows: Self.statuses)
        defer { grid.close() }

        grid.model.setValueFilter(Self.onlyActive)

        #expect(grid.controller.numberOfRows(in: grid.main) == 2)
        #expect(grid.main.numberOfRows == 2)
        #expect(grid.frozen.numberOfRows == 2)
    }

    @Test("Filters on two columns intersect")
    func filtersIntersect() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)

        model.setValueFilter(Self.filter(["c"], column: 1, named: "name", onto: Self.onlyActive))

        #expect(model.order.filteredIDs == [.existing(2)])
        #expect(model.rowCount == 1)
    }

    @Test("Choosing NULL alone keeps only the NULL rows")
    func nullSelectionMatchesNullRows() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)

        model.setValueFilter(Self.filter([], includesNull: true, column: 0, named: "status"))

        #expect(model.order.filteredIDs == [.existing(3)])
    }

    @Test("Clearing one filter leaves the other narrowing the rows")
    func clearingOneFilterRecomputes() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)
        model.setValueFilter(Self.filter(["c"], column: 1, named: "name", onto: Self.onlyActive))

        var remaining = model.store.valueFilter
        remaining.clear(column: 1)
        model.setValueFilter(remaining)

        #expect(model.order.filteredIDs == [.existing(0), .existing(2)])
    }

    @Test("Clearing every filter shows every loaded row again")
    func clearingAllRestoresRows() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)
        model.setValueFilter(Self.onlyActive)

        model.setValueFilter(GridValueFilterState())

        #expect(!model.order.isFiltered)
        #expect(model.rowCount == 4)
    }

    @Test("A row added while a filter is on stays visible")
    func insertedRowsStayVisible() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)
        model.setValueFilter(Self.onlyActive)

        model.apply(owner.tableRows.appendInsertedRow(values: [.text("inactive"), .text("z")]))

        #expect(model.rowCount == 3)
        #expect(model.order.filteredIDs?.last?.isInserted == true)
    }

    // MARK: - New columns

    @Test("A result without the filtered column drops its filter")
    func reloadPrunesStaleFilters() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)
        model.setValueFilter(Self.onlyActive)

        owner.tableRows.columns = ["other", "name"]
        model.reloadRows()

        #expect(!model.store.valueFilter.isActive)
        #expect(!model.order.isFiltered)
        #expect(model.rowCount == 4)
    }

    @Test("A filter follows its column by name when the columns move, and a renamed column drops it")
    func filterFollowsColumnByName() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(owner)
        model.setValueFilter(Self.onlyActive)

        let swapped = Self.statuses.rows.map { Row(id: $0.id, values: [$0.values[1], $0.values[0]]) }
        owner.tableRows = TableRows(
            rows: ContiguousArray(swapped),
            columns: ["name", "status"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        model.reloadRows()

        #expect(model.store.valueFilter.isActive(column: 1))
        #expect(!model.store.valueFilter.isActive(column: 0))
        #expect(model.order.filteredIDs == [.existing(0), .existing(2)])

        owner.tableRows.columns = ["name", "state"]
        model.reloadRows()

        #expect(!model.store.valueFilter.isActive)
        #expect(model.rowCount == 4)
    }

    @Test("The inspector reads the model's formats only for the columns they were set on")
    func inspectorFormatsRequireMatchingColumns() throws {
        let owner = GridTestOwner(TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(Data(repeating: 0xAA, count: 16))])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BYTEA")]
        ))
        let model = makeModel(owner)
        let column = try #require(model.columns.column(at: 0))

        model.setDisplayFormat(.uuid, for: column)

        #expect(InspectorValueDisplayFormatResolver.activeFormats(from: model, matching: ["id"]) == [.uuid])
        #expect(InspectorValueDisplayFormatResolver.activeFormats(from: model, matching: ["payload"]) == nil)
        #expect(InspectorValueDisplayFormatResolver.activeFormats(from: nil, matching: ["id"]) == nil)
    }

    // MARK: - Confirming a change of order

    @Test("A grid with no owner applies its filter directly")
    func ownerlessGridAppliesImmediately() {
        let owner = GridTestOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: nil)

        model.setValueFilter(Self.onlyActive)

        #expect(model.store.valueFilter.isActive)
        #expect(model.rowCount == 2)
    }

    @Test("A grid with an owner asks before it narrows anything")
    func ownedGridAsksFirst() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)

        model.setValueFilter(Self.onlyActive)

        #expect(owner.askedCount == 1)
        #expect(!model.store.valueFilter.isActive)
        #expect(!model.order.isFiltered)
    }

    @Test("Approving the change applies the filter")
    func approvingApplies() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)
        model.setValueFilter(Self.onlyActive)

        owner.confirm()

        #expect(model.store.valueFilter.isActive)
        #expect(model.rowCount == 2)
    }

    @Test("Declining the change leaves the rows as they were")
    func decliningLeavesRowsAlone() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)

        model.setValueFilter(Self.onlyActive)
        owner.discard()

        #expect(!model.store.valueFilter.isActive)
        #expect(model.rowCount == 4)
    }

    @Test("Clearing every filter asks as well")
    func clearingAsksFirst() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)
        model.setValueFilter(Self.onlyActive)
        owner.confirm()

        model.setValueFilter(GridValueFilterState())
        #expect(owner.askedCount == 2)
        #expect(model.store.valueFilter.isActive)

        owner.confirm()
        #expect(!model.store.valueFilter.isActive)
    }

    @Test("Applying the filter the grid already has asks nothing")
    func reapplyingTheSameFilterAsksNothing() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)
        model.setValueFilter(Self.onlyActive)
        owner.confirm()

        model.setValueFilter(Self.onlyActive)

        #expect(owner.askedCount == 1)
    }

    @Test("Clearing when nothing is filtered asks nothing")
    func clearingWithNoFilterAsksNothing() {
        let owner = DeferringOwner(Self.statuses)
        let model = makeModel(dataSource: owner, actions: owner)

        model.setValueFilter(GridValueFilterState())

        #expect(owner.askedCount == 0)
    }

    // MARK: - The popover

    // The confirmation is a sheet answered later, so the popover and its picks stay until the change lands.
    @Test("The popover closes only once its change is applied; declining the change leaves it open")
    func popoverClosesOnceTheFilterApplies() throws {
        let grid = HostedDataGrid(rows: Self.statuses)
        defer { grid.close() }
        let popover = EditingCloseCountingPopover()
        grid.controller.menuState.valueFilterPopover = popover
        let status = try #require(grid.model.columns.columns.first { $0.name == "status" })
        let onlyActive = ColumnValueFilter(selectedValues: ["active"], includesNull: false)

        grid.owner.approvesDisplayOrderChange = false
        #expect(grid.controller.applyValueFilter(onlyActive, to: status))
        #expect(grid.owner.displayOrderRequests == 1)
        #expect(popover.closeCount == 0)
        #expect(grid.controller.menuState.valueFilterPopover === popover)

        grid.owner.approvesDisplayOrderChange = true
        #expect(grid.controller.applyValueFilter(onlyActive, to: status))
        #expect(grid.model.rowCount == 2)
        #expect(popover.closeCount == 1)
        #expect(grid.controller.menuState.valueFilterPopover == nil)

        #expect(!grid.controller.applyValueFilter(onlyActive, to: status), "the same filter is no change")
        #expect(grid.owner.displayOrderRequests == 2)
    }

    @Test("Replacing the rows closes an open value filter, whose values were the old rows'")
    func replacingTheRowsClosesTheValueFilter() {
        let grid = HostedDataGrid(rows: Self.statuses)
        defer { grid.close() }
        let popover = EditingCloseCountingPopover()
        grid.controller.menuState.valueFilterPopover = popover

        grid.owner.tableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.text("archived"), .text("z")])],
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        grid.model.reloadRows()

        #expect(popover.closeCount == 1)
        #expect(grid.controller.menuState.valueFilterPopover == nil)
    }
}
