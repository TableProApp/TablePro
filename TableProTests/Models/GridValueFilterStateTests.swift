//
//  GridValueFilterStateTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

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

    @Test("remap keeps a filter whose column stayed put")
    func remapKeepsUnmovedColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "status", forColumn: 1)

        let remapped = state.remapped(toColumns: ["id", "status"])

        #expect(remapped == state)
    }

    @Test("remap follows a column to its new position by name")
    func remapMovesShiftedColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["paid"], includesNull: true), columnName: "status", forColumn: 3)

        let remapped = state.remapped(toColumns: ["id", "customer", "status"])

        #expect(!remapped.isActive(column: 3))
        #expect(remapped.filter(forColumn: 2) == ColumnValueFilter(selectedValues: ["paid"], includesNull: true))
        #expect(remapped.columnName(forColumn: 2) == "status")
    }

    @Test("remap drops a filter whose column is gone")
    func remapDropsMissingColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["a"], includesNull: false), columnName: "note", forColumn: 2)

        #expect(!state.remapped(toColumns: ["id", "status"]).isActive)
    }

    @Test("remap drops a moved filter whose name now repeats")
    func remapDropsAmbiguousColumn() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["1"], includesNull: false), columnName: "id", forColumn: 2)

        #expect(!state.remapped(toColumns: ["id", "name", "total", "id"]).isActive)
    }

    @Test("remap never moves a filter onto a column another filter kept")
    func remapKeepsTheFilterAlreadyInPlace() {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: ["kept"], includesNull: false), columnName: "status", forColumn: 0)
        state.set(ColumnValueFilter(selectedValues: ["moved"], includesNull: false), columnName: "status", forColumn: 2)

        let remapped = state.remapped(toColumns: ["status", "name"])

        #expect(remapped.activeColumns == [0])
        #expect(remapped.filter(forColumn: 0)?.selectedValues == ["kept"])
    }

    @Test("hidesEverything reflects an empty selection")
    func hidesEverythingWhenNothingSelected() {
        #expect(ColumnValueFilter(selectedValues: [], includesNull: false).hidesEverything)
        #expect(!ColumnValueFilter(selectedValues: [], includesNull: true).hidesEverything)
        #expect(!ColumnValueFilter(selectedValues: ["a"], includesNull: false).hidesEverything)
    }
}
