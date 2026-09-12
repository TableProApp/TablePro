//
//  SchemaOperationRefusalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RefusingDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    var refuse: (PluginSchemaOperation) -> String? = { _ in nil }

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

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? { refuse(operation) }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (...)"
    }
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(table)"
    }
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        "ALTER TABLE \(table) ADD CONSTRAINT \(constraint.name) CHECK (\(constraint.expression))"
    }
    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(table) DROP CONSTRAINT \(constraintName)"
    }
}

private enum RefusalReason {
    static let generated = "Column total is a generated column, which needs PostgreSQL 12 or later."
    static let brin = "BRIN indexes need PostgreSQL 9.5 or later."
    static let rename = "Renaming a check constraint needs PostgreSQL 9.2 or later."
}

@MainActor @Suite("Schema operation refusal")
struct SchemaOperationRefusalTests {
    private static let generatedReason = RefusalReason.generated
    private static let brinReason = RefusalReason.brin
    private static let renameReason = RefusalReason.rename

    private func legacyDriver() -> RefusingDDLDriver {
        let driver = RefusingDDLDriver()
        driver.refuse = { operation in
            switch operation {
            case .addColumn(let column):
                return column.isGenerated ? RefusalReason.generated : nil
            case .addIndex(let index):
                return index.indexType == "BRIN" ? RefusalReason.brin : nil
            case .renameCheckConstraint:
                return RefusalReason.rename
            @unknown default:
                return nil
            }
        }
        return driver
    }

