import Foundation
import TableProPluginKit
import Testing

private final class SchemaLessDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? { "add \(table)" }
    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? { "modify \(table)" }
    func generateDropColumnSQL(table: String, columnName: String) -> String? { "drop \(table)" }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? { "index \(table)" }
    func generateDropIndexSQL(table: String, indexName: String) -> String? { "drop index \(table)" }
    func generateModifyIndexSQL(table: String, oldIndexName: String, newIndex: PluginIndexDefinition) -> String? {
        "replace index \(table)"
    }
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? { "fk \(table)" }
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? { "drop fk \(table)" }
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        "check \(table)"
    }
    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? { "drop check \(table)" }
    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String? {
        "rename check \(table)"
    }
    func generateModifyPrimaryKeySQL(
        table: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? { ["pk \(table)"] }
    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? { "create \(definition.tableName)" }
}

struct PluginSchemaDDLDefaultsTests {
    private let driver: any PluginDatabaseDriver = SchemaLessDDLDriver()
    private let column = PluginColumnDefinition(name: "c", dataType: "TEXT")

    @Test("A driver that answers only the schema-less generators answers the schema-taking ones")
    func schemaTakingDefaultsForward() {
        let index = PluginIndexDefinition(name: "i", columns: ["c"])
        let fk = PluginForeignKeyDefinition(name: "f", columns: ["c"], referencedTable: "u", referencedColumns: ["id"])
        let check = PluginCheckConstraintDefinition(name: "k", expression: "c <> ''")

        #expect(driver.generateAddColumnSQL(table: "t", schema: "s", column: column) == "add t")
        #expect(driver.generateModifyColumnSQL(table: "t", schema: "s", oldColumn: column, newColumn: column) == "modify t")
        #expect(driver.generateDropColumnSQL(table: "t", schema: "s", columnName: "c") == "drop t")
        #expect(driver.generateAddIndexSQL(table: "t", schema: "s", index: index) == "index t")
        #expect(driver.generateDropIndexSQL(table: "t", schema: "s", indexName: "i") == "drop index t")
        #expect(driver.generateModifyIndexSQL(table: "t", schema: "s", oldIndexName: "i", newIndex: index) == "replace index t")
        #expect(driver.generateAddForeignKeySQL(table: "t", schema: "s", fk: fk) == "fk t")
        #expect(driver.generateDropForeignKeySQL(table: "t", schema: "s", constraintName: "f") == "drop fk t")
        #expect(driver.generateAddCheckConstraintSQL(table: "t", schema: "s", constraint: check) == "check t")
        #expect(driver.generateDropCheckConstraintSQL(table: "t", schema: "s", constraintName: "k") == "drop check t")
        #expect(driver.generateRenameCheckConstraintSQL(table: "t", schema: "s", from: "k", to: "m") == "rename check t")
        #expect(
            driver.generateModifyPrimaryKeySQL(
                table: "t", schema: "s", oldColumns: [], newColumns: ["c"], constraintName: nil
            ) == ["pk t"]
        )
        #expect(
            driver.generateCreateTableStatements(
                definition: PluginCreateTableDefinition(tableName: "t", columns: [column]), schema: "s"
            ) == ["create t"]
        )
    }
}
