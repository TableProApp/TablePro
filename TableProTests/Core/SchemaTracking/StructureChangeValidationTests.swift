//
//  StructureChangeValidationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// The gate that stops an incomplete row reaching DDL generation.
///
/// `canCommit` and the messages behind it were written and then never read: Save asked only whether
/// anything was staged. So the "+" in the Foreign Keys tab, which stages a blank row immediately,
/// produced `ADD CONSTRAINT "" FOREIGN KEY () REFERENCES "" ()` on MySQL and PostgreSQL and
/// "Unsupported schema operation: Add foreign key ''" on SQLite.
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

    // MARK: - Columns the save does not touch

    private func column(_ name: String, type: String, isPrimaryKey: Bool = false) -> ColumnInfo {
        ColumnInfo(
            name: name, dataType: type, isNullable: !isPrimaryKey, isPrimaryKey: isPrimaryKey,
            defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
        )
    }

    private func schemaManager(
        loading columns: [ColumnInfo],
        primaryKey: [String],
        table: String = "notes"
    ) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(tableName: table, columns: columns, indexes: [], foreignKeys: [], primaryKey: primaryKey)
        return manager
    }

    /// `CREATE TABLE notes (id INTEGER PRIMARY KEY, body, tag TEXT)`. Measured on SQLite 3.53.4,
    /// `PRAGMA table_xinfo` reports `body`'s type as the empty string, and the driver passes it on.
    private func notesWithATypelessColumn() -> StructureChangeManager {
        schemaManager(
            loading: [
                column("id", type: "INTEGER", isPrimaryKey: true),
                column("body", type: ""),
                column("tag", type: "TEXT")
            ],
            primaryKey: ["id"]
        )
    }

    private func edit(
        _ name: String,
        in manager: StructureChangeManager,
        _ change: (inout EditableColumnDefinition) -> Void
    ) throws {
        var column = try #require(manager.workingColumns.first(where: { $0.name == name }))
        change(&column)
        manager.updateColumn(id: column.id, with: column)
    }

    private func delete(_ name: String, in manager: StructureChangeManager) throws {
        let column = try #require(manager.workingColumns.first(where: { $0.name == name }))
        manager.deleteColumn(id: column.id)
    }

    @Test("A column declared without a type does not block a save that leaves it alone")
    func untouchedTypelessColumnDoesNotBlockTheSave() throws {
        let manager = notesWithATypelessColumn()
        try edit("tag", in: manager) { $0.name = "label" }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    /// MongoDB 7 stores fields named `""` and `"   "`, and the flattener lists both as columns.
    @Test("A field with an empty name does not block a save that leaves it alone")
    func untouchedEmptyNamedFieldDoesNotBlockTheSave() throws {
        let manager = schemaManager(
            loading: [
                column("_id", type: "ObjectId", isPrimaryKey: true),
                column("", type: "VARCHAR"),
                column("   ", type: "VARCHAR"),
                column("a", type: "INTEGER")
            ],
            primaryKey: ["_id"],
            table: "c"
        )
        try edit("a", in: manager) { $0.name = "alpha" }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    @Test("Renaming a column that has no type does not ask for one")
    func renamingATypelessColumnDoesNotAskForAType() throws {
        let manager = notesWithATypelessColumn()
        try edit("body", in: manager) { $0.name = "content" }
        #expect(manager.canCommit)
    }

    @Test("Making a column that has no type NOT NULL does not ask for a type")
    func nullabilityEditOnATypelessColumnDoesNotAskForAType() throws {
        let manager = notesWithATypelessColumn()
        try edit("body", in: manager) { $0.setNullable(false) }
        #expect(manager.canCommit)
    }

    @Test("Naming a field that had no name is not refused")
    func namingAnEmptyNamedFieldIsAllowed() throws {
        let manager = schemaManager(
            loading: [column("_id", type: "ObjectId", isPrimaryKey: true), column("   ", type: "VARCHAR")],
            primaryKey: ["_id"],
            table: "c"
        )
        try edit("   ", in: manager) { $0.name = "spaces" }
        #expect(manager.canCommit)
    }

    @Test("Deleting a column that has no type does not block the save")
    func deletingATypelessColumnDoesNotBlockTheSave() throws {
        let manager = notesWithATypelessColumn()
        try delete("body", in: manager)
        #expect(manager.canCommit)
    }

    @Test("A primary key on a column with no type is found")
    func primaryKeyOnATypelessColumnIsFound() throws {
        let manager = schemaManager(
            loading: [column("k", type: "", isPrimaryKey: true), column("v", type: "INTEGER")],
            primaryKey: ["k"],
            table: "keyed"
        )
        try edit("v", in: manager) { $0.name = "value" }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    /// Measured on SQLite 3.54: `RENAME COLUMN id TO note_id` keeps the key, and `pk` reads 1 on
    /// the renamed column.
    @Test("Renaming the primary key column does not block the save")
    func renamingThePrimaryKeyColumnDoesNotBlockTheSave() throws {
        let manager = notesWithATypelessColumn()
        try edit("id", in: manager) { $0.name = "note_id" }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    /// MySQL and PostgreSQL drop the key with the column, and SQLite refuses with "cannot drop
    /// PRIMARY KEY column". Either way it is the database's answer, not a missing column.
    @Test("Deleting a primary key column is left to the database")
    func deletingAPrimaryKeyColumnIsLeftToTheDatabase() throws {
        let manager = notesWithATypelessColumn()
        try delete("id", in: manager)
        #expect(manager.canCommit)
    }

    @Test("An index on a column with no type is not refused as naming a missing column")
    func indexOnATypelessColumnIsFound() {
        let manager = notesWithATypelessColumn()
        manager.addIndex(
            EditableIndexDefinition(
                id: UUID(), name: "notes_body", columns: ["body"], type: .btree, isUnique: false,
                isPrimary: false, comment: nil
            )
        )
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    /// Measured on SQLite 3.53.4: `ADD COLUMN body INTEGER` beside a typeless `body` fails with
    /// "duplicate column name: body". A column with no type still holds its name.
    @Test("Adding a column named like one that has no type is a duplicate")
    func addingAColumnNamedLikeATypelessOneIsADuplicate() {
        let manager = notesWithATypelessColumn()
        var added = EditableColumnDefinition.placeholder()
        added.name = "body"
        added.dataType = "INTEGER"
        manager.addColumn(added)
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Duplicate column name: body"))
        #expect(!manager.validationSummary.contains("must have a name"))
    }

    @Test("Two loaded columns with one name do not block an unrelated save")
    func untouchedDuplicateNamesDoNotBlockAnUnrelatedSave() throws {
        let manager = schemaManager(
            loading: [column("x", type: "INTEGER"), column("x", type: "INTEGER"), column("y", type: "TEXT")],
            primaryKey: []
        )
        try edit("y", in: manager) { $0.name = "z" }
        #expect(manager.canCommit)
    }

    // MARK: - Edits that still block the save

    @Test("Clearing a column's type blocks the save")
    func clearingAColumnsTypeBlocksTheSave() throws {
        let manager = notesWithATypelessColumn()
        try edit("tag", in: manager) { $0.dataType = "" }
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }

    @Test("Clearing a column's name blocks the save")
    func clearingAColumnsNameBlocksTheSave() throws {
        let manager = notesWithATypelessColumn()
        try edit("tag", in: manager) { $0.name = "   " }
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }

    @Test("Clearing the name of a column that has no type blocks the save")
    func clearingATypelessColumnsNameBlocksTheSave() throws {
        let manager = notesWithATypelessColumn()
        try edit("body", in: manager) { $0.name = "" }
        #expect(!manager.canCommit)
    }

    @Test("The blank column the add button stages blocks the save")
    func blankAddedColumnBlocksTheSave() {
        let manager = notesWithATypelessColumn()
        manager.addNewColumn()
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }

    @Test("Two blank added columns are incomplete, not duplicates")
    func twoBlankRowsAreIncompleteNotDuplicates() {
        let manager = notesWithATypelessColumn()
        manager.addNewColumn()
        manager.addNewColumn()
        #expect(!manager.canCommit)
        #expect(!manager.validationSummary.contains("Duplicate"))
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }

    @Test("Renaming a column onto another column's name is a duplicate")
    func renamingOntoAnExistingNameIsADuplicate() throws {
        let manager = notesWithATypelessColumn()
        try edit("tag", in: manager) { $0.name = "id" }
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Duplicate column name: id"))
    }

    // MARK: - Blank names the table already holds

    /// `CREATE TABLE blanks (id INTEGER PRIMARY KEY, "" TEXT, "   " TEXT, tag TEXT)`. SQLite holds
    /// `""` and `"   "` as two columns, and measured on 3.54.0 `RENAME COLUMN "   " TO ""` fails with
    /// "duplicate column name: ".
    private func tableWithBlankNames() -> StructureChangeManager {
        schemaManager(
            loading: [
                column("id", type: "INTEGER", isPrimaryKey: true),
                column("", type: "TEXT"),
                column("   ", type: "TEXT"),
                column("tag", type: "TEXT")
            ],
            primaryKey: ["id"],
            table: "blanks"
        )
    }

    @Test("Renaming a column onto a blank name the table holds is a duplicate")
    func renamingOntoALoadedBlankNameIsADuplicate() throws {
        let manager = tableWithBlankNames()
        try edit("   ", in: manager) { $0.name = "" }
        #expect(!manager.canCommit)
        #expect(manager.validationSummary.contains("Duplicate column name"))
    }

    /// Measured on SQLite 3.54.0: `RENAME COLUMN "" TO "  "` beside `"   "` succeeds.
    @Test("Blank names of different lengths are different names")
    func blankNamesOfDifferentLengthsDoNotCollide() throws {
        let manager = tableWithBlankNames()
        try edit("", in: manager) { $0.name = "  " }
        #expect(manager.canCommit)
        #expect(manager.validationSummary.isEmpty)
    }

    @Test("A blank added column beside a blank name the table holds is incomplete, not a duplicate")
    func blankAddedColumnBesideALoadedBlankNameIsIncomplete() {
        let manager = tableWithBlankNames()
        manager.addNewColumn()
        #expect(!manager.canCommit)
        #expect(!manager.validationSummary.contains("Duplicate"))
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }

    @Test("Clearing a name beside a blank name the table holds is incomplete, not a duplicate")
    func clearedNameBesideALoadedBlankNameIsIncomplete() throws {
        let manager = tableWithBlankNames()
        try edit("tag", in: manager) { $0.name = "" }
        #expect(!manager.canCommit)
        #expect(!manager.validationSummary.contains("Duplicate"))
        #expect(manager.validationSummary.contains("Column must have a name and a data type"))
    }
}
