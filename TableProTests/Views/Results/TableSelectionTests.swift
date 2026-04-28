//
//  TableSelectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableSelection")
struct TableSelectionTests {
    @Test("Default selection is empty")
    func defaultIsEmpty() {
        let selection = TableSelection()
        #expect(selection.focusedRow == -1)
        #expect(selection.focusedColumn == -1)
        #expect(selection.anchor == -1)
        #expect(selection.pivot == -1)
        #expect(selection.hasFocus == false)
    }

    @Test("hasFocus requires both row and column")
    func hasFocusRequiresBoth() {
        var selection = TableSelection()
        selection.focusedRow = 5
        #expect(selection.hasFocus == false)
        selection.focusedColumn = 2
        #expect(selection.hasFocus == true)
        selection.focusedRow = -1
        #expect(selection.hasFocus == false)
    }

    @Test("clearFocus resets focus only")
    func clearFocusKeepsAnchor() {
        var selection = TableSelection()
        selection.setFocus(row: 5, column: 2)
        selection.resetAnchor(at: 5)
        selection.clearFocus()
        #expect(selection.focusedRow == -1)
        #expect(selection.focusedColumn == -1)
        #expect(selection.anchor == 5)
        #expect(selection.pivot == 5)
    }

    @Test("setFocus assigns row and column")
    func setFocus() {
        var selection = TableSelection()
        selection.setFocus(row: 7, column: 3)
        #expect(selection.focusedRow == 7)
        #expect(selection.focusedColumn == 3)
    }

    @Test("resetAnchor sets both anchor and pivot")
    func resetAnchor() {
        var selection = TableSelection()
        selection.resetAnchor(at: 4)
        #expect(selection.anchor == 4)
        #expect(selection.pivot == 4)
    }

    @Test("clearAnchor resets anchor and pivot")
    func clearAnchor() {
        var selection = TableSelection()
        selection.resetAnchor(at: 4)
        selection.clearAnchor()
        #expect(selection.anchor == -1)
        #expect(selection.pivot == -1)
    }

    @Test("Equatable compares all four fields")
    func equatable() {
        var a = TableSelection()
        a.setFocus(row: 1, column: 2)
        a.resetAnchor(at: 1)
        var b = a
        #expect(a == b)
        b.focusedRow = 2
        #expect(a != b)
    }
}

@Suite("TableSelection.reloadIndexes")
struct TableSelectionReloadIndexesTests {
    @Test("No change returns nil")
    func noChange() {
        var selection = TableSelection()
        selection.setFocus(row: 5, column: 2)
        let same = selection
        #expect(selection.reloadIndexes(from: same) == nil)
    }

    @Test("Anchor change without focus change returns nil")
    func anchorOnlyChange() {
        var previous = TableSelection()
        previous.setFocus(row: 5, column: 2)
        var current = previous
        current.resetAnchor(at: 8)
        #expect(current.reloadIndexes(from: previous) == nil)
    }

    @Test("Initial focus from empty includes new cell only")
    func initialFocus() {
        let previous = TableSelection()
        var current = previous
        current.setFocus(row: 3, column: 1)
        let result = current.reloadIndexes(from: previous)
        #expect(result?.rows == IndexSet([3]))
        #expect(result?.columns == IndexSet([1]))
    }

    @Test("Clearing focus includes old cell only")
    func clearFocusFromActive() {
        var previous = TableSelection()
        previous.setFocus(row: 3, column: 1)
        var current = previous
        current.clearFocus()
        let result = current.reloadIndexes(from: previous)
        #expect(result?.rows == IndexSet([3]))
        #expect(result?.columns == IndexSet([1]))
    }

    @Test("Row change at same column reloads both rows")
    func rowChange() {
        var previous = TableSelection()
        previous.setFocus(row: 3, column: 2)
        var current = previous
        current.focusedRow = 4
        let result = current.reloadIndexes(from: previous)
        #expect(result?.rows == IndexSet([3, 4]))
        #expect(result?.columns == IndexSet([2]))
    }

    @Test("Column change at same row reloads both columns")
    func columnChange() {
        var previous = TableSelection()
        previous.setFocus(row: 3, column: 2)
        var current = previous
        current.focusedColumn = 5
        let result = current.reloadIndexes(from: previous)
        #expect(result?.rows == IndexSet([3]))
        #expect(result?.columns == IndexSet([2, 5]))
    }

    @Test("Both change reloads both rows and both columns")
    func bothChange() {
        var previous = TableSelection()
        previous.setFocus(row: 3, column: 2)
        var current = previous
        current.setFocus(row: 7, column: 5)
        let result = current.reloadIndexes(from: previous)
        #expect(result?.rows == IndexSet([3, 7]))
        #expect(result?.columns == IndexSet([2, 5]))
    }

    @Test("Clearing focus from no-focus state returns nil")
    func clearFromEmpty() {
        let previous = TableSelection()
        let current = previous
        #expect(current.reloadIndexes(from: previous) == nil)
    }
}
