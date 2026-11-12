//
//  PluginKeyedChangesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct PluginKeyedChangesTests {
    @Test("Every change gets its own key, and the key agrees across the changes and the sets")
    func keysAgreeAcrossCollections() {
        let insertedA = RowID.inserted(UUID())
        let insertedB = RowID.inserted(UUID())
        let changes = [
            RowChange(rowID: .existing(40), type: .delete, originalRow: ["40"]),
            RowChange(rowID: insertedA, type: .insert),
            RowChange(rowID: .existing(7), type: .update, originalRow: ["7"]),
            RowChange(rowID: insertedB, type: .insert)
        ]

        let keyed = PluginKeyedChanges(
            changes: changes,
            insertedRowData: [insertedA: ["a"], insertedB: ["b"]],
            deletedRowIDs: [.existing(40)],
            insertedRowIDs: [insertedA, insertedB]
        )

        let keys = keyed.changes.map(\.rowIndex)
        #expect(Set(keys).count == 4)
        #expect(keyed.deletedRowIndices == [keys[0]])
        #expect(keyed.insertedRowIndices == [keys[1], keys[3]])
        #expect(keyed.insertedRowData[keys[1]] == ["a"])
        #expect(keyed.insertedRowData[keys[3]] == ["b"])
        #expect(keyed.insertedRowData[keys[2]] == nil)
    }

    /// `PendingChanges` swap-removes a cancelled change, so the array stops matching edit order. A delete
    /// followed by a new row on the same key only saves in that order, so a plugin is handed the changes by
    /// sequence, the way the host's own generator reads them.
    @Test("A plugin receives the changes in the order they were made, not array order")
    func changesArriveInEditOrder() {
        let replacement = RowID.inserted(UUID())
        let changes = [
            RowChange(rowID: replacement, type: .insert, sequence: 5),
            RowChange(rowID: .existing(3), type: .update, originalRow: ["3"], sequence: 2),
            RowChange(rowID: .existing(9), type: .delete, originalRow: ["9"], sequence: 1)
        ]

        let keyed = PluginKeyedChanges(
            changes: changes,
            insertedRowData: [replacement: ["9"]],
            deletedRowIDs: [.existing(9)],
            insertedRowIDs: [replacement]
        )

        #expect(keyed.changes.map(\.type) == [.delete, .update, .insert])
        #expect(keyed.rowIDs == [.existing(9), .existing(3), replacement])
    }

    @Test("A row marked in a set but carried by no change is left out")
    func rowsWithoutAChangeAreDropped() {
        let orphan = RowID.inserted(UUID())
        let keyed = PluginKeyedChanges(
            changes: [RowChange(rowID: .existing(1), type: .delete, originalRow: ["1"])],
            insertedRowData: [orphan: ["x"]],
            deletedRowIDs: [.existing(1), .existing(2)],
            insertedRowIDs: [orphan]
        )

        #expect(keyed.changes.count == 1)
        #expect(keyed.deletedRowIndices.count == 1)
        #expect(keyed.insertedRowIndices.isEmpty)
        #expect(keyed.insertedRowData.isEmpty)
    }

    @Test("The change keeps its type, cells and original row across the boundary")
    func changeContentCrossesUnchanged() {
        let change = RowChange(
            rowID: .existing(3),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: ["3", "a"]
        )

        let keyed = PluginKeyedChanges(changes: [change], insertedRowData: [:], deletedRowIDs: [], insertedRowIDs: [])

        let crossed = keyed.changes.first
        #expect(crossed?.type == .update)
        #expect(crossed?.cellChanges.first?.columnName == "name")
        #expect(crossed?.cellChanges.first?.newValue == "b")
        #expect(crossed?.originalRow == ["3", "a"])
    }

    @MainActor
    @Test("A row edited around another change reaches the driver once per edit, each with the row as it then stands")
    func aRowEditedAroundAnotherChangeReachesTheDriverTwice() throws {
        let handed = HandedChanges()
        let driver = RowWriteStubDriver { changes, _, _, _ in
            handed.changes = changes
            return changes.map { PluginRowWrite(statement: "write(\($0.rowIndex))", rowIndices: [$0.rowIndex]) }
        }
        let (manager, _) = EditAroundADelete.manager(table: "items", databaseType: DatabaseType(rawValue: "MongoDB"))
        manager.pluginDriver = driver
        EditAroundADelete.record(on: manager)

        _ = try manager.generateSQL()
        let types = handed.changes.map { $0.type }
        let keys = Set(handed.changes.map { $0.rowIndex })
        let laterColumns = handed.changes.last?.cellChanges.map { $0.columnName }

        #expect(types == [.update, .delete, .update])
        #expect(keys.count == 3)
        #expect(handed.changes.last?.originalRow == ["3", "Cyd", "c@test.com"])
        #expect(laterColumns == ["email"])
    }
}

private final class HandedChanges {
    var changes: [PluginRowChange] = []
}
