//
//  GridValueFilterStateTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

@Suite("GridValueFilterState")
struct GridValueFilterStateTests {
    @Test("set marks a column active")
    func setMarksColumnActive() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 0)

        #expect(state.isActive)
        #expect(state.isActive(column: 0))
        #expect(state.activeColumnCount == 1)
        #expect(state.activeColumns == [0])
        #expect(state.filter(forColumn: 0)?.selectedValues == ["a"])
    }

    @Test("clear removes a single column")
    func clearRemovesColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 0)
        state.set(ColumnValueFilter(selectedValues: ["b"], includesNull: false), columnName: "name", forColumn: 1)

        state.clear(column: 0)

        #expect(!state.isActive(column: 0))
        #expect(state.isActive(column: 1))
        #expect(state.activeColumnCount == 1)
    }

    @Test("clearAll empties the state")
    func clearAllEmptiesState() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 0)
        state.set(ColumnValueFilter(selectedValues: ["b"], includesNull: false), columnName: "name", forColumn: 1)

        state.clearAll()

        #expect(!state.isActive)
        #expect(state.activeColumnCount == 0)
    }

    @Test("prune drops filters whose column name changed")
    func pruneDropsRenamedColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 0)
        state.set(ColumnValueFilter(selectedValues: ["b"], includesNull: false), columnName: "name", forColumn: 1)

        state.prune(againstColumns: ["status", "email"])

        #expect(state.isActive(column: 0))
        #expect(!state.isActive(column: 1))
    }

    @Test("prune drops filters past the column count")
    func pruneDropsOutOfRangeColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 2)

        state.prune(againstColumns: ["status", "name"])

        #expect(!state.isActive)
    }

    @Test("hidesEverything reflects an empty selection")
    func hidesEverythingWhenNothingSelected() {
        #expect(ColumnValueFilter(selectedValues: [], includesNull: false).hidesEverything)
        #expect(!ColumnValueFilter(selectedValues: [], includesNull: true).hidesEverything)
        #expect(!ColumnValueFilter(selectedValues: ["a"], includesNull: false).hidesEverything)
    }
}
