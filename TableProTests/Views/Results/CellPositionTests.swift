//
//  CellPositionTests.swift
//  TableProTests
//
//  Tests for CellPosition and RowVisualState value types.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("CellPosition")
struct CellPositionTests {
    @Test("Equal positions are equal")
    func equalPositionsAreEqual() {
        let a = CellPosition(row: 5, column: 3)
        let b = CellPosition(row: 5, column: 3)
        #expect(a == b)
    }

    @Test("Different row produces unequal positions")
    func differentRowUnequal() {
        let a = CellPosition(row: 0, column: 3)
        let b = CellPosition(row: 1, column: 3)
        #expect(a != b)
    }

    @Test("Different column produces unequal positions")
    func differentColumnUnequal() {
        let a = CellPosition(row: 5, column: 0)
        let b = CellPosition(row: 5, column: 1)
        #expect(a != b)
    }

    @Test("Both fields different produces unequal positions")
    func bothFieldsDifferent() {
        let a = CellPosition(row: 0, column: 0)
        let b = CellPosition(row: 1, column: 1)
        #expect(a != b)
    }

    @Test("Zero position stores correctly")
    func zeroPosition() {
        let pos = CellPosition(row: 0, column: 0)
        #expect(pos.row == 0)
        #expect(pos.column == 0)
    }

    @Test("Large indices stored correctly")
    func largeIndices() {
        let pos = CellPosition(row: 1_000_000, column: 500)
        #expect(pos.row == 1_000_000)
        #expect(pos.column == 500)
    }
}

@Suite("RowVisualState")
struct RowVisualStateTests {
    @Test("Empty state has all flags false and empty modifiedColumns")
    func emptyState() {
        let state = RowVisualState.empty
        #expect(state.isDeleted == false)
        #expect(state.isInserted == false)
        #expect(state.modifiedColumns.isEmpty)
    }

    @Test("Deleted state reports isDeleted true")
    func deletedState() {
        let state = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
        #expect(state.isDeleted == true)
        #expect(state.isInserted == false)
    }

    @Test("Inserted state reports isInserted true")
    func insertedState() {
        let state = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
        #expect(state.isInserted == true)
        #expect(state.isDeleted == false)
    }

    @Test("Modified columns tracks column indices correctly")
    func modifiedColumns() {
        let state = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [1, 3, 5])
        #expect(state.modifiedColumns.count == 3)
        #expect(state.modifiedColumns.contains(1))
        #expect(state.modifiedColumns.contains(3))
        #expect(state.modifiedColumns.contains(5))
        #expect(!state.modifiedColumns.contains(2))
    }
}
