//
//  CheckConstraintStatementTests.swift
//  TableProTests
//
//  Ordering and drop-versus-rename rules for staged check constraint edits.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ConstraintDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsRename = true

    var isConnected: Bool { true }
    var currentSchema: String? { "public" }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        "ALTER TABLE \(table) ADD CONSTRAINT \(constraint.name) CHECK (\(constraint.expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(table) DROP CONSTRAINT \(constraintName)"
    }

    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String? {
        guard supportsRename else { return nil }
        return "ALTER TABLE \(table) RENAME CONSTRAINT \(oldName) TO \(newName)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(table) DROP COLUMN \(columnName)"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }
}

struct CheckConstraintStatementTests {
    private func constraint(
        name: String,
        expression: String
    ) -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(
            id: UUID(), name: name, expression: expression, columns: [], isValidated: true
        )
    }

    private func generator(_ driver: ConstraintDDLDriver) -> SchemaStatementGenerator {
        SchemaStatementGenerator(tableName: "orders", pluginDriver: driver)
    }

    @Test("adding a constraint emits one ADD CONSTRAINT")
    func addEmitsOneStatement() throws {
        let statements = try generator(ConstraintDDLDriver())
            .generate(changes: [.addCheckConstraint(constraint(name: "ck_total", expression: "total > 0"))])
        #expect(statements.count == 1)
        #expect(statements[0].sql == "ALTER TABLE orders ADD CONSTRAINT ck_total CHECK (total > 0);")
    }

    @Test("a rename alone is a rename, never a drop and re-add that rescans the table")
    func renameOnlyEmitsRename() throws {
        let old = constraint(name: "ck_old", expression: "total > 0")
        var new = old
        new.name = "ck_new"

        let statements = try generator(ConstraintDDLDriver())
            .generate(changes: [.modifyCheckConstraint(old: old, new: new)])
        #expect(statements.count == 1)
        #expect(statements[0].sql.contains("RENAME CONSTRAINT"))
    }

    @Test("on an engine with no RENAME CONSTRAINT a rename falls back to drop and re-add")
    func renameFallsBackWhereUnsupported() throws {
        let driver = ConstraintDDLDriver()
        driver.supportsRename = false
        let old = constraint(name: "ck_old", expression: "total > 0")
        var new = old
        new.name = "ck_new"

        let statements = try generator(driver).generate(changes: [.modifyCheckConstraint(old: old, new: new)])
        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("DROP CONSTRAINT ck_old"))
        #expect(statements[1].sql.contains("ADD CONSTRAINT ck_new"))
    }

    @Test("changing the expression drops then re-adds, in that order")
    func expressionChangeDropsThenAdds() throws {
        let old = constraint(name: "ck_total", expression: "total > 0")
        var new = old
        new.expression = "total >= 0"

        let statements = try generator(ConstraintDDLDriver())
            .generate(changes: [.modifyCheckConstraint(old: old, new: new)])
        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("DROP CONSTRAINT ck_total"))
        #expect(statements[1].sql.contains("ADD CONSTRAINT ck_total CHECK (total >= 0)"))
    }

    @Test("a constraint is dropped before the column it references, and added after")
    func constraintOrderingBracketsColumnChanges() throws {
        let dropped = constraint(name: "ck_old", expression: "total > 0")
        let added = constraint(name: "ck_new", expression: "qty > 0")
        var column = EditableColumnDefinition.placeholder()
        column.name = "qty"
        column.dataType = "int"

        let statements = try generator(ConstraintDDLDriver()).generate(changes: [
            .addCheckConstraint(added),
            .addColumn(column),
            .deleteCheckConstraint(dropped)
        ])

        let kinds = statements.map(\.sql)
        #expect(kinds.count == 3)
        #expect(kinds[0].contains("DROP CONSTRAINT ck_old"))
        #expect(kinds[1].contains("ADD COLUMN qty"))
        #expect(kinds[2].contains("ADD CONSTRAINT ck_new"))
    }

    /// The structure editor lets a new constraint take a deleted one's name on the strength of this
    /// order, whichever of the two was staged first.
    @Test("a deleted constraint is dropped before another is added under its name")
    func deletedNameIsFreeBeforeAnAdd() throws {
        let statements = try generator(ConstraintDDLDriver()).generate(changes: [
            .addCheckConstraint(constraint(name: "ck", expression: "qty < 10")),
            .deleteCheckConstraint(constraint(name: "ck", expression: "qty > 0"))
        ])

        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT ck;",
            "ALTER TABLE orders ADD CONSTRAINT ck CHECK (qty < 10);"
        ])
    }

    @Test("a deleted constraint is dropped before another is renamed onto its name")
    func deletedNameIsFreeBeforeARename() throws {
        let kept = constraint(name: "ck_b", expression: "qty < 10")
        var renamed = kept
        renamed.name = "ck"

        let statements = try generator(ConstraintDDLDriver()).generate(changes: [
            .modifyCheckConstraint(old: kept, new: renamed),
            .deleteCheckConstraint(constraint(name: "ck", expression: "qty > 0"))
        ])

        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT ck;",
            "ALTER TABLE orders RENAME CONSTRAINT ck_b TO ck;"
        ])
    }

    private func renamed(_ name: String, to newName: String, expression: String) -> SchemaChange {
        let old = constraint(name: name, expression: expression)
        var new = old
        new.name = newName
        return .modifyCheckConstraint(old: old, new: new)
    }

    /// `c` renamed to `b`, `a` deleted, then `b` renamed to `a`, in the order the user staged them.
    private var renameChain: [SchemaChange] {
        [
            renamed("c", to: "b", expression: "z > 0"),
            .deleteCheckConstraint(constraint(name: "a", expression: "x > 0")),
            renamed("b", to: "a", expression: "y > 0")
        ]
    }

    /// Measured on PostgreSQL 17.11: after `DROP CONSTRAINT a`, `RENAME CONSTRAINT c TO b` fails while
    /// `b` exists, and renaming `b` to `a` first, then `c` to `b`, commits.
    @Test("a rename onto a name another rename frees runs after that rename")
    func renameChainRunsInNameOrder() throws {
        let statements = try generator(ConstraintDDLDriver()).generate(changes: renameChain)

        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT a;",
            "ALTER TABLE orders RENAME CONSTRAINT b TO a;",
            "ALTER TABLE orders RENAME CONSTRAINT c TO b;"
        ])
    }

    /// MySQL, MariaDB and SQLite have no `RENAME CONSTRAINT`, so each rename is a drop and an add.
    /// Measured on MariaDB 13.0.2: in staging order the add of `b` fails with ERROR 1826 after `a` and
    /// `c` are dropped, and the table is left with `b` alone.
    @Test("a rename chain on an engine with no RENAME CONSTRAINT runs in name order")
    func renameChainWithoutRenameRunsInNameOrder() throws {
        let driver = ConstraintDDLDriver()
        driver.supportsRename = false

        let statements = try generator(driver).generate(changes: renameChain)

        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT a;",
            "ALTER TABLE orders DROP CONSTRAINT b;",
            "ALTER TABLE orders ADD CONSTRAINT a CHECK (y > 0);",
            "ALTER TABLE orders DROP CONSTRAINT c;",
            "ALTER TABLE orders ADD CONSTRAINT b CHECK (z > 0);"
        ])
    }

    @Test("two constraints trading names are dropped and added back")
    func swappedNamesAreDroppedAndAddedBack() throws {
        let statements = try generator(ConstraintDDLDriver()).generate(changes: [
            renamed("a", to: "b", expression: "x > 0"),
            renamed("b", to: "a", expression: "y > 0")
        ])

        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT a;",
            "ALTER TABLE orders DROP CONSTRAINT b;",
            "ALTER TABLE orders ADD CONSTRAINT b CHECK (x > 0);",
            "ALTER TABLE orders ADD CONSTRAINT a CHECK (y > 0);"
        ])
    }

    @Test("adding a check scans every existing row, so it counts as a data migration")
    func addingAConstraintRequiresDataMigration() {
        let change = SchemaChange.addCheckConstraint(constraint(name: "ck", expression: "a > 0"))
        #expect(change.requiresDataMigration)
    }

    @Test("dropping is destructive, and so is an expression change, because it re-adds")
    func destructiveClassification() {
        let target = constraint(name: "ck", expression: "a > 0")
        var changedExpression = target
        changedExpression.expression = "a > 1"

        #expect(SchemaChange.deleteCheckConstraint(target).isDestructive)
        #expect(SchemaChange.modifyCheckConstraint(old: target, new: changedExpression).isDestructive)
        #expect(!SchemaChange.addCheckConstraint(target).isDestructive)
        #expect(SchemaChange.deleteCheckConstraint(target).isDelete)
    }

    /// A rename is one native statement that touches no rows, so warning about data loss would be
    /// a false alarm on every rename.
    @Test("a pure rename is neither destructive nor a data migration")
    func renameIsNotDestructive() {
        let old = constraint(name: "ck_old", expression: "a > 0")
        var renamed = old
        renamed.name = "ck_new"

        #expect(!SchemaChange.modifyCheckConstraint(old: old, new: renamed).isDestructive)
        #expect(!SchemaChange.modifyCheckConstraint(old: old, new: renamed).requiresDataMigration)
    }
}
