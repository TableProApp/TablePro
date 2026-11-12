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

    @Test("A row edited again after another row's delete is written after that delete")
    func laterEditRunsAfterTheDeleteBeforeIt() throws {
        let (manager, _) = EditAroundADelete.manager()
        EditAroundADelete.record(on: manager)

        let statements = try manager.generateSQL()

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE", "UPDATE"])
        try #require(statements.count == 3)
        #expect(EditAroundADelete.strings(statements[0]) == ["Cyd", "3"])
        #expect(EditAroundADelete.strings(statements[1]) == ["2"])
        #expect(EditAroundADelete.strings(statements[2]) == ["b@test.com", "3"])
    }

    @Test("A swap through a temporary value saves each step in the order it was made")
    func swapThroughATemporaryValueSavesInOrder() throws {
        let (manager, _) = EditAroundADelete.manager()
        let rowA: [PluginCellValue] = ["1", "Al", "a@test.com"]
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "tmp", originalRow: rowA
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 2, columnName: "email",
            oldValue: "b@test.com", newValue: "a@test.com", originalRow: EditAroundADelete.rowB
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "tmp", newValue: "b@test.com", originalRow: ["1", "Al", "tmp"]
        )

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "UPDATE", "UPDATE"])
        #expect(bound == [["tmp", "1"], ["a@test.com", "2"], ["b@test.com", "1"]])
    }

    @Test("A later edit of a row keys on the key an earlier edit of it wrote")
    func laterRunKeysOnTheKeyTheEarlierRunWrote() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 0, columnName: "id",
            oldValue: "3", newValue: "6", originalRow: EditAroundADelete.rowC
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: ["6", "Cy", "c@test.com"]
        )

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE", "UPDATE"])
        #expect(bound == [["6", "3"], ["2"], ["Cyd", "6"]])
    }

    @Test("A tab switch keeps the place of every edit of a row, so a later change sorts after them")
    func aTabSwitchKeepsEveryRunsPlace() throws {
        let (manager, _) = EditAroundADelete.manager()
        EditAroundADelete.record(on: manager)
        let state = manager.saveState()

        manager.restoreState(from: state, tableName: "users", databaseType: .mysql, generatedColumns: [])
        manager.recordRowInsertion(rowID: .inserted(UUID()), values: ["9", "Di", "d@test.com"])
        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["UPDATE", "DELETE", "UPDATE", "INSERT"])
    }

    @Test("Undoing the delete of a row edited around another delete brings back both of its edits in place")
    func undoingADeleteBringsBackEveryRun() throws {
        let (manager, _) = EditAroundADelete.manager()
        EditAroundADelete.record(on: manager)
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Cyd", "b@test.com"])

        manager.undoRowDeletion(rowID: .existing(2))
        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["UPDATE", "DELETE", "UPDATE"])
    }

    @Test("Two edits of a row with nothing between them stay one UPDATE")
    func editsWithNothingBetweenStayOneUpdate() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: EditAroundADelete.rowC
        )
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 2, columnName: "email",
            oldValue: "c@test.com", newValue: "x@test.com", originalRow: ["3", "Cyd", "c@test.com"]
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE"])
        #expect(bound.first == ["Cyd", "x@test.com", "3"])
    }

    @Test("A cell typed back to its value as read is not written, whatever came between")
    func aCellTypedBackToItsValueAsReadIsNotWritten() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 2, columnName: "email",
            oldValue: "c@test.com", newValue: "x@test.com", originalRow: EditAroundADelete.rowC
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 2, columnName: "email",
            oldValue: "x@test.com", newValue: "c@test.com", originalRow: ["3", "Cy", "x@test.com"]
        )
        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["DELETE"])
    }

    @Test("Edits of a row around a change that was then cancelled are one UPDATE")
    func aChangeCancelledBetweenRunsLeavesOneUpdate() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: EditAroundADelete.rowC
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)
        manager.undoRowDeletion(rowID: .existing(1))
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 2, columnName: "email",
            oldValue: "c@test.com", newValue: "x@test.com", originalRow: ["3", "Cyd", "c@test.com"]
        )

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE"])
        #expect(bound == [["Cyd", "x@test.com", "3"]])
    }

    @Test("A row whose key an earlier edit set to SQL stays one UPDATE keyed on the key as read")
    func aKeySetToSQLBeforeAnotherChangeKeepsTheRowWhole() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 0, columnName: "id", oldValue: "3", newValue: "NOW()",
            originalRow: EditAroundADelete.rowC, absence: FieldAbsence(), isExpression: true
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: ["NOW()", "Cy", "c@test.com"]
        )

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE"])
        #expect(statements.first?.sql.contains("= NOW()") == true)
        #expect(bound.first == ["Cyd", "3"])
    }

    @Test("A key set to SQL by a row's last edit still saves that edit in its own place")
    func aKeySetToSQLInTheLastEditStillSplits() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: EditAroundADelete.rowC
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: EditAroundADelete.rowB)
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 0, columnName: "id", oldValue: "3", newValue: "NOW()",
            originalRow: ["3", "Cyd", "c@test.com"], absence: FieldAbsence(), isExpression: true
        )

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }

        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE", "UPDATE"])
        #expect(bound == [["Cyd", "3"], ["2"], ["3"]])
    }

    @Test("A row of a table with no primary key stays one UPDATE at its first edit's place")
    func aKeylessRowStaysOneUpdate() throws {
        let (manager, _) = EditAroundADelete.manager(primaryKeyColumns: [])
        EditAroundADelete.record(on: manager)
        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["UPDATE", "DELETE"])
    }
}

