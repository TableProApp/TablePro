//
//  GridDisplayOrderResolverTests.swift
//  TableProTests
//
//  The display order is a pure function of the rows, the value filter and the display formats, so
//  it resolves identically inside the grid and in the coordinator that answers without one.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("GridDisplayOrderResolver")
@MainActor
struct GridDisplayOrderResolverTests {
    private func makeTableRows() -> TableRows {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
            Row(id: .existing(3), values: [.null, .text("d")]),
        ]
        return TableRows(
            rows: rows,
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    private func filter(
        _ selectedValues: Set<String>,
        includesNull: Bool = false,
        columnName: String = "status",
        column: Int = 0
    ) -> GridValueFilterState {
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: selectedValues, includesNull: includesNull),
            columnName: columnName,
            forColumn: column
        )
        return state
    }

    private func resolve(
        tableRows: TableRows? = nil,
        valueFilter: GridValueFilterState,
        displayFormats: [ValueDisplayFormat?] = []
    ) -> [RowID]? {
        GridDisplayOrderResolver.resolve(
            tableRows: tableRows ?? makeTableRows(),
            valueFilter: valueFilter,
            displayFormats: displayFormats,
            databaseType: .postgresql
        )
    }

    @Test("an inactive filter leaves the display order as the storage order")
    func inactiveFilterResolvesToNil() {
        #expect(resolve(valueFilter: GridValueFilterState()) == nil)
    }

    @Test("an active filter narrows the rows and keeps storage order among the survivors")
    func activeFilterNarrowsAndPreservesOrder() {
        #expect(resolve(valueFilter: filter(["active"])) == [.existing(0), .existing(2)])
    }

    @Test("NULL passes only when the filter includes it")
    func nullPassesOnlyWhenIncluded() {
        #expect(resolve(valueFilter: filter([], includesNull: true)) == [.existing(3)])
        #expect(resolve(valueFilter: filter(["active"])) == [.existing(0), .existing(2)])
        #expect(resolve(valueFilter: filter(["active"], includesNull: true)) == [.existing(0), .existing(2), .existing(3)])
    }

    @Test("a row must satisfy every active column filter")
    func filtersCombineWithAnd() {
        var state = filter(["active"])
        state.set(
            ColumnValueFilter(selectedValues: ["c"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        #expect(resolve(valueFilter: state) == [.existing(2)])
    }

    @Test("a filter that matches nothing resolves to an empty order, not to nil")
    func filterHidingEverythingResolvesToEmpty() {
        #expect(resolve(valueFilter: filter(["nothing-matches-this"]))?.isEmpty == true)
    }

    @Test("a pending inserted row always passes, whatever the filter says")
    func insertedRowsAlwaysPass() {
        var rows = makeTableRows()
        _ = rows.appendInsertedRow(values: [.text("inactive"), .text("new")])
        #expect(resolve(tableRows: rows, valueFilter: filter(["active"]))?.last?.isInserted == true)
    }

    @Test("matching is done on the displayed value, so a display format changes what passes")
    func matchingFollowsTheDisplayFormat() {
        let rows = TableRows(
            rows: [Row(id: .existing(0), values: [.text("1700000000")])],
            columns: ["created"],
            columnTypes: [.integer(rawType: "BIGINT")]
        )
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: ["1700000000"], includesNull: false),
            columnName: "created",
            forColumn: 0
        )

        #expect(resolve(tableRows: rows, valueFilter: state) == [.existing(0)])
        #expect(resolve(tableRows: rows, valueFilter: state, displayFormats: [.unixTimestamp])?.isEmpty == true)
    }

    @Test("a filter whose column has moved is ignored rather than applied to the new column")
    func staleColumnFilterIsInert() {
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: ["active"], includesNull: false),
            columnName: "was-here-before",
            forColumn: 0
        )
        #expect(resolve(valueFilter: state) == nil)
    }

    @Test("a filter on a column index past the end is ignored")
    func outOfRangeColumnFilterIsInert() {
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: ["x"], includesNull: false),
            columnName: "extra",
            forColumn: 9
        )
        #expect(resolve(valueFilter: state) == nil)
    }
}
