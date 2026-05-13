//
//  StructureEditingSupportFieldDiffTests.swift
//  TableProTests
//
//  Tests for the field-by-field diff helpers that drive per-cell modified-column
//  tinting on the Structure tab. The grid reads `RowVisualState.modifiedColumns`
//  to decide which cells get the yellow tint; these helpers compute that set
//  from the working/original entity pair stored on `StructureChangeManager`.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("StructureEditingSupport Field Diff")
@MainActor
struct StructureEditingSupportFieldDiffTests {
    // MARK: - Fixtures

    private static let mysqlOrderedFields: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .primaryKey,
        .autoIncrement, .comment, .charset, .collation
    ]

    private static let postgresOrderedFields: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .primaryKey, .autoIncrement, .comment
    ]

    private func makeColumn(name: String = "id", dataType: String = "INT") -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: false,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    private func makeIndex(name: String = "idx_users_email") -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: ["email"],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil,
            columnPrefixes: [:],
            whereClause: nil
        )
    }

    private func makeForeignKey(name: String = "fk_orders_user") -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            referencedSchema: nil,
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    // MARK: - columnModifiedIndices

    @Test("Identical columns produce empty diff")
    func columnIdentical() {
        let column = makeColumn()
        let result = StructureEditingSupport.columnModifiedIndices(
            old: column,
            new: column,
            orderedFields: Self.mysqlOrderedFields
        )
        #expect(result.isEmpty)
    }

    @Test("Renaming a column flags only the name index")
    func columnNameChanged() {
        let original = makeColumn(name: "user_id")
        var renamed = original
        renamed.name = "user_idd"

        let result = StructureEditingSupport.columnModifiedIndices(
            old: original,
            new: renamed,
            orderedFields: Self.mysqlOrderedFields
        )
        #expect(result == [0])
    }

    @Test("Editing two unrelated fields flags exactly those indices")
    func columnTwoFieldsChanged() {
        let original = makeColumn()
        var changed = original
        changed.dataType = "BIGINT"
        changed.comment = "primary identifier"

        let result = StructureEditingSupport.columnModifiedIndices(
            old: original,
            new: changed,
            orderedFields: Self.mysqlOrderedFields
        )
        // .type is at index 1, .comment is at index 6 in mysqlOrderedFields.
        #expect(result == [1, 6])
    }

    @Test("Diff respects orderedFields and skips fields not displayed by the database type")
    func columnFieldsMissingFromOrderedFields() {
        let original = makeColumn()
        var changed = original
        changed.collation = "utf8mb4_general_ci"

        // Postgres ordered fields exclude `.collation`, so the change is
        // invisible to the grid and must not produce an index.
        let result = StructureEditingSupport.columnModifiedIndices(
            old: original,
            new: changed,
            orderedFields: Self.postgresOrderedFields
        )
        #expect(result.isEmpty)
    }

    @Test("All nine StructureColumnField cases are diffable")
    func columnEveryFieldDetected() {
        let original = makeColumn(name: "a", dataType: "INT")
        var changed = original
        changed.name = "b"
        changed.dataType = "BIGINT"
        changed.isNullable.toggle()
        changed.defaultValue = "0"
        changed.isPrimaryKey.toggle()
        changed.autoIncrement.toggle()
        changed.comment = "x"
        changed.charset = "utf8mb4"
        changed.collation = "utf8mb4_general_ci"

        let result = StructureEditingSupport.columnModifiedIndices(
            old: original,
            new: changed,
            orderedFields: Self.mysqlOrderedFields
        )
        #expect(result == Set(0..<Self.mysqlOrderedFields.count))
    }

    // MARK: - indexModifiedIndices

    @Test("Identical indexes produce empty diff")
    func indexIdentical() {
        let index = makeIndex()
        #expect(StructureEditingSupport.indexModifiedIndices(old: index, new: index).isEmpty)
    }

    @Test("Changing only columnPrefixes flags the columns index")
    func indexColumnPrefixesChanged() {
        let original = makeIndex()
        var changed = original
        changed.columnPrefixes = ["email": 10]

        let result = StructureEditingSupport.indexModifiedIndices(old: original, new: changed)
        // columnPrefixes is OR'd into index 1 (Columns) because the prefix is
        // displayed inline with the column list (`name(10)`).
        #expect(result == [1])
    }

    @Test("Toggling unique flags only the unique index")
    func indexUniqueChanged() {
        let original = makeIndex()
        var changed = original
        changed.isUnique.toggle()

        let result = StructureEditingSupport.indexModifiedIndices(old: original, new: changed)
        #expect(result == [3])
    }

    @Test("Index fields not displayed in the grid (isPrimary, comment) do not produce indices")
    func indexUndisplayedFieldsIgnored() {
        let original = makeIndex()
        var changed = original
        changed.isPrimary.toggle()
        changed.comment = "rebuild after migration"

        let result = StructureEditingSupport.indexModifiedIndices(old: original, new: changed)
        #expect(result.isEmpty)
    }

    // MARK: - foreignKeyModifiedIndices

    @Test("Identical foreign keys produce empty diff")
    func foreignKeyIdentical() {
        let fk = makeForeignKey()
        #expect(StructureEditingSupport.foreignKeyModifiedIndices(old: fk, new: fk).isEmpty)
    }

    @Test("Changing referential actions flags onDelete and onUpdate independently")
    func foreignKeyReferentialActionsChanged() {
        let original = makeForeignKey()
        var changed = original
        changed.onDelete = .cascade

        let onlyDelete = StructureEditingSupport.foreignKeyModifiedIndices(old: original, new: changed)
        #expect(onlyDelete == [5])

        changed.onUpdate = .setNull
        let both = StructureEditingSupport.foreignKeyModifiedIndices(old: original, new: changed)
        #expect(both == [5, 6])
    }

    @Test("All seven foreign-key grid columns are covered")
    func foreignKeyEveryFieldDetected() {
        let original = makeForeignKey()
        var changed = original
        changed.name = "fk_renamed"
        changed.columns = ["user_id", "tenant_id"]
        changed.referencedTable = "tenants"
        changed.referencedColumns = ["id", "tenant_id"]
        changed.referencedSchema = "public"
        changed.onDelete = .cascade
        changed.onUpdate = .restrict

        let result = StructureEditingSupport.foreignKeyModifiedIndices(old: original, new: changed)
        #expect(result == Set(0..<7))
    }
}

