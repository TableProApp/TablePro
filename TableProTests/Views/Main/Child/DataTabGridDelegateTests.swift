//
//  DataTabGridDelegateTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing
@testable import TablePro

@MainActor
private final class FakeTableViewCoordinator: TableViewCoordinating {
    var insertedCalls: [IndexSet] = []
    var removedCalls: [IndexSet] = []
    var fullReplaceCount: Int = 0
    var invalidateCount: Int = 0
    var deltaCalls: [Delta] = []
    var commitEditCount: Int = 0

    func applyInsertedRows(_ indices: IndexSet) {
        insertedCalls.append(indices)
    }

    func applyRemovedRows(_ indices: IndexSet) {
        removedCalls.append(indices)
    }

    func applyFullReplace() {
        fullReplaceCount += 1
    }

    func invalidateCachesForUndoRedo() {
        invalidateCount += 1
    }

    func applyDelta(_ delta: Delta) {
        deltaCalls.append(delta)
    }

    func commitActiveCellEdit() {
        commitEditCount += 1
    }

    var beginEditingCalls: [(row: Int, column: Int)] = []

    func beginEditing(displayRow: Int, column: Int) {
        beginEditingCalls.append((row: displayRow, column: column))
    }
}

@Suite("DataTabGridDelegate row-delta forwarding")
@MainActor
struct DataTabGridDelegateTests {

    @Test("dataGridDidInsertRows(at:) forwards the IndexSet to applyInsertedRows")
    func insertForwardsIndices() {
        let delegate = DataTabGridDelegate()
        let applier = FakeTableViewCoordinator()
        delegate.tableViewCoordinator = applier

        let indices = IndexSet([1, 3, 5])
        delegate.dataGridDidInsertRows(at: indices)

        #expect(applier.insertedCalls.count == 1)
        #expect(applier.insertedCalls.first == indices)
        #expect(applier.removedCalls.isEmpty)
        #expect(applier.fullReplaceCount == 0)
    }

    @Test("dataGridDidRemoveRows(at:) forwards the IndexSet to applyRemovedRows")
    func removeForwardsIndices() {
        let delegate = DataTabGridDelegate()
        let applier = FakeTableViewCoordinator()
        delegate.tableViewCoordinator = applier

        let indices = IndexSet(integersIn: 4..<7)
        delegate.dataGridDidRemoveRows(at: indices)

        #expect(applier.removedCalls.count == 1)
        #expect(applier.removedCalls.first == indices)
        #expect(applier.insertedCalls.isEmpty)
        #expect(applier.fullReplaceCount == 0)
    }

    @Test("dataGridDidReplaceAllRows() forwards to applyFullReplace")
    func fullReplaceForwards() {
        let delegate = DataTabGridDelegate()
        let applier = FakeTableViewCoordinator()
        delegate.tableViewCoordinator = applier

        delegate.dataGridDidReplaceAllRows()

        #expect(applier.fullReplaceCount == 1)
        #expect(applier.insertedCalls.isEmpty)
        #expect(applier.removedCalls.isEmpty)
    }

    @Test("Calls are no-ops when tableViewCoordinator is nil")
    func nilCoordinatorIsNoOp() {
        let delegate = DataTabGridDelegate()
        #expect(delegate.tableViewCoordinator == nil)

        delegate.dataGridDidInsertRows(at: IndexSet([0]))
        delegate.dataGridDidRemoveRows(at: IndexSet([0]))
        delegate.dataGridDidReplaceAllRows()
    }
}
