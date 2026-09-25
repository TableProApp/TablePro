//
//  TableRowsSortingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableRowsSortingTests {
    private func makeRows() -> TableRows {
        var rows = TableRows(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
        rows.replace(rows: [
            [.text("10"), .text("beta")],
            [.text("2"), .text("alpha")],
            [.text("33"), .text("alpha")],
        ])
        return rows
    }

    @Test("An unsorted state returns the rows untouched")
    func noSortLeavesOrder() {
        let sorted = TableRowsSorting.sorted(makeRows(), by: SortState())
        #expect(sorted.rows.map { $0[0].sortKey } == ["10", "2", "33"])
    }

    @Test("An integer column orders numerically, not as text")
    func integerColumnOrdersNumerically() {
        let state = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user)
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        #expect(sorted.rows.map { $0[0].sortKey } == ["2", "10", "33"])
    }

    @Test("Descending reverses the same order")
    func descendingReverses() {
        let state = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        #expect(sorted.rows.map { $0[0].sortKey } == ["33", "10", "2"])
    }

    /// A tie falls back to the order the rows arrived in, so re-sorting the same column twice cannot
    /// shuffle rows the comparison calls equal.
    @Test("Ties keep the original order")
    func tiesAreStable() {
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .ascending)], source: .user)
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        #expect(sorted.rows.map { $0[0].sortKey } == ["2", "33", "10"])
    }

    @Test("A second column breaks the first one's ties")
    func secondColumnBreaksTies() {
        let state = SortState(
            columns: [
                SortColumn(columnIndex: 1, direction: .ascending),
                SortColumn(columnIndex: 0, direction: .descending),
            ],
            source: .user
        )
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        #expect(sorted.rows.map { $0[0].sortKey } == ["33", "2", "10"])
    }

    @Test("Reordering rebuilds the id index")
    func reorderRebuildsIndex() {
        let state = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user)
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        for (offset, row) in sorted.rows.enumerated() {
            #expect(sorted.index(of: row.id) == offset)
        }
    }

    @Test("A column index the result does not have is ignored")
    func outOfRangeColumnIsIgnored() {
        let state = SortState(columns: [SortColumn(columnIndex: 9, direction: .ascending)], source: .user)
        let sorted = TableRowsSorting.sorted(makeRows(), by: state)
        #expect(sorted.rows.map { $0[0].sortKey } == ["10", "2", "33"])
    }
}