// MARK: - undoDelete(for:at:)

@Suite("StructureChangeManager Row-Specific Undo Delete")
@MainActor
struct StructureChangeManagerUndoDeleteTests {
    private func makeManagerWithSchema() -> StructureChangeManager {
        let manager = StructureChangeManager()
        let columns: [ColumnInfo] = [
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
        ]
        manager.loadSchema(
            tableName: "users",
            columns: columns,
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"],
            databaseType: .mysql
        )
        return manager
    }

    @Test("undoDelete clears the deletion mark for an existing column")
    func undoDeleteExistingColumn() {
        let manager = makeManagerWithSchema()
        let emailColumn = manager.workingColumns[1]
        manager.deleteColumn(id: emailColumn.id)
        #expect(manager.deleteInsertState(for: 1, tab: .columns).isDeleted)

        manager.undoDelete(for: .columns, at: 1)
        #expect(!manager.deleteInsertState(for: 1, tab: .columns).isDeleted)
        #expect(manager.pendingChanges[.column(emailColumn.id)] == nil)
    }

    @Test("undoDelete is a no-op for rows whose pending change is not a delete")
    func undoDeleteIgnoresNonDeleteChanges() {
        let manager = makeManagerWithSchema()
        var renamed = manager.workingColumns[1]
        renamed.name = "email_address"
        manager.updateColumn(id: renamed.id, with: renamed)
        let beforeChanges = manager.pendingChanges

        manager.undoDelete(for: .columns, at: 1)

        #expect(manager.pendingChanges == beforeChanges)
    }

    @Test("undoDelete bounds-checks the row index")
    func undoDeleteOutOfRange() {
        let manager = makeManagerWithSchema()
        manager.undoDelete(for: .columns, at: 99)
        manager.undoDelete(for: .indexes, at: 0)
        manager.undoDelete(for: .foreignKeys, at: 0)
        #expect(manager.pendingChanges.isEmpty)
    }

    @Test("undoDelete on .ddl / .parts tabs is a no-op")
    func undoDeleteDDLAndParts() {
        let manager = makeManagerWithSchema()
        let emailColumn = manager.workingColumns[1]
        manager.deleteColumn(id: emailColumn.id)

        manager.undoDelete(for: .ddl, at: 1)
        manager.undoDelete(for: .parts, at: 1)

        #expect(manager.deleteInsertState(for: 1, tab: .columns).isDeleted)
    }
}
