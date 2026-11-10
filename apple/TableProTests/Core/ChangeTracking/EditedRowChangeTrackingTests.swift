//
//  EditedRowChangeTrackingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct EditedRowDeletionTests {
    private static let columns = ["code", "name"]

    private func makeManager() -> (DataChangeManager, UndoManager) {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        manager.configureForTable(
            tableName: "countries",
            columns: Self.columns,
            primaryKeyColumns: ["code"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return (manager, undoManager)
    }

    private func editCode(_ manager: DataChangeManager) {
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 0, columnName: "code",
            oldValue: "US", newValue: "UK", originalRow: ["US", "United States"]
        )
    }

    @Test("A delete of an edited row keys on the values the row was read with")
    func deleteUsesTheRowAsRead() throws {
        let (manager, _) = makeManager()
        editCode(manager)

        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["UK", "United States"])

        let delete = try #require(manager.changes.first { $0.type == .delete })
        #expect(delete.originalRow == ["US", "United States"])
        #expect(manager.changes.count == 1)

        let statements = try manager.generateSQL()
        #expect(statements.count == 1)
        let parameters = String(describing: statements.first?.parameters ?? [])
        #expect(parameters.contains("US"))
        #expect(!parameters.contains("UK"))
    }

    @Test("A batch delete reads each edited row's image the same way")
    func batchDeleteUsesTheRowsAsRead() {
        let (manager, _) = makeManager()
        editCode(manager)

        manager.recordBatchRowDeletion(rows: [
            (rowID: .existing(0), originalRow: ["UK", "United States"]),
            (rowID: .existing(1), originalRow: ["FR", "France"])
        ])

        let edited = manager.changes.first { $0.rowID == .existing(0) }
        let untouched = manager.changes.first { $0.rowID == .existing(1) }
        #expect(edited?.originalRow == ["US", "United States"])
        #expect(untouched?.originalRow == ["FR", "France"])
    }

    @Test("Undoing the delete brings the row's edit back")
    func undoingTheDeleteRestoresTheEdit() throws {
        let (manager, undoManager) = makeManager()
        editCode(manager)
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["UK", "United States"])
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 0))

        undoManager.undo()

        #expect(!manager.isRowDeleted(.existing(0)))
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 0))
        let update = try #require(manager.changes.first)
        #expect(manager.changes.count == 1)
        #expect(update.type == .update)
        #expect(update.cellChanges.first?.oldValue == "US")
        #expect(update.cellChanges.first?.newValue == "UK")

        undoManager.redo()

        #expect(manager.changes.count == 1)
        #expect(manager.changes.first?.type == .delete)
        #expect(manager.changes.first?.originalRow == ["US", "United States"])
    }

    @Test("A discard still knows the original of a cell edited before its row was deleted")
    func originalValuesCoverADeletedRowsEdits() {
        let (manager, _) = makeManager()
        editCode(manager)
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["UK", "United States"])

        let originals = manager.getOriginalValues()

        #expect(originals.count == 1)
        #expect(originals.first?.rowID == .existing(0))
        #expect(originals.first?.columnIndex == 0)
        #expect(originals.first?.value == "US")
    }

    @Test("A deleted row's parked edit survives a tab switch")
    func parkedEditSurvivesSaveAndRestore() {
        let (manager, _) = makeManager()
        editCode(manager)
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["UK", "United States"])
        let state = manager.saveState()

        let (restored, _) = makeManager()
        restored.restoreState(from: state, tableName: "countries", databaseType: .mysql, generatedColumns: [])
        restored.undoRowDeletion(rowID: .existing(0))

        #expect(restored.isCellModified(rowID: .existing(0), columnIndex: 0))
        #expect(restored.changes.first?.type == .update)
    }

    @Test("Deleting an edited row from the grid deletes the row the server holds")
    func gridDeleteOfAnEditedRow() throws {
        let (manager, _) = makeManager()
        let operations = RowOperationsManager(changeManager: manager)
        var tableRows = TableRows.from(
            queryRows: [["US", "United States"], ["UK", "United Kingdom"]],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count)
        )
        let rowID = tableRows.rows[0].id
        manager.recordCellChange(
            rowID: rowID, columnIndex: 0, columnName: "code",
            oldValue: "US", newValue: "UK", originalRow: Array(tableRows.rows[0].values)
        )
        _ = tableRows.edit(row: 0, column: 0, value: "UK", isAbsent: false)

        _ = operations.deleteRows([rowID], selectedDisplayIndices: [0], displayCount: 2, tableRows: &tableRows)

        let delete = try #require(manager.changes.first { $0.type == .delete })
        #expect(delete.originalRow == ["US", "United States"])
    }
}