@MainActor
struct UpdateRunActionTests {
    @Test("One command over several rows writes each row once, whatever its other rows' changes")
    func oneCommandOverSeveralRowsIsOneUpdatePerRow() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "Di", "d@test.com"])
        manager.recordAsOneAction {
            manager.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name",
                oldValue: "Al", newValue: "Alf", originalRow: ["1", "Al", "a@test.com"]
            )
            manager.recordCellChange(
                rowID: .existing(1), columnIndex: 1, columnName: "name",
                oldValue: "Bo", newValue: "Bob", originalRow: EditAroundADelete.rowB
            )
            manager.recordCellChange(
                rowID: .existing(0), columnIndex: 2, columnName: "email",
                oldValue: "a@test.com", newValue: "alf@test.com", originalRow: ["1", "Alf", "a@test.com"]
            )
            manager.recordCellChange(
                rowID: .existing(1), columnIndex: 2, columnName: "email",
                oldValue: "b@test.com", newValue: "bob@test.com", originalRow: ["2", "Bob", "b@test.com"]
            )
        }
        manager.recordRowDeletion(rowID: .existing(4), originalRow: ["5", "Ed", "e@test.com"])

        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["DELETE", "UPDATE", "UPDATE", "DELETE"])
    }

    @Test("Typing into several rows at once writes each row once")
    func typingIntoSeveralRowsIsOneUpdatePerRow() throws {
        let (manager, _) = EditAroundADelete.manager()
        manager.recordTypedCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Al", newValue: "A", originalRow: ["1", "Al", "a@test.com"]
        )
        manager.recordTypedCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: "Bo", newValue: "A", originalRow: EditAroundADelete.rowB
        )
        manager.recordTypedCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "Ab", originalRow: ["1", "A", "a@test.com"]
        )
        manager.endCoalescedUndoRun()
        let verbs = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(verbs == ["UPDATE", "UPDATE"])
    }
}

@MainActor
struct UpdateRunUndoTests {
    @Test("Redoing a row's later edit puts it back after the delete it followed")
    func redoPutsTheLaterEditBackAfterTheDelete() throws {
        let (manager, undoManager) = EditAroundADelete.manager()
        EditAroundADelete.record(on: manager)

        undoManager.undo()
        undoManager.redo()

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }
        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE", "UPDATE"])
        #expect(bound.last == ["b@test.com", "3"])
    }

    @Test("Undoing a row's later edit leaves its earlier one where it was")
    func undoingTheLaterEditLeavesTheEarlierUpdate() throws {
        let (manager, undoManager) = EditAroundADelete.manager()
        EditAroundADelete.record(on: manager)

        undoManager.undo()

        let statements = try manager.generateSQL()
        let bound = statements.map { EditAroundADelete.strings($0) }
        #expect(EditAroundADelete.verbs(statements) == ["UPDATE", "DELETE"])
        #expect(bound.first == ["Cyd", "3"])
    }

    @Test("Undoing and redoing a command over two rows still writes each row once")
    func undoAndRedoOfACommandKeepOneUpdatePerRow() throws {
        let (manager, undoManager) = EditAroundADelete.manager()
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "Di", "d@test.com"])
        undoManager.beginUndoGrouping()
        manager.recordAsOneAction {
            manager.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name",
                oldValue: "Al", newValue: "Alf", originalRow: ["1", "Al", "a@test.com"]
            )
            manager.recordCellChange(
                rowID: .existing(1), columnIndex: 1, columnName: "name",
                oldValue: "Bo", newValue: "Bob", originalRow: EditAroundADelete.rowB
            )
            manager.recordCellChange(
                rowID: .existing(0), columnIndex: 2, columnName: "email",
                oldValue: "a@test.com", newValue: "alf@test.com", originalRow: ["1", "Alf", "a@test.com"]
            )
            manager.recordCellChange(
                rowID: .existing(1), columnIndex: 2, columnName: "email",
                oldValue: "b@test.com", newValue: "bob@test.com", originalRow: ["2", "Bob", "b@test.com"]
            )
        }
        undoManager.endUndoGrouping()

        undoManager.undo()
        let undone = try EditAroundADelete.verbs(manager.generateSQL())
        undoManager.redo()
        let redone = try EditAroundADelete.verbs(manager.generateSQL())

        #expect(undone == ["DELETE"])
        #expect(redone == ["DELETE", "UPDATE", "UPDATE"])
    }
}

// Edit C, delete B, then give C the email B freed: each step is valid on a unique `email`.
@MainActor
enum EditAroundADelete {
    static let columns = ["id", "name", "email"]
    static let rowB: [PluginCellValue] = ["2", "Bo", "b@test.com"]
    static let rowC: [PluginCellValue] = ["3", "Cy", "c@test.com"]

    static func manager(
        table: String = "users",
        primaryKeyColumns: [String] = ["id"],
        databaseType: DatabaseType = .mysql
    ) -> (DataChangeManager, UndoManager) {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        manager.configureForTable(
            tableName: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            generatedColumns: []
        )
        return (manager, undoManager)
    }

    static func record(on manager: DataChangeManager) {
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Cy", newValue: "Cyd", originalRow: rowC
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: rowB)
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 2, columnName: "email",
            oldValue: "c@test.com", newValue: "b@test.com", originalRow: ["3", "Cyd", "c@test.com"]
        )
    }

    nonisolated static func verbs(_ statements: [ParameterizedStatement]) -> [String] {
        statements.map { String($0.sql.prefix(while: { $0 != " " })) }
    }

    nonisolated static func strings(_ statement: ParameterizedStatement) -> [String] {
        statement.parameters.compactMap { $0 as? String }
    }
}
