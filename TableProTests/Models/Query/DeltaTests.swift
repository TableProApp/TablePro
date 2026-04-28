//
//  DeltaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Delta")
struct DeltaTests {
    @Test("cellChanged equality matches on row and column")
    func cellChangedEquality() {
        let lhs = Delta.cellChanged(row: 1, column: 2)
        let rhs = Delta.cellChanged(row: 1, column: 2)
        let other = Delta.cellChanged(row: 2, column: 2)
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("cellsChanged equality matches on the underlying set")
    func cellsChangedEquality() {
        let lhs = Delta.cellsChanged([CellPosition(row: 0, column: 1), CellPosition(row: 2, column: 3)])
        let rhs = Delta.cellsChanged([CellPosition(row: 2, column: 3), CellPosition(row: 0, column: 1)])
        #expect(lhs == rhs)
    }

    @Test("rowsInserted equality matches on the underlying IndexSet")
    func rowsInsertedEquality() {
        let lhs = Delta.rowsInserted(IndexSet(0...2))
        let rhs = Delta.rowsInserted(IndexSet(0...2))
        let other = Delta.rowsInserted(IndexSet(0...3))
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("rowsRemoved equality matches on the underlying IndexSet")
    func rowsRemovedEquality() {
        let lhs = Delta.rowsRemoved(IndexSet([1, 3]))
        let rhs = Delta.rowsRemoved(IndexSet([1, 3]))
        let other = Delta.rowsRemoved(IndexSet([1, 4]))
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("columnsReplaced equals itself")
    func columnsReplacedEquality() {
        let lhs = Delta.columnsReplaced
        let rhs = Delta.columnsReplaced
        #expect(lhs == rhs)
    }

    @Test("fullReplace equals itself")
    func fullReplaceEquality() {
        let lhs = Delta.fullReplace
        let rhs = Delta.fullReplace
        #expect(lhs == rhs)
    }

    @Test("Delta.none is an empty cellsChanged set")
    func noneIsEmptyCellsChanged() {
        #expect(Delta.none == Delta.cellsChanged([]))
    }

    @Test("Distinct cases never compare equal")
    func distinctCasesAreUnequal() {
        let single = Delta.cellChanged(row: 0, column: 0)
        let many = Delta.cellsChanged([CellPosition(row: 0, column: 0)])
        let inserted = Delta.rowsInserted(IndexSet(integer: 0))
        let removed = Delta.rowsRemoved(IndexSet(integer: 0))
        #expect(single != many)
        #expect(single != inserted)
        #expect(many != removed)
        #expect(inserted != removed)
        #expect(Delta.columnsReplaced != Delta.fullReplace)
    }
}
