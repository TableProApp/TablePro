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

    var checkRefusal: String?
    var checkConstraintRefusal: String? { checkRefusal }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (...)"
    }
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(table)"
    }
    func generateModifyIndexSQL(table: String, oldIndexName: String, newIndex: PluginIndexDefinition) -> String? {
        "ALTER TABLE \(table) REPLACE INDEX \(oldIndexName) ON (\(newIndex.columns.joined(separator: ", ")))"
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

@MainActor
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

    @Test("An index edited in place and a dropped index reach the driver as their own operations")
    func modifyAndDropIndexReachTheDriver() {
        let driver = RefusingDDLDriver()
        driver.refuse = { operation in
            switch operation {
            case .modifyIndex(let old, let new): return "modify \(old.name) to \(new.name)"
            case .dropIndex(let index) where index.name == "ix_old": return "drop \(index.name)"
            default: return nil
            }
        }
        let modify = SchemaChange.modifyIndex(old: index("ix", type: .btree), new: index("ix", type: .hash))

        #expect(refusal(of: modify, driver: driver) == "modify ix to ix")
        #expect(refusal(of: .deleteIndex(index("ix_old", type: .btree)), driver: driver) == "drop ix_old")
    }

    /// A replacement is a drop and an add, so an index the driver will not drop is refused for that,
    /// ahead of the advice about replacing it. DynamoDB answered a local index's replacement with
    /// "delete it and save", and the delete was then refused for a different reason.
    @Test("Replacing an index asks first whether the old one can be dropped")
    func replacementAsksTheDropFirst() {
        let driver = RefusingDDLDriver()
        driver.refuse = { operation in
            switch operation {
            case .dropIndex(let index): return "drop \(index.name)"
            case .modifyIndex: return "replace"
            default: return nil
            }
        }
        let modify = SchemaChange.modifyIndex(old: index("ix", type: .btree), new: index("ix", type: .hash))

        #expect(refusal(of: modify, driver: driver) == "drop ix")
    }

    @Test("An index deleted and added back under its name asks the driver about one replacement")
    func sameNameDropAndAddAskForAReplacement() {
        let driver = RefusingDDLDriver()
        driver.refuse = { operation in
            guard case .modifyIndex(let old, _) = operation else { return nil }
            return "replace \(old.name)"
        }
        var replacement = index("ix", type: .btree)
        replacement.columns = ["total"]

        #expect(refusalOfBatch([.deleteIndex(index("ix", type: .btree)), .addIndex(replacement)], driver: driver) == "replace ix")
    }

    @Test("What the driver is asked about and the statements it writes describe the same replacement")
    func refusalAndStatementsAgreeOnTheReplacement() throws {
        let driver = RefusingDDLDriver()
        var asked: [String] = []
        driver.refuse = { operation in
            switch operation {
            case .modifyIndex(let old, let new): asked.append("modify \(old.name) \(old.columns) to \(new.columns)")
            case .addIndex(let index): asked.append("add \(index.name)")
            case .dropIndex(let index): asked.append("drop \(index.name)")
            default: break
            }
            return nil
        }
        var replacement = index("ix", type: .btree)
        replacement.columns = ["total"]

        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: driver)
            .generate(changes: [.addIndex(replacement), .deleteIndex(index("ix", type: .btree))])

        #expect(asked == ["drop ix", "modify ix [\"qty\"] to [\"total\"]", "add ix"])
        #expect(statements.map(\.sql) == ["ALTER TABLE orders REPLACE INDEX ix ON (total);"])
    }

    @Test("Indexes deleted and added under different names are not asked about as a replacement")
    func differentNamesAreNotAReplacement() {
        let driver = RefusingDDLDriver()
        var askedAboutReplacement = false
        driver.refuse = { operation in
            if case .modifyIndex = operation { askedAboutReplacement = true }
            return nil
        }

        _ = refusalOfBatch([.deleteIndex(index("ix_a", type: .btree)), .addIndex(index("ix_b", type: .btree))], driver: driver)
        #expect(!askedAboutReplacement)
    }

    /// Measured on MariaDB 13.0.2: with a column change in the same save the replacement splits,
    /// `DROP INDEX PRIMARY` commits, `ADD UNIQUE INDEX PRIMARY` fails with ERROR 1280, and the table
    /// is left with no key. The one-statement form fails the same way and keeps the key.
    @Test("A copy of MySQL's PRIMARY row put in place of the original is refused before anything runs")
    func mysqlPrimaryReplacementIsRefused() throws {
        let driver = RefusingDDLDriver()
        driver.refuse = { operation in
            guard case .addIndex(let index) = operation else { return nil }
            return mysqlReservedIndexNameRefusal(for: index)
        }
        var primary = index("PRIMARY", type: .btree)
        primary.isPrimary = true
        var copy = primary.withNewIdentity()
        copy.isPrimary = false
        let reason = try #require(mysqlReservedIndexNameRefusal(for: copy.toPlugin()))

        #expect(refusalOfBatch([.addIndex(copy), .deleteIndex(primary)], driver: driver) == reason)
        #expect(refusalOfBatch(
            [.addIndex(copy), .deleteIndex(primary), .addColumn(column("qty", generated: false))], driver: driver
        ) == reason)
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
        let builder = SchemaSyncScriptBuilder(targetDriver: legacyDriver(), targetDatabaseType: .postgresql)
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
        let builder = SchemaSyncScriptBuilder(targetDriver: legacyDriver(), targetDatabaseType: .postgresql)
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

    /// The server in front of the user, not the engine: MySQL before 8.0.16 answers `Query OK` to
    /// an `ADD CONSTRAINT ... CHECK` and throws the clause away.
    @Test("A server with no check constraints refuses every check change at save time")
    func serverWithoutChecksRefusesCheckChanges() {
        let driver = legacyDriver()
        driver.checkRefusal = "Check constraints need MySQL 8.0.16 or later."
        let added = constraint("c", "x > 0")
        #expect(refusal(of: .addCheckConstraint(added), driver: driver) == driver.checkRefusal)
        #expect(refusal(of: .deleteCheckConstraint(added), driver: driver) == driver.checkRefusal)
        let renamed = constraint("d", "x > 0")
        #expect(refusal(of: .modifyCheckConstraint(old: added, new: renamed), driver: driver) == driver.checkRefusal)
        let rewritten = constraint("c", "x > 1")
        #expect(refusal(of: .modifyCheckConstraint(old: added, new: rewritten), driver: driver) == driver.checkRefusal)
        #expect(refusal(of: .addColumn(column("qty", generated: false)), driver: driver) == nil)
    }

    @Test("A server that keeps check constraints refuses none of them")
    func serverWithChecksRefusesNothing() {
        let driver = legacyDriver()
        let added = constraint("c", "x > 0")
        #expect(refusal(of: .addCheckConstraint(added), driver: driver) == nil)
        #expect(refusal(of: .deleteCheckConstraint(added), driver: driver) == nil)
        #expect(refusal(
            of: .modifyCheckConstraint(old: added, new: constraint("c", "x > 1")), driver: driver
        ) == nil)
    }
}
