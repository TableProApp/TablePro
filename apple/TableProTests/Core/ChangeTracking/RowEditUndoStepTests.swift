//
//  RowEditUndoStepTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowEditUndoStepTests {
    private static let columns = ["code", "status"]

    private func makeManager() -> (DataChangeManager, UndoManager) {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        manager.configureForTable(
            tableName: "tickets",
            columns: Self.columns,
            primaryKeyColumns: ["code"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return (manager, undoManager)
    }

    @Test("Undoing a cell typed back to its value stages the row as it was read")
    func undoAfterTypingBackKeepsTheRowAsRead() throws {
        let (manager, undoManager) = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "status",
            oldValue: "open", newValue: "closed", originalRow: ["A1", "open"]
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "status",
            oldValue: "closed", newValue: "open", originalRow: ["A1", "closed"]
        )
        #expect(manager.pendingUpdate(forRow: .existing(0)) == nil)

        undoManager.undo()

        let update = try #require(manager.pendingUpdate(forRow: .existing(0)))
        #expect(update.originalRow == ["A1", "open"])
        #expect(update.cellChanges.first?.newValue == "closed")
    }

    @Test("Undoing a key typed back keys the UPDATE on the key as read")
    func undoAfterTypingTheKeyBackKeysOnTheReadKey() throws {
        let (manager, undoManager) = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 0, columnName: "code",
            oldValue: "A1", newValue: "A2", originalRow: ["A1", "open"]
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 0, columnName: "code",
            oldValue: "A2", newValue: "A1", originalRow: ["A2", "open"]
        )

        undoManager.undo()

        let update = try #require(manager.pendingUpdate(forRow: .existing(0)))
        #expect(update.originalRow == ["A1", "open"])
        let statement = try #require(try manager.generateSQL().first)
        let parameters = statement.parameters.compactMap { $0 as? String }
        #expect(parameters == ["A2", "A1"])
    }

    @Test("Undo Delete from the row menu is its own step, so Undo deletes the row again and then restores it")
    func restoringADeletedRowIsUndoable() {
        let (manager, undoManager) = makeManager()
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["A1", "open"])

        manager.restoreDeletedRows([.existing(0)])
        #expect(!manager.isRowDeleted(.existing(0)))
        #expect(undoManager.undoActionName == String(localized: "Restore Row"))

        undoManager.undo()
        #expect(manager.isRowDeleted(.existing(0)))
        #expect(undoManager.redoActionName == String(localized: "Restore Row"))
        #expect(undoManager.undoActionName == String(localized: "Delete Row"))

        undoManager.undo()
        #expect(!manager.isRowDeleted(.existing(0)))
        #expect(!undoManager.canUndo)
        #expect(!manager.hasChanges)

        undoManager.redo()
        #expect(manager.isRowDeleted(.existing(0)))
        undoManager.redo()
        #expect(!manager.isRowDeleted(.existing(0)))
    }

    @Test("Restoring several deleted rows is one step over all of them")
    func restoringSeveralRowsIsOneStep() {
        let (manager, undoManager) = makeManager()
        manager.recordBatchRowDeletion(rows: [
            (rowID: .existing(0), originalRow: ["A1", "open"]),
            (rowID: .existing(1), originalRow: ["A2", "open"]),
        ])

        manager.restoreDeletedRows([.existing(0), .existing(1)])
        #expect(manager.deletedRowIDs.isEmpty)
        #expect(undoManager.undoActionName == String(localized: "Restore Rows"))

        undoManager.undo()
        #expect(manager.deletedRowIDs == [.existing(0), .existing(1)])

        undoManager.undo()
        #expect(manager.deletedRowIDs.isEmpty)
        #expect(!undoManager.canUndo)
    }
}