    private func column(_ name: String, generated: Bool) -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = "integer"
        if generated {
            column.generationKind = .stored
            column.generationExpression = "qty * price"
        }
        return column
    }

    private func index(_ name: String, type: EditableIndexDefinition.IndexType) -> EditableIndexDefinition {
        var index = EditableIndexDefinition.placeholder()
        index.name = name
        index.columns = ["qty"]
        index.type = type
        return index
    }

    private func constraint(_ name: String, _ expression: String) -> EditableCheckConstraintDefinition {
        EditableCheckConstraintDefinition(id: UUID(), name: name, expression: expression, columns: [], isValidated: true)
    }

    private func refusal(of change: SchemaChange, driver: RefusingDDLDriver) -> String? {
        do {
            _ = try SchemaStatementGenerator(tableName: "orders", pluginDriver: driver).generate(changes: [change])
            return nil
        } catch let error as SchemaOperationRefusedError {
            return error.reason
        } catch {
            return "unexpected: \(error.localizedDescription)"
        }
    }

    private func refusalOfBatch(_ changes: [SchemaChange], driver: RefusingDDLDriver) -> String? {
        do {
            _ = try SchemaStatementGenerator(tableName: "orders", pluginDriver: driver).generate(changes: changes)
            return nil
        } catch let error as SchemaOperationRefusedError {
            return error.reason
        } catch {
            return "unexpected: \(error.localizedDescription)"
        }
    }

    @Test("A refused column is reported with the driver's reason, not a generic unsupported message")
    func refusedColumnSurfacesReason() {
        #expect(refusal(of: .addColumn(column("total", generated: true)), driver: legacyDriver()) == Self.generatedReason)
        #expect(refusal(of: .addColumn(column("qty", generated: false)), driver: legacyDriver()) == nil)
    }

    @Test("A refused index is reported whether it is added or modified")
    func refusedIndexSurfacesReason() {
        let driver = legacyDriver()
        #expect(refusal(of: .addIndex(index("ix_brin", type: .brin)), driver: driver) == Self.brinReason)
        let modify = SchemaChange.modifyIndex(old: index("ix", type: .btree), new: index("ix", type: .brin))
        #expect(refusal(of: modify, driver: driver) == Self.brinReason)
        #expect(refusal(of: .addIndex(index("ix_btree", type: .btree)), driver: driver) == nil)
    }

    @Test("A refusal is reported ahead of a change in the same save that the driver cannot generate")
    func refusalWinsOverUngeneratableChange() {
        let unsupportedDrop = SchemaChange.deleteIndex(index("ix_old", type: .btree))
        let refusedAdd = SchemaChange.addIndex(index("ix_brin", type: .brin))
        #expect(refusal(of: unsupportedDrop, driver: legacyDriver())?.hasPrefix("unexpected:") == true)
        #expect(refusalOfBatch([unsupportedDrop, refusedAdd], driver: legacyDriver()) == Self.brinReason)
    }

    @Test("A refused rename stays refused and never turns into a drop and re-add")
    func refusedRenameIsNotDroppedAndReAdded() {
        let rename = SchemaChange.modifyCheckConstraint(old: constraint("ck_a", "qty > 0"), new: constraint("ck_b", "qty > 0"))
        #expect(refusal(of: rename, driver: legacyDriver()) == Self.renameReason)
    }

    @Test("An expression change is a drop and re-add, which a rename refusal does not block")
    func expressionChangeIsNotARename() throws {
        let change = SchemaChange.modifyCheckConstraint(old: constraint("ck_a", "qty > 0"), new: constraint("ck_a", "qty > 1"))
        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: legacyDriver())
            .generate(changes: [change])
        #expect(statements.map(\.sql) == [
            "ALTER TABLE orders DROP CONSTRAINT ck_a;",
            "ALTER TABLE orders ADD CONSTRAINT ck_a CHECK (qty > 1);"
        ])
    }

    @Test("A driver that never refuses generates as before")
    func defaultDriverRefusesNothing() throws {
        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: RefusingDDLDriver())
            .generate(changes: [.addColumn(column("total", generated: true))])
        #expect(statements.map(\.sql) == ["ALTER TABLE orders ADD COLUMN total;"])
    }

    @Test("Create Table names a refused column instead of saying the database cannot create tables")
    func createTableNamesRefusedColumn() {
        let plan = CreateTablePlan(
            definition: PluginCreateTableDefinition(
                tableName: "orders",
                columns: [column("qty", generated: false).toPlugin(), column("total", generated: true).toPlugin()],
                primaryKeyColumns: []
            ),
            indexes: [],
            issues: []
        )
        let composed = CreateTableStatementComposer.compose(plan: plan, driver: legacyDriver())
        #expect(composed.statements.isEmpty)
        #expect(composed.issues.map(\.message) == [Self.generatedReason])
        #expect(composed.issues.first?.tab == .columns)
    }

    @Test("Create Table flags a refused index on its own row and still creates the table")
    func createTableFlagsRefusedIndexRow() {
        let plan = CreateTablePlan(
            definition: PluginCreateTableDefinition(
                tableName: "orders",
                columns: [column("qty", generated: false).toPlugin()],
                primaryKeyColumns: []
            ),
            indexes: [index("ix_btree", type: .btree).toPlugin(), index("ix_brin", type: .brin).toPlugin()],
            issues: []
        )
        let composed = CreateTableStatementComposer.compose(plan: plan, driver: legacyDriver())
        #expect(composed.statements == ["CREATE TABLE orders (...)", "CREATE INDEX ix_btree ON orders"])
        #expect(composed.issues.count == 1)
        #expect(composed.issues.first?.tab == .indexes)
        #expect(composed.issues.first?.row == 1)
        #expect(composed.issues.first?.message == Self.brinReason)
    }

    @Test("Schema sync refuses to create a table the target cannot hold, naming table and reason")
    func schemaSyncRefusesCreateTable() {
        let snapshot = TableStructureSnapshot(name: "orders", columns: [column("total", generated: true)])
        let builder = SchemaSyncScriptBuilder(targetDriver: legacyDriver())
        do {
            _ = try builder.build(operations: [.createTable(snapshot)], foreignKeysByTable: [:])
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("orders"))
            #expect(error.localizedDescription.contains(Self.generatedReason))
        }
    }

    @Test("Schema sync refuses to add a column the target cannot hold")
    func schemaSyncRefusesAlterTable() {
        let builder = SchemaSyncScriptBuilder(targetDriver: legacyDriver())
        do {
            _ = try builder.build(
                operations: [.alterTable(name: "orders", schema: nil, changes: [.addColumn(column("total", generated: true))])],
                foreignKeysByTable: [:]
            )
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == Self.generatedReason)
        }
    }
}
