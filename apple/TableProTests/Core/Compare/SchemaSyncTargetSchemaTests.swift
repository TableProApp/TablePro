import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SchemaQualifyingDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { "session" }

    private func qualified(_ table: String, _ schema: String?) -> String {
        "\(schema ?? "session").\(table)"
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition, schema: String?) -> [String]? {
        ["CREATE TABLE \(qualified(definition.tableName, schema))"]
    }

    func generateAddColumnSQL(table: String, schema: String?, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualified(table, schema)) ADD \(column.name)"
    }

    func generateAddIndexSQL(table: String, schema: String?, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(qualified(table, schema))"
    }
}

struct SchemaSyncTargetSchemaTests {
    private let driver = SchemaQualifyingDriver()

    @Test("Create and alter name the target's schema, not the source snapshot's or the session's")
    func statementsNameTheTargetSchema() throws {
        let builder = SchemaSyncScriptBuilder(targetDriver: driver, targetDatabaseType: .postgresql, targetSchema: "archive")
        let source = TableStructureSnapshot(
            name: "orders", schema: "sales", columns: [TestFixtures.makeEditableColumn(isPrimaryKey: true)]
        )
        let statements = try builder.build(
            operations: [
                .createTable(source),
                .alterTable(
                    name: "customers", schema: "sales",
                    changes: [.addColumn(TestFixtures.makeEditableColumn(name: "note", dataType: "TEXT"))]
                )
            ],
            foreignKeysByTable: [:]
        )

        let sql = statements.map(\.sql)
        #expect(sql == ["CREATE TABLE archive.orders", "ALTER TABLE archive.customers ADD note"])
    }

    @Test("A Structure save names its scope's schema")
    func generatorNamesItsSchema() throws {
        let generator = SchemaStatementGenerator(tableName: "orders", schema: "sales", pluginDriver: driver)
        let sql = try generator.generate(changes: [
            .addColumn(TestFixtures.makeEditableColumn(name: "note", dataType: "TEXT")),
            .addIndex(TestFixtures.makeEditableIndex(name: "orders_note", columns: ["note"]))
        ]).map(\.sql)

        #expect(sql == ["ALTER TABLE sales.orders ADD note;", "CREATE INDEX orders_note ON sales.orders;"])
    }
}
