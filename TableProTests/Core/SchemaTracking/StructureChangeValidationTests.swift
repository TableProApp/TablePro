//
//  StructureChangeValidationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

/// The gate that stops an incomplete row reaching DDL generation.
///
/// `canCommit` and the messages behind it were written and then never read: Save asked only whether
/// anything was staged. So the "+" in the Foreign Keys tab, which stages a blank row immediately,
/// produced `ADD CONSTRAINT "" FOREIGN KEY () REFERENCES "" ()` on MySQL and PostgreSQL and
/// "Unsupported schema operation: Add foreign key ''" on SQLite.
@Suite("Structure Change Validation")
@MainActor
struct StructureChangeValidationTests {
    private func loadedManager(foreignKeys: [ForeignKeyInfo] = []) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(
                    name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true,
                    defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
                ),
                ColumnInfo(
                    name: "customer_id", dataType: "INTEGER", isNullable: true, isPrimaryKey: false,
                    defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
                )
            ],
            indexes: [],
            foreignKeys: foreignKeys,
            primaryKey: ["id"]
        )
        return manager
    }

    private func validForeignKey(
        name: String = "fk_orders_customer",
        columns: [String] = ["customer_id"],
        referencedTable: String = "customers",
        referencedColumns: [String] = ["id"]
    ) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            referencedSchema: nil,
            onDelete: .noAction,
            onUpdate: .noAction
        )
    }

    @Test("A manager with nothing staged cannot commit")
    func nothingStagedCannotCommit() {
        #expect(!loadedManager().canCommit)
    }

    /// This is the reported defect. The "+" stages a placeholder with no name, no columns and no
    /// referenced table, and Save used to take it straight to the DDL generator.
    @Test("The blank row the add button stages blocks the save")
    func blankForeignKeyBlocksCommit() {
        let manager = loadedManager()
        manager.addNewForeignKey()
        #expect(manager.hasChanges)
        #expect(!manager.canCommit)
        #expect(!manager.validationSummary.isEmpty)
    }

    @Test("Filling the row in unblocks the save")
    func completedForeignKeyAllowsCommit() {
        let manager = loadedManager()
        manager.addNewForeignKey()
        let staged = try? #require(manager.workingForeignKeys.last)
        if let staged {
            manager.updateForeignKey(id: staged.id, with: validForeignKey())
        }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    @Test("A key on a column the table does not have blocks the save")
    func foreignKeyOnMissingColumnBlocksCommit() {
        let manager = loadedManager()
        manager.addForeignKey(validForeignKey(columns: ["nope"]))
        #expect(!manager.canCommit)
    }

    /// A self-referencing key is the one case where both sides are in this editor, so both can be
    /// checked here rather than left to fail at the database.
    @Test("A self-referencing key that points at a missing column blocks the save")
    func selfReferenceOnMissingColumnBlocksCommit() {
        let manager = loadedManager()
        manager.addForeignKey(
            validForeignKey(referencedTable: "orders", referencedColumns: ["nope"])
        )
        #expect(!manager.canCommit)
    }

    /// The referenced columns of a key pointing at another table are not in this editor, so they
    /// are the database's to check, when the change runs.
    @Test("A key pointing at another table is not checked against this table's columns")
    func referenceToAnotherTableIsNotCheckedLocally() {
        let manager = loadedManager()
        manager.addForeignKey(validForeignKey(referencedColumns: ["not_in_orders"]))
        #expect(manager.canCommit)
    }

    /// Turning on a gate that had never run is where a regression hides. An untouched foreign key
    /// still names the column's old spelling after a rename, and every engine's `RENAME COLUMN`
    /// carries the dependency over itself, so blocking here would refuse a save that works today.
    @Test("Renaming a column an untouched foreign key uses does not block the save")
    func renameDoesNotBlockAnUntouchedForeignKey() {
        let manager = loadedManager(foreignKeys: [
            ForeignKeyInfo(
                name: "fk_orders_customer", column: "customer_id",
                referencedTable: "customers", referencedColumn: "id"
            )
        ])
        var renamed = manager.workingColumns[1]
        renamed.name = "buyer_id"
        manager.updateColumn(id: manager.workingColumns[1].id, with: renamed)

        #expect(manager.hasChanges)
        #expect(manager.canCommit)
    }

    /// A struck-through foreign key is on its way out, so demanding that it name a column that is
    /// going with it would refuse the very edit the user made.
    @Test("Deleting a column and its foreign key together does not block the save")
    func compoundDeleteDoesNotBlockTheSave() {
        let manager = loadedManager()
        manager.addForeignKey(validForeignKey())
        let staged = manager.workingForeignKeys.last
        if let staged { manager.deleteForeignKey(id: staged.id) }
        manager.deleteColumn(id: manager.workingColumns[1].id)
        #expect(manager.canCommit)
    }

    /// SQLite accepts a column declared `ID` referenced as `id`, and reports each spelling as
    /// written. An exact comparison refused a valid self-referencing key.
    @Test("A self-referencing key matches its column whatever the case")
    func selfReferenceComparesCaseInsensitively() {
        let manager = loadedManager()
        manager.addForeignKey(
            validForeignKey(columns: ["CUSTOMER_ID"], referencedTable: "ORDERS", referencedColumns: ["ID"])
        )
        #expect(manager.canCommit)
    }

    @Test("Every blocked save can say what is wrong with it")
    func summaryNamesTheProblem() {
        let manager = loadedManager()
        manager.addNewForeignKey()
        manager.addNewIndex()
        let summary = manager.validationSummary
        #expect(summary.contains("Foreign key"))
        #expect(summary.contains("Index"))
    }
}
