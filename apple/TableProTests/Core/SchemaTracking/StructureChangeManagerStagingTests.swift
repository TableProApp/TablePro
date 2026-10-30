//
//  StructureChangeManagerStagingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
struct StructureChangeManagerStagingTests {
    private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func column(_ name: String, in manager: StructureChangeManager) -> EditableColumnDefinition {
        manager.workingColumns.first { $0.name == name }!
    }

    @Test("Making a column part of the key stages the key change the drivers write, not a column change")
    func primaryKeyCellStagesKeyChange() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)

        let changes = manager.getChangesArray()
        #expect(changes.contains(.modifyPrimaryKey(old: ["id"], new: ["id", "email"])))
        #expect(!changes.contains { if case .modifyColumn = $0 { true } else { false } })
        #expect(manager.workingPrimaryKey == ["id", "email"])
    }

    @Test("Taking the only key column out stages an empty key")
    func removingKeyColumnStagesEmptyKey() {
        let manager = loadedManager()
        var id = column("id", in: manager)
        id.isPrimaryKey = false
        manager.updateColumn(id: id.id, with: id)

        #expect(manager.getChangesArray().contains(.modifyPrimaryKey(old: ["id"], new: [])))
    }

    @Test("One undo reverts the key change and the column's flag together")
    func primaryKeyChangeUndoesAsOneStep() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)

        manager.undo()

        #expect(manager.workingPrimaryKey == ["id"])
        #expect(column("email", in: manager).isPrimaryKey == false)
        #expect(!manager.hasChanges)
    }

    @Test("A key toggle together with another edit keeps the column change")
    func keyToggleKeepsOtherColumnEdits() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.isNullable = false
        manager.updateColumn(id: email.id, with: email)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)

        let changes = manager.getChangesArray()
        #expect(changes.contains { if case .modifyColumn = $0 { true } else { false } })
        #expect(changes.contains { if case .modifyPrimaryKey = $0 { true } else { false } })
    }

    @Test("Undo Delete on an edited column stages its edit again")
    func undoDeleteRestagesEdit() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.dataType = "TEXT"
        manager.updateColumn(id: email.id, with: email)
        manager.deleteColumn(id: email.id)

        manager.undoDelete(section: .columns, id: email.id)

        guard case .modifyColumn(_, let new)? = manager.pendingChanges[.column(email.id)] else {
            Issue.record("the edit made before the delete is no longer staged")
            return
        }
        #expect(new.dataType == "TEXT")
    }

    @Test("Undoing a delete through the undo stack stages the earlier edit again")
    func undoStackDeleteRestagesEdit() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.dataType = "TEXT"
        manager.updateColumn(id: email.id, with: email)
        manager.deleteColumn(id: email.id)

        manager.undo()

        guard case .modifyColumn? = manager.pendingChanges[.column(email.id)] else {
            Issue.record("the edit made before the delete is no longer staged")
            return
        }
    }

    @Test("The Edit menu title names the change it undoes")
    func undoMenuTitleNamesTheChange() {
        let manager = loadedManager()
        manager.deleteColumn(id: column("email", in: manager).id)

        #expect(manager.undoMenuItemTitle.contains(String(localized: "Delete Column")))
    }

    @Test("Redoing a key toggle stages only the key change")
    func redoKeepsKeyOnlyChangeOffColumns() {
        let manager = loadedManager()
        var id = column("id", in: manager)
        id.isPrimaryKey = false
        manager.updateColumn(id: id.id, with: id)
        manager.undo()
        manager.redo()

        let changes = manager.getChangesArray()
        #expect(changes.contains(.modifyPrimaryKey(old: ["id"], new: [])))
        #expect(!changes.contains { if case .modifyColumn = $0 { true } else { false } })
    }

    @Test("Renaming a column the staged key names renames it in the key")
    func renameFollowsStagedKey() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)
        email.name = "address"
        manager.updateColumn(id: email.id, with: email)

        #expect(manager.workingPrimaryKey == ["id", "address"])
        #expect(manager.getChangesArray().contains(.modifyPrimaryKey(old: ["id"], new: ["id", "address"])))
        #expect(manager.canCommit)
    }

    @Test("A rename leaves an unchanged key alone")
    func renameWithoutStagedKeyStagesNoKeyChange() {
        let manager = loadedManager()
        var id = column("id", in: manager)
        id.name = "order_id"
        manager.updateColumn(id: id.id, with: id)

        #expect(!manager.getChangesArray().contains { if case .modifyPrimaryKey = $0 { true } else { false } })
    }

    @Test("Removing a column the staged key names takes it out of the key")
    func deletingStagedKeyMemberUpdatesKey() {
        let manager = loadedManager()
        manager.addNewColumn()
        var added = manager.workingColumns.last!
        added.name = "tenant_id"
        added.dataType = "INT"
        manager.updateColumn(id: added.id, with: added)
        added.isPrimaryKey = true
        manager.updateColumn(id: added.id, with: added)
        #expect(manager.workingPrimaryKey == ["id", "tenant_id"])

        manager.deleteColumn(id: added.id)

        #expect(manager.workingPrimaryKey == ["id"])
        #expect(!manager.getChangesArray().contains { if case .modifyPrimaryKey = $0 { true } else { false } })
    }

    @Test("Undo Delete on a column the staged key named puts it back in the key")
    func undoDeleteRestoresKeyMembership() {
        let manager = loadedManager()
        var email = column("email", in: manager)
        email.isNullable = false
        manager.updateColumn(id: email.id, with: email)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)
        manager.deleteColumn(id: email.id)
        #expect(manager.workingPrimaryKey == ["id"])

        manager.undoDelete(section: .columns, id: email.id)

        #expect(manager.workingPrimaryKey == ["id", "email"])
        #expect(manager.getChangesArray().contains(.modifyPrimaryKey(old: ["id"], new: ["id", "email"])))
    }

    @Test("A key change after a rename names the renamed column")
    func keyChangeAfterRenameUsesNewNames() {
        let manager = loadedManager()
        var id = column("id", in: manager)
        id.name = "order_id"
        manager.updateColumn(id: id.id, with: id)
        var email = column("email", in: manager)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)

        #expect(manager.workingPrimaryKey == ["order_id", "email"])
        #expect(manager.canCommit)
    }

    @Test("Undo Delete puts a key column back where it was in the key")
    func undoDeleteKeepsKeyOrder() {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "t",
            columns: ["a", "b", "c"].map {
                ColumnInfo(name: $0, dataType: "INT", isNullable: false, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            },
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        for name in ["a", "b", "c"] {
            var column = manager.workingColumns.first { $0.name == name }!
            column.isPrimaryKey = true
            manager.updateColumn(id: column.id, with: column)
        }
        let a = manager.workingColumns.first { $0.name == "a" }!
        manager.deleteColumn(id: a.id)
        #expect(manager.workingPrimaryKey == ["b", "c"])

        manager.undoDelete(section: .columns, id: a.id)

        #expect(manager.workingPrimaryKey == ["a", "b", "c"])
    }

    @Test("Deleting the old key column, then marking another, stages a key that names only surviving columns")
    func deleteThenMarkStagesSurvivingKey() {
        let manager = loadedManager()
        manager.deleteColumn(id: column("id", in: manager).id)
        var email = column("email", in: manager)
        email.isPrimaryKey = true
        manager.updateColumn(id: email.id, with: email)

        #expect(manager.workingPrimaryKey == ["email"])
        #expect(manager.getChangesArray().contains(.modifyPrimaryKey(old: ["id"], new: ["email"])))
        #expect(manager.canCommit)
    }

    @Test("Renaming a key column without changing the key stages no key change")
    func renameOfKeyColumnStagesNoKeyChange() {
        let manager = loadedManager()
        var id = column("id", in: manager)
        id.name = "order_id"
        manager.updateColumn(id: id.id, with: id)
        manager.deleteColumn(id: id.id)
        manager.undoDelete(section: .columns, id: id.id)

        #expect(!manager.getChangesArray().contains { if case .modifyPrimaryKey = $0 { true } else { false } })
        #expect(manager.workingPrimaryKey == ["order_id"])
    }

    @Test("Deleting the key column alone stages no key change, as the database drops it with the column")
    func deletingKeyColumnAloneStagesNoKeyChange() {
        let manager = loadedManager()
        manager.deleteColumn(id: column("id", in: manager).id)

        #expect(!manager.getChangesArray().contains { if case .modifyPrimaryKey = $0 { true } else { false } })
    }
}
