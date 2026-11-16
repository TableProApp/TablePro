import Foundation
@testable import TableProMobile
import TableProModels
import TableProMSSQLCore
import TableProPluginKit
import Testing

struct MSSQLTransferEngineTests {
    @Test("Bound values go as sp_executesql parameters typed by their values, as the Mac binds them")
    func boundStatementUsesSpExecuteSql() {
        let sql = MSSQLDriver.boundStatement(
            "INSERT INTO [dbo].[t] ([a], [b], [c]) VALUES (?, ?, ?)",
            parameters: [.text("it's"), .bytes(Data([0xAB, 0x01])), .null]
        )

        #expect(sql == "EXEC sp_executesql N'INSERT INTO [dbo].[t] ([a], [b], [c]) VALUES "
            + "(@__tablepro_p1, @__tablepro_p2, @__tablepro_p3)', "
            + "N'@__tablepro_p1 NVARCHAR(MAX), @__tablepro_p2 VARBINARY(MAX), @__tablepro_p3 NVARCHAR(MAX)', "
            + "@__tablepro_p1 = N'it''s', @__tablepro_p2 = 0xAB01, @__tablepro_p3 = NULL")
    }

    @Test("A statement with no values, or no placeholders, goes as it is")
    func unboundStatementIsUnchanged() {
        #expect(MSSQLDriver.boundStatement("DELETE FROM [dbo].[t]", parameters: []) == "DELETE FROM [dbo].[t]")
        #expect(MSSQLDriver.boundStatement("SELECT 1", parameters: [.text("x")]) == "SELECT 1")
    }

    private static let salesReplies: [String: [[PluginCellValue]]] = [
        MSSQLSchemaQueries.tables(schema: "sales"): [["orders", "BASE TABLE"], ["recent", "VIEW"]],
        MSSQLObjectQueries.routineList(schema: "sales"): [
            ["archive", "sales", "P ", "0", "0", "@before date", nil],
            ["total", "sales", "FN", "0", "0", "", "int"],
            ["concat_all", "sales", "AF", "0", "0", "@value nvarchar(4000)", "nvarchar"],
        ],
    ]

    private static func catalog(_ reads: RecordedCatalogReads) -> MSSQLMobileExportCatalog {
        MSSQLMobileExportCatalog(
            catalog: MSSQLExportCatalog(run: { try reads.result($0) }, currentSchema: "dbo"),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.mssql.rawValue, session: nil)
        )
    }

    @Test("Tables, views and routines are listed under their schema, each routine with its kind")
    func listsObjects() async throws {
        let objects = try await Self.catalog(RecordedCatalogReads(Self.salesReplies))
            .exportObjects(database: "shop", schema: "sales")

        #expect(objects.map(\.name) == ["orders", "recent", "archive", "total", "concat_all"])
        #expect(objects.map(\.kind) == [.table, .view, .routine, .routine, .routine])
        #expect(objects.map(\.tableType) == ["table", "view", "procedure", "function", "function"])
        #expect(objects.allSatisfy { $0.databaseName == "sales" && $0.schema == "sales" })
    }

    @Test("An empty schema is the session's own, never a schema named \"\"")
    func emptySchemaIsCurrent() async throws {
        let reads = RecordedCatalogReads([MSSQLSchemaQueries.tables(schema: "dbo"): [["t", "BASE TABLE"]]])
        let objects = try await Self.catalog(reads).exportObjects(database: "shop", schema: "")

        #expect(objects.map(\.name) == ["t"])
        #expect(objects.first?.databaseName == "dbo")
        #expect(!reads.statements.contains(MSSQLSchemaQueries.tables(schema: "")))
    }

    @Test("A routine drops with its own verb, a CLR aggregate as one, never DROP ROUTINE")
    func routineDrops() async throws {
        let catalog = Self.catalog(RecordedCatalogReads(Self.salesReplies))
        let objects = try await catalog.exportObjects(database: "shop", schema: "sales")

        #expect(catalog.dropStatement(for: objects[2]) == "DROP PROCEDURE IF EXISTS [sales].[archive]")
        #expect(catalog.dropStatement(for: objects[3]) == "DROP FUNCTION IF EXISTS [sales].[total]")
        #expect(catalog.dropStatement(for: objects[4]) == "DROP AGGREGATE IF EXISTS [sales].[concat_all]")
        #expect(catalog.dropStatement(for: objects[0]) == nil)
        #expect(catalog.quoteIdentifier("a]b") == "[a]]b]")
        #expect(catalog.tableDDLIncludesForeignKeys)
    }

    // MARK: - Write dialect

    private static let dialect = MSSQLMobileWriteDialect(databaseTypeId: DatabaseType.mssql.rawValue, currentSchema: "dbo")

    @Test("Rows bind as ? into the bracketed, schema-qualified table, within SQL Server's ceilings")
    func importStatements() async throws {
        let columns = [ColumnInfo(name: "a", typeName: "int", ordinalPosition: 0)]
        let statements = try await Self.dialect.importStatements(table: "t", schema: "sales", columns: columns)

        #expect(statements.insertStatement(columns: ["a"], values: [.text("1")])?.sql
            == "INSERT INTO [sales].[t] ([a]) VALUES (?)")
        #expect(statements.maxBindParameters == 2_100)
        #expect(statements.maxRowsPerInsert == 1_000)
    }

    @Test("With the import's database the rows go to a three-part name, whatever database the session is on")
    func importStatementsNameTheDatabase() async throws {
        let dialect = MSSQLMobileWriteDialect(
            databaseTypeId: DatabaseType.mssql.rawValue, currentSchema: "dbo", database: "sales_db"
        )
        let columns = [ColumnInfo(name: "a", typeName: "int", ordinalPosition: 0)]

        let named = try await dialect.importStatements(table: "t", schema: "sales", columns: columns)
        let defaulted = try await dialect.importStatements(table: "t", schema: nil, columns: columns)

        #expect(named.insertStatement(columns: ["a"], values: [.text("1")])?.sql
            == "INSERT INTO [sales_db].[sales].[t] ([a]) VALUES (?)")
        #expect(defaulted.insertStatement(columns: ["a"], values: [.text("1")])?.sql
            == "INSERT INTO [sales_db].[dbo].[t] ([a]) VALUES (?)")
        #expect(dialect.namesDatabase)
        #expect(Self.dialect.namesDatabase == false)
    }

    @Test("A new table goes into the session's schema when the import names an empty one")
    func createTableInCurrentSchema() throws {
        let definition = PluginCreateTableDefinition(
            tableName: "t", columns: [PluginColumnDefinition(name: "a", dataType: "int", isPrimaryKey: true)]
        )
        let statements = try Self.dialect.createTableStatements(definition: definition, schema: "")

        #expect(statements.first?.hasPrefix("CREATE TABLE [dbo].[t] (") == true)
    }

    @Test("A column type the writer cannot spell refuses the table with its reason")
    func createTableRefusalNamesTheColumn() throws {
        let column = PluginColumnDefinition(name: "a", dataType: "int; DROP TABLE x")
        let definition = PluginCreateTableDefinition(tableName: "t", columns: [column])
        let reason = try #require(MSSQLTableDefinitionSQL.refusal(for: column))

        #expect(throws: MobileTransferRefusal(reason: reason)) {
            _ = try Self.dialect.createTableStatements(definition: definition, schema: "dbo")
        }
    }
}
