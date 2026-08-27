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

@Suite("Check constraint statement generation")
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
