//
//  StructureChangeNameReuseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A name belongs to the rows the table keeps after the save.
///
/// The save drops every index and check constraint before it adds or renames one, so a name a row
/// is being deleted under is free by the time anything takes it. The duplicate check still counted
/// the deleted row, and "delete idx_a, add a new idx_a" was refused as a duplicate of the row on
/// its way out.
@MainActor
struct StructureChangeNameReuseTests {
    private func manager(
        indexes: [IndexInfo] = [],
        checkConstraints: [CheckConstraintInfo] = []
    ) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "notes",
            columns: ["id", "body", "title", "a"].map { name in
                ColumnInfo(
                    name: name, dataType: "INTEGER", isNullable: name != "id", isPrimaryKey: name == "id",
                    defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
                )
            },
            indexes: indexes,
            foreignKeys: [],
            checkConstraints: checkConstraints,
            primaryKey: ["id"]
        )
        return manager
    }

    private func loadedIndex(_ name: String, on column: String) -> IndexInfo {
        IndexInfo(name: name, columns: [column], isUnique: false, isPrimary: false, type: "BTREE")
    }

    private func newIndex(_ name: String, on column: String) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: [column], type: .btree, isUnique: false, isPrimary: false, comment: nil
        )
    }

    private func newConstraint(_ name: String, _ expression: String) -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(id: UUID(), name: name, expression: expression, columns: [], isValidated: true)
    }

    private func index(named name: String, in manager: StructureChangeManager) throws -> EditableIndexDefinition {
        try #require(manager.workingIndexes.first { $0.name == name })
    }

    private func constraint(
        at position: Int,
        in manager: StructureChangeManager
    ) throws -> EditableCheckConstraintDefinition {
        let constraints = manager.workingCheckConstraints
        try #require(constraints.indices.contains(position))
        return constraints[position]
    }

    private func errors(in manager: StructureChangeManager) -> Set<String> {
        Set(manager.validationErrors.values)
    }

    // MARK: - Indexes

    /// Measured on SQLite 3.54, PostgreSQL 17.11 and MariaDB 13.0.2: `CREATE INDEX idx_a` fails while
    /// `idx_a` exists, and succeeds straight after `DROP INDEX idx_a` in the same save.
    @Test("Deleting an index frees its name for a new one in the same save")
    func deletingAnIndexFreesItsNameForANewOne() throws {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body")])
        manager.deleteIndex(id: try index(named: "idx_a", in: manager).id)
        manager.addIndex(newIndex("idx_a", on: "title"))

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    @Test("An index renamed onto a deleted index's name saves")
    func renamingAnIndexOntoADeletedOnesName() throws {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body"), loadedIndex("idx_b", on: "title")])
        manager.deleteIndex(id: try index(named: "idx_a", in: manager).id)
        var renamed = try index(named: "idx_b", in: manager)
        renamed.name = "idx_a"
        manager.updateIndex(id: renamed.id, with: renamed)

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    /// The row menu's **Duplicate** stages a copy under the same name, which is the everyday way to
    /// build a replacement before the original goes.
    @Test("Duplicating an index and then deleting the original saves")
    func duplicatingAnIndexThenDeletingTheOriginalSaves() throws {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body")])
        let original = try index(named: "idx_a", in: manager)
        manager.addIndex(original.withNewIdentity())
        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate index name: idx_a"])

        manager.deleteIndex(id: original.id)
        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    @Test("Bringing the deleted index back makes the replacement a duplicate again")
    func undoingTheDeletionBringsTheDuplicateBack() throws {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body")])
        let original = try index(named: "idx_a", in: manager)
        manager.addIndex(newIndex("idx_a", on: "title"))
        manager.deleteIndex(id: original.id)
        #expect(manager.canCommit)

        manager.undoDelete(for: .indexes, at: 0)
        #expect(!manager.canCommit)
        #expect(manager.validationErrors.count == 2)
        #expect(errors(in: manager) == ["Duplicate index name: idx_a"])
    }

    @Test("Undoing the deletion makes the replacement a duplicate again")
    func undoRestoresTheDuplicate() throws {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body")])
        let original = try index(named: "idx_a", in: manager)
        manager.addIndex(newIndex("idx_a", on: "title"))
        manager.deleteIndex(id: original.id)

        manager.undo()
        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate index name: idx_a"])
    }

    @Test("An index added under the name of one the table keeps is a duplicate")
    func addingAnIndexUnderAKeptIndexesNameIsADuplicate() {
        let manager = manager(indexes: [loadedIndex("idx_a", on: "body")])
        manager.addIndex(newIndex("idx_a", on: "title"))

        #expect(!manager.canCommit)
        #expect(manager.validationErrors.count == 2)
        #expect(errors(in: manager) == ["Duplicate index name: idx_a"])
    }

    @Test("Two added indexes under one name are duplicates")
    func twoAddedIndexesWithOneNameAreDuplicates() {
        let manager = manager()
        manager.addIndex(newIndex("idx_a", on: "body"))
        manager.addIndex(newIndex("idx_a", on: "title"))

        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate index name: idx_a"])
    }

    // MARK: - Check constraints

    /// Measured on SQLite 3.54 and PostgreSQL 17.11: `DROP CONSTRAINT c` then `ADD CONSTRAINT c`
    /// saves, and `ADD CONSTRAINT c` alone fails while `c` exists.
    @Test("Deleting a check constraint frees its name for a new one in the same save")
    func deletingACheckConstraintFreesItsName() throws {
        let manager = manager(checkConstraints: [CheckConstraintInfo(name: "c", expression: "a > 0")])
        manager.deleteCheckConstraint(id: try constraint(at: 0, in: manager).id)
        manager.addCheckConstraint(newConstraint("c", "a < 10"))

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    @Test("A check constraint renamed onto a deleted one's name saves")
    func renamingAConstraintOntoADeletedOnesName() throws {
        let manager = manager(checkConstraints: [
            CheckConstraintInfo(name: "c", expression: "a > 0"),
            CheckConstraintInfo(name: "d", expression: "a < 10")
        ])
        manager.deleteCheckConstraint(id: try constraint(at: 0, in: manager).id)
        var renamed = try constraint(at: 1, in: manager)
        renamed.name = "c"
        manager.updateCheckConstraint(id: renamed.id, with: renamed)

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    @Test("A check constraint added under the name of one the table keeps is a duplicate")
    func addingAConstraintUnderAKeptNameIsADuplicate() {
        let manager = manager(checkConstraints: [CheckConstraintInfo(name: "c", expression: "a > 0")])
        manager.addCheckConstraint(newConstraint("c", "a < 10"))

        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate constraint name: c"])
    }

    /// Measured on SQLite 3.54: `ADD CONSTRAINT "C"` beside `c` fails with "constraint C already
    /// exists", and MariaDB 13.0.2 refuses it with ERROR 1826.
    @Test("A check constraint added beside one whose name differs only in case is a duplicate")
    func addingAConstraintUnderACaseVariantOfAKeptNameIsADuplicate() {
        let manager = manager(checkConstraints: [CheckConstraintInfo(name: "c", expression: "a > 0")])
        manager.addCheckConstraint(newConstraint("C", "a < 10"))

        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate constraint name: c", "Duplicate constraint name: C"])
    }

    // MARK: - Two loaded check constraints under one name

    /// SQLite 3.54 accepts `CONSTRAINT c CHECK (a > 0), CONSTRAINT c CHECK (a < 10)` in one
    /// `CREATE TABLE`, and the Structure tab lists both.
    private func tableWithTwoConstraintsNamedC(secondName: String = "c") -> StructureChangeManager {
        manager(checkConstraints: [
            CheckConstraintInfo(name: "c", expression: "a > 0"),
            CheckConstraintInfo(name: secondName, expression: "a < 10")
        ])
    }

    private let sharedNameRefusal = "More than one check constraint is named c. Change or delete all of them in the same save."

    @Test("Two loaded check constraints under one name do not block a save that leaves them alone")
    func untouchedSameNamedConstraintsDoNotBlockAnUnrelatedSave() {
        let manager = tableWithTwoConstraintsNamedC()
        manager.addIndex(newIndex("idx_body", on: "body"))

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    /// Measured on SQLite 3.54: `DROP CONSTRAINT c` removes the first `c` in the table's text,
    /// whichever row was picked.
    @Test("Deleting one of two check constraints under one name is refused")
    func droppingOneOfTwoSameNamedConstraintsIsRefused() throws {
        let manager = tableWithTwoConstraintsNamedC()
        let second = try constraint(at: 1, in: manager)
        manager.deleteCheckConstraint(id: second.id)

        #expect(!manager.canCommit)
        #expect(manager.validationErrors[.checkConstraint(second.id)] == sharedNameRefusal)
        #expect(manager.validationErrors.count == 1)
    }

    @Test("Rewriting one of two check constraints under one name is refused")
    func rewritingOneOfTwoSameNamedConstraintsIsRefused() throws {
        let manager = tableWithTwoConstraintsNamedC()
        var rewritten = try constraint(at: 0, in: manager)
        rewritten.expression = "a > 1"
        manager.updateCheckConstraint(id: rewritten.id, with: rewritten)

        #expect(!manager.canCommit)
        #expect(manager.validationErrors[.checkConstraint(rewritten.id)] == sharedNameRefusal)
    }

    @Test("Renaming one of two check constraints under one name is refused")
    func renamingOneOfTwoSameNamedConstraintsIsRefused() throws {
        let manager = tableWithTwoConstraintsNamedC()
        var renamed = try constraint(at: 0, in: manager)
        renamed.name = "d"
        manager.updateCheckConstraint(id: renamed.id, with: renamed)

        #expect(!manager.canCommit)
        #expect(manager.validationErrors[.checkConstraint(renamed.id)] == sharedNameRefusal)
        #expect(manager.validationErrors.count == 1)
    }

    /// Measured on SQLite 3.54: `DROP CONSTRAINT "C"` on a table holding `c` and `C` drops `c`.
    @Test("Check constraint names that differ only in case are one name")
    func caseVariantConstraintNamesAreShared() throws {
        let manager = tableWithTwoConstraintsNamedC(secondName: "C")
        let second = try constraint(at: 1, in: manager)
        manager.deleteCheckConstraint(id: second.id)

        #expect(!manager.canCommit)
        #expect(manager.validationErrors[.checkConstraint(second.id)]?.hasPrefix("More than one check constraint is named C") == true)
    }

    @Test("Deleting every check constraint under a shared name saves")
    func droppingBothSameNamedConstraintsSaves() throws {
        let manager = tableWithTwoConstraintsNamedC()
        let ids = manager.workingCheckConstraints.map(\.id)
        for id in ids {
            manager.deleteCheckConstraint(id: id)
        }

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    /// Measured on SQLite 3.54: after `DROP CONSTRAINT c` twice and `ADD CONSTRAINT c`, the add of
    /// `C` fails with "constraint C already exists".
    @Test("Replacing both check constraints under a shared name with c and C is a duplicate")
    func replacingBothWithCaseVariantsIsADuplicate() {
        let manager = tableWithTwoConstraintsNamedC()
        for id in manager.workingCheckConstraints.map(\.id) {
            manager.deleteCheckConstraint(id: id)
        }
        manager.addCheckConstraint(newConstraint("c", "a > 1"))
        manager.addCheckConstraint(newConstraint("C", "a < 9"))

        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate constraint name: c", "Duplicate constraint name: C"])
    }

    /// SQLite has no `RENAME CONSTRAINT`, so each rename is a drop by the shared name and an add of
    /// the row's own definition. Whichever `c` each drop takes, both go and both come back right.
    @Test("Renaming every check constraint under a shared name saves")
    func renamingBothSameNamedConstraintsSaves() throws {
        let manager = tableWithTwoConstraintsNamedC()
        for (position, name) in [(0, "d"), (1, "e")] {
            var renamed = try constraint(at: position, in: manager)
            renamed.name = name
            manager.updateCheckConstraint(id: renamed.id, with: renamed)
        }

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    /// Measured on SQLite 3.54: `DROP CONSTRAINT c; DROP CONSTRAINT c; ADD CONSTRAINT c CHECK (a < 20)`
    /// leaves exactly the rewritten constraint.
    @Test("Deleting one check constraint under a shared name and rewriting the other saves")
    func deletingOneAndRewritingTheOtherSaves() throws {
        let manager = tableWithTwoConstraintsNamedC()
        manager.deleteCheckConstraint(id: try constraint(at: 0, in: manager).id)
        var rewritten = try constraint(at: 1, in: manager)
        rewritten.expression = "a < 20"
        manager.updateCheckConstraint(id: rewritten.id, with: rewritten)

        #expect(manager.canCommit)
        #expect(manager.validationErrors.isEmpty)
    }

    /// Both would be added back as `c`, and the second `ADD CONSTRAINT c` fails on SQLite 3.54 with
    /// "constraint c already exists".
    @Test("Rewriting both check constraints under their shared name is a duplicate")
    func rewritingBothUnderTheSharedNameIsADuplicate() throws {
        let manager = tableWithTwoConstraintsNamedC()
        for (position, expression) in [(0, "a > 1"), (1, "a < 9")] {
            var rewritten = try constraint(at: position, in: manager)
            rewritten.expression = expression
            manager.updateCheckConstraint(id: rewritten.id, with: rewritten)
        }

        #expect(!manager.canCommit)
        #expect(errors(in: manager) == ["Duplicate constraint name: c"])
    }
}
