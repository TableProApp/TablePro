import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLExportCatalogTests {
    private static let capabilities = PostgreSQLCapabilities(serverVersion: 170_000)

    private static func listing(_ schema: String) -> String {
        PostgreSQLTableListing.query(
            schema: schema,
            includeMaterializedViews: true,
            includeForeignTables: true,
            includeComments: false,
            includePartitionAwareness: true
        )
    }

    private static let salesReplies: [String: [[PluginCellValue]]] = [
        listing("sales"): [
            ["orders", "BASE TABLE", nil, nil],
            ["events", "PARTITIONED TABLE", nil, "2"],
            ["recent", "VIEW", nil, nil],
            ["totals", "MATERIALIZED VIEW", nil, nil],
            ["remote", "FOREIGN TABLE", nil, nil],
        ],
        PostgreSQLObjectQueries.routineList(schema: "sales", capabilities: capabilities): [
            ["16401", "f", "sales", "(integer)", "integer", "sql", "f"],
            ["16402", "f", "sales", "(text)", nil, "plpgsql", "p"],
        ],
        PostgreSQLObjectQueries.triggerList(schema: "sales", table: nil): [
            ["audit", "orders", "sales", "AFTER", "INSERT", "ROW", "O", "CREATE TRIGGER audit AFTER INSERT ON sales.orders"],
        ],
        PostgreSQLObjectQueries.routineDefinition(identity: "16402"): [["CREATE PROCEDURE sales.f(text) AS $$ $$"]],
    ]

    private static func catalog(_ reads: RecordedCatalogReads) -> PostgreSQLMobileExportCatalog {
        PostgreSQLMobileExportCatalog(
            catalog: PostgreSQLCatalogExport(
                read: { statement, _ in try reads.rows(statement) },
                currentSchema: "public",
                capabilities: capabilities,
                catalogCapabilities: capabilities,
                catalogPresence: nil
            ),
            sessionScope: nil,
            script: ExportCatalogScript(databaseTypeId: DatabaseType.postgresql.rawValue, session: nil),
            standardConformingStrings: true
        )
    }

    @Test("Every kind the Mac exports is listed under its schema, a partitioned table once as a table")
    func listsEveryKind() async throws {
        let objects = try await Self.catalog(RecordedCatalogReads(Self.salesReplies))
            .exportObjects(database: "app", schema: "sales")

        #expect(objects.map(\.name) == ["orders", "events", "recent", "totals", "remote", "f", "f", "audit"])
        #expect(objects.map(\.kind) == [
            .table, .table, .view, .materializedView, .foreignTable, .routine, .routine, .trigger,
        ])
        #expect(objects.map(\.tableType) == [
            "table", "table", "view", "materializedView", "foreignTable", "function", "procedure", "trigger",
        ])
        #expect(objects.allSatisfy { $0.databaseName == "sales" && $0.schema == "sales" })
        #expect(objects[5].identity == "(integer)")
        #expect(objects[6].identity == "(text)")
        #expect(objects[7].parentTable == "orders")
    }

    @Test("No schema lists the session's own")
    func listsTheCurrentSchema() async throws {
        let reads = RecordedCatalogReads([Self.listing("public"): [["t", "BASE TABLE", nil, nil]]])
        let objects = try await Self.catalog(reads).exportObjects(database: "app", schema: nil)

        #expect(objects.map(\.name) == ["t"])
        #expect(objects.first?.databaseName == "public")
    }

    @Test("A server that refuses the catalog listing is listed from information_schema")
    func listingFallsBack() async throws {
        let fallback = PostgreSQLTableListing.informationSchemaQuery(in: .schema("sales"))
        let reads = RecordedCatalogReads([fallback: [["orders", "BASE TABLE", nil, nil]]], failing: [Self.listing("sales")])
        let objects = try await Self.catalog(reads).exportObjects(database: "app", schema: "sales")

        #expect(objects.map(\.name) == ["orders"])
        #expect(reads.statements.contains(fallback))
    }

    @Test("A schema read naming two tables alike in different Unicode forms throws, so the dump reads each table alone")
    func unicodeFormsOfOneNameThrow() async throws {
        let composed = PluginCellValue.text("caf\u{E9}")
        let decomposed = PluginCellValue.text("cafe\u{301}")
        let columns = PostgreSQLSchemaQueries.columnsQuery(
            schema: "sales", table: nil, capabilities: Self.capabilities, includeMaterializedViews: true
        )
        let foreignKeys = PostgreSQLForeignKeyQueries.foreignKeyList(
            schema: "sales", table: nil, capabilities: Self.capabilities
        )
        let reads = RecordedCatalogReads([
            columns: [[composed, "a", "integer", "YES", nil], [decomposed, "b", "text", "YES", nil]],
            foreignKeys: [
                [composed, "a_fk", "a", "parent", "id", "sales", "NO ACTION", "NO ACTION"],
                [decomposed, "b_fk", "b", "parent", "id", "sales", "NO ACTION", "NO ACTION"],
            ],
        ])
        let catalog = Self.catalog(reads)

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "sales")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "sales")
        }
    }

    @Test("A routine's definition is read for the routine of its own kind and signature")
    func routineDDLMatchesKind() async throws {
        let catalog = Self.catalog(RecordedCatalogReads(Self.salesReplies))
        let objects = try await catalog.exportObjects(database: "app", schema: "sales")
        let procedure = try #require(objects.first(where: { $0.tableType == "procedure" }))

        #expect(try await catalog.fetchObjectDDL(procedure) == "CREATE PROCEDURE sales.f(text) AS $$ $$")
    }

    @Test("Drops name the routine's kind and signature, and the trigger's table")
    func dropStatements() async throws {
        let catalog = Self.catalog(RecordedCatalogReads(Self.salesReplies))
        let objects = try await catalog.exportObjects(database: "app", schema: "sales")

        #expect(catalog.dropStatement(for: objects[5]) == "DROP FUNCTION IF EXISTS \"sales\".\"f\"(integer)")
        #expect(catalog.dropStatement(for: objects[6]) == "DROP PROCEDURE IF EXISTS \"sales\".\"f\"(text)")
        #expect(catalog.dropStatement(for: objects[7]) == "DROP TRIGGER IF EXISTS \"audit\" ON \"sales\".\"orders\"")
        #expect(catalog.dropStatement(for: objects[0]) == nil)
    }

    @Test("Literals follow the session's standard_conforming_strings, as the Mac's driver writes them")
    func literalEscaping() {
        let reads = RecordedCatalogReads()
        let standard = Self.catalog(reads)
        let backslash = PostgreSQLMobileExportCatalog(
            catalog: standard.catalog, sessionScope: nil, script: standard.script, standardConformingStrings: false
        )

        #expect(standard.escapeStringLiteral("it's \\ here") == "it''s \\ here")
        #expect(backslash.escapeStringLiteral("it's \\ here") == "it''s \\\\ here")
        #expect(standard.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(standard.supportsCascadeDrop)
        #expect(!standard.tableDDLIncludesForeignKeys)
    }

    // MARK: - Write dialect

    private static let columns = [
        ColumnInfo(name: "a", typeName: "integer", ordinalPosition: 0),
        ColumnInfo(name: "b", typeName: "text", ordinalPosition: 1),
    ]

    private static func dialect(buildsTables: Bool = true) -> PostgreSQLMobileWriteDialect {
        PostgreSQLMobileWriteDialect(
            databaseTypeId: DatabaseType.postgresql.rawValue,
            currentSchema: "public",
            capabilities: capabilities,
            buildsTables: buildsTables
        )
    }

    @Test("Rows bind as $n into the schema-qualified table")
    func importStatementsBindDollar() async throws {
        let statements = try await Self.dialect().importStatements(table: "t", schema: "sales", columns: Self.columns)
        let insert = try #require(statements.insertStatement(columns: ["a", "b"], values: [.text("1"), .null]))

        #expect(insert.sql == "INSERT INTO \"sales\".\"t\" (\"a\", \"b\") VALUES ($1, $2)")
        #expect(insert.parameters == [.text("1"), .null])
    }

    @Test("A new table is created in the import's schema, or the session's when it names none")
    func createTableSchema() throws {
        let definition = PluginCreateTableDefinition(
            tableName: "t",
            columns: [PluginColumnDefinition(name: "a", dataType: "integer", isNullable: false, isPrimaryKey: true)]
        )

        let named = try Self.dialect().createTableStatements(definition: definition, schema: "sales")
        let unnamed = try Self.dialect().createTableStatements(definition: definition, schema: nil)

        #expect(named.first?.hasPrefix("CREATE TABLE \"sales\".\"t\" (") == true)
        #expect(unnamed.first?.hasPrefix("CREATE TABLE \"public\".\"t\" (") == true)
    }

    @Test("Redshift refuses a new table as the Mac does, and still takes rows into an existing one")
    func redshiftRefusesNewTables() async throws {
        let definition = PluginCreateTableDefinition(
            tableName: "t", columns: [PluginColumnDefinition(name: "a", dataType: "integer")]
        )
        let redshift = Self.dialect(buildsTables: false)

        #expect(throws: ImportTableNames.noStatement) {
            _ = try redshift.createTableStatements(definition: definition, schema: "public")
        }
        let statements = try await redshift.importStatements(table: "t", schema: nil, columns: Self.columns)
        #expect(statements.insertStatement(columns: ["a"], values: [.text("1")])?.sql == "INSERT INTO \"t\" (\"a\") VALUES ($1)")
    }
}
