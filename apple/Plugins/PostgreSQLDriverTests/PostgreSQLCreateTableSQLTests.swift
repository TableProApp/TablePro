import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLCreateTableSQLTests {
    private static let pg17 = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let pg18 = PostgreSQLCapabilities(serverVersion: 180_000)

    @Test("A single key is declared inline and a column comment follows the table")
    func singleKeyInlineWithComment() throws {
        let definition = PluginCreateTableDefinition(
            tableName: "orders",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "note", dataType: "text", defaultValue: "'x'", comment: "Free text")
            ]
        )
        let statements = try #require(PostgreSQLCreateTableSQL.statements(definition, schema: "app", capabilities: Self.pg17))

        #expect(statements == [
            """
            CREATE TABLE "app"."orders" (
              "id" integer NOT NULL PRIMARY KEY,
              "note" text NULL DEFAULT 'x'
            )
            """,
            #"COMMENT ON COLUMN "app"."orders"."note" IS 'Free text'"#
        ])
    }

    @Test("A composite key and a foreign key are table constraints")
    func compositeKeyAndForeignKey() throws {
        let definition = PluginCreateTableDefinition(
            tableName: "child",
            columns: [
                PluginColumnDefinition(name: "a", dataType: "integer", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "b", dataType: "integer", isNullable: false, isPrimaryKey: true)
            ],
            foreignKeys: [
                PluginForeignKeyDefinition(
                    name: "child_fk", columns: ["a"], referencedTable: "parents", referencedColumns: ["id"],
                    onDelete: "CASCADE", referencedSchema: "core"
                )
            ]
        )
        let parts = try #require(PostgreSQLCreateTableSQL.parts(definition, schema: "app", capabilities: Self.pg17))

        #expect(parts.qualifiedTable == #""app"."child""#)
        #expect(parts.createTable == """
            CREATE TABLE "app"."child" (
              "a" integer NOT NULL,
              "b" integer NOT NULL,
              PRIMARY KEY ("a", "b"),
              CONSTRAINT "child_fk" FOREIGN KEY ("a") REFERENCES "core"."parents" ("id") ON DELETE CASCADE
            )
            """)
        #expect(parts.indexStatements.isEmpty)
    }

    @Test("A serial column states no nullability")
    func serialColumn() {
        let column = PluginColumnDefinition(name: "id", dataType: "BIGINT", isNullable: false, autoIncrement: true)
        #expect(PostgreSQLCreateTableSQL.columnDefinition(column, inlinePK: false, capabilities: Self.pg17)
            == #""id" BIGSERIAL"#)
    }

    @Test("A generated column is STORED before PostgreSQL 18 and keeps its kind from 18")
    func generatedColumnKeyword() {
        let column = PluginColumnDefinition(
            name: "total", dataType: "integer", generationExpression: "a * 2", generationKind: nil,
            ddlSpelling: nil, ddlDefault: nil, ddlGenerationExpression: nil, ddlCollation: nil, columnCheck: nil
        )
        #expect(PostgreSQLCreateTableSQL.columnDefinition(column, inlinePK: false, capabilities: Self.pg17)
            == #""total" integer GENERATED ALWAYS AS (a * 2) STORED"#)
        #expect(PostgreSQLCreateTableSQL.columnDefinition(column, inlinePK: false, capabilities: Self.pg18)
            == #""total" integer GENERATED ALWAYS AS (a * 2) VIRTUAL"#)
    }

    @Test("A table with no columns writes nothing")
    func noColumnsWritesNothing() {
        let definition = PluginCreateTableDefinition(tableName: "empty", columns: [])
        #expect(PostgreSQLCreateTableSQL.statements(definition, schema: "app", capabilities: Self.pg17) == nil)
    }

    @Test("The plugin driver writes its table in the session's schema through the shared writer")
    func driverForwardsToTheWriter() {
        let driver = PostgreSQLPluginDriver(
            config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: "")
        )
        let definition = PluginCreateTableDefinition(
            tableName: "orders",
            columns: [PluginColumnDefinition(name: "id", dataType: "integer", isPrimaryKey: true)]
        )
        #expect(driver.generateCreateTableStatements(definition: definition)
            == PostgreSQLCreateTableSQL.statements(definition, schema: "public", capabilities: driver.versionedCapabilities))
    }
}