@MainActor
struct SameRowCellRedoTests {
    @Test("Redoing one cell of a row that still has another pending edit records it again")
    func redoMergesIntoTheRowsUpdate() throws {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        let original: [PluginCellValue] = ["1", "Ann", "ann@old.com"]
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Ann", newValue: "Anna", originalRow: original
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "ann@old.com", newValue: "ann@new.com", originalRow: original
        )

        undoManager.undo()
        #expect(manager.getModifiedColumnsForRow(.existing(0)) == [1])

        undoManager.redo()

        #expect(manager.getModifiedColumnsForRow(.existing(0)) == [1, 2])
        let update = try #require(manager.changes.first)
        #expect(manager.changes.count == 1)
        let email = try #require(update.cellChanges.first { $0.columnIndex == 2 })
        #expect(email.oldValue == "ann@old.com")
        #expect(email.newValue == "ann@new.com")

        undoManager.undo()
        undoManager.undo()
        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }
}

@MainActor
struct UpdateSaveOrderTests {
    @Test("An edit made after two deletes is written after them")
    func updateKeepsItsPlaceAfterDeletes() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "a@test.com"])
        manager.recordRowInsertion(rowID: .inserted(UUID()), values: ["9", "new@test.com"])
        manager.recordRowDeletion(rowID: .existing(1), originalRow: ["2", "b@test.com"])
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "email",
            oldValue: "c@test.com", newValue: "b@test.com", originalRow: ["3", "c@test.com"]
        )

        let verbs = try manager.generateSQL().map { statement in String(statement.sql.prefix(while: { $0 != " " })) }

        #expect(verbs == ["DELETE", "INSERT", "DELETE", "UPDATE"])
    }

    @Test("An update gets its own sequence number, and gets a later one when a redo records it again")
    func updatesAreSequenced() throws {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "a"])
        pending.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "email",
            oldValue: "b", newValue: "a", originalRow: ["2", "b"]
        )
        let delete = try #require(pending.change(forRow: .existing(0), type: .delete))
        let update = try #require(pending.change(forRow: .existing(1), type: .update))
        #expect(update.sequence > delete.sequence)

        pending.reapplyCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "email",
            originalDBValue: "c", newValue: "d", originalRow: ["3", "c"]
        )
        let replayed = try #require(pending.change(forRow: .existing(2), type: .update))
        #expect(replayed.sequence > update.sequence)
    }

    @Test("An edit parked under a delete keeps its place in the order when the delete is undone")
    func parkedUpdateKeepsItsSequence() throws {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "email",
            oldValue: "a", newValue: "b", originalRow: ["1", "a"]
        )
        let sequence = try #require(pending.change(forRow: .existing(0), type: .update)).sequence
        pending.recordRowInsertion(rowID: .inserted(UUID()), values: ["9", "a"])
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "b"])

        _ = pending.undoRowDeletion(rowID: .existing(0))

        #expect(pending.change(forRow: .existing(0), type: .update)?.sequence == sequence)
        #expect(pending.isCellModified(rowID: .existing(0), columnIndex: 1))
    }
}
