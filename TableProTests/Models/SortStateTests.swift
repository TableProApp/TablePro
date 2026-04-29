//
//  SortStateTests.swift
//  TableProTests
//
//  Tests for SortDirection, SortColumn, and SortState types.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SortDirection")
struct SortDirectionTests {
    @Test("Ascending equals ascending")
    func ascendingEquality() {
        #expect(SortDirection.ascending == SortDirection.ascending)
    }

    @Test("Descending equals descending")
    func descendingEquality() {
        #expect(SortDirection.descending == SortDirection.descending)
    }

    @Test("Ascending not equal to descending")
    func ascendingNotDescending() {
        #expect(SortDirection.ascending != SortDirection.descending)
    }

    @Test("Toggle ascending becomes descending")
    func toggleAscending() {
        var dir = SortDirection.ascending
        dir.toggle()
        #expect(dir == .descending)
    }

    @Test("Toggle descending becomes ascending")
    func toggleDescending() {
        var dir = SortDirection.descending
        dir.toggle()
        #expect(dir == .ascending)
    }

    @Test("Double toggle returns to original")
    func doubleToggle() {
        var dir = SortDirection.ascending
        dir.toggle()
        dir.toggle()
        #expect(dir == .ascending)
    }

}

@Suite("SortColumn")
struct SortColumnTests {
    @Test("Stores columnIndex and direction")
    func storesProperties() {
        let col = SortColumn(columnIndex: 2, direction: .descending)
        #expect(col.columnIndex == 2)
        #expect(col.direction == .descending)
    }

    @Test("Equal columns are equal")
    func equalColumns() {
        let a = SortColumn(columnIndex: 1, direction: .ascending)
        let b = SortColumn(columnIndex: 1, direction: .ascending)
        #expect(a == b)
    }

    @Test("Different index produces unequal columns")
    func differentIndex() {
        let a = SortColumn(columnIndex: 1, direction: .ascending)
        let b = SortColumn(columnIndex: 2, direction: .ascending)
        #expect(a != b)
    }

    @Test("Different direction produces unequal columns")
    func differentDirection() {
        let a = SortColumn(columnIndex: 1, direction: .ascending)
        let b = SortColumn(columnIndex: 1, direction: .descending)
        #expect(a != b)
    }

    @Test("Direction is mutable")
    func directionMutable() {
        var col = SortColumn(columnIndex: 0, direction: .ascending)
        col.direction = .descending
        #expect(col.direction == .descending)
    }
}

@Suite("SortState")
struct SortStateTests {
    @Test("Empty init has no columns")
    func emptyInit() {
        let state = SortState()
        #expect(state.columns.isEmpty)
    }

    @Test("Empty state is not sorting")
    func emptyNotSorting() {
        let state = SortState()
        #expect(state.isSorting == false)
    }

    @Test("Empty state columnIndex is nil")
    func emptyColumnIndex() {
        let state = SortState()
        #expect(state.columnIndex == nil)
    }

    @Test("Empty state direction defaults to ascending")
    func emptyDirectionDefault() {
        let state = SortState()
        #expect(state.direction == .ascending)
    }

    @Test("Single column makes isSorting true")
    func singleColumnSorting() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 3, direction: .descending)]
        #expect(state.isSorting == true)
    }

    @Test("Single column index returns first")
    func singleColumnIndex() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 3, direction: .descending)]
        #expect(state.columnIndex == 3)
    }

    @Test("Single column direction returns first")
    func singleColumnDirection() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 3, direction: .descending)]
        #expect(state.direction == .descending)
    }

    @Test("Multi-column returns first column index")
    func multiColumnIndex() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 2, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .descending)
        ]
        #expect(state.columnIndex == 2)
    }

    @Test("Multi-column returns first direction")
    func multiColumnDirection() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 2, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .descending)
        ]
        #expect(state.direction == .ascending)
    }

    @Test("Equal states are equal")
    func equalStates() {
        var a = SortState()
        a.columns = [SortColumn(columnIndex: 1, direction: .ascending)]
        var b = SortState()
        b.columns = [SortColumn(columnIndex: 1, direction: .ascending)]
        #expect(a == b)
    }
}
