import Foundation
import os
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import TableProPluginKit
import Testing

struct OracleTransferEngineTests {
    @Test("Untyped values stay literals where a literal carries them; bytes and long text bind as :n")
    func boundStatementSubstitutes() throws {
        let long = String(repeating: "a", count: OracleBindPlaceholders.maxLiteralBytes + 1)
        let statement = try OracleDriver.boundStatement(
            "INSERT INTO \"APP\".\"T\" (\"A\", \"B\", \"C\", \"D\") VALUES (?, ?, ?, ?)",
            parameters: [.text("00123"), .bytes(Data([0x01])), .null, .text(long)],
            typeNames: nil,
            writesBooleans: false
        )

        #expect(statement.sql == "INSERT INTO \"APP\".\"T\" (\"A\", \"B\", \"C\", \"D\") VALUES ('00123', :1, NULL, :2)")
        #expect(statement.binds == [.bytes(Data([0x01])), .text(long)])
    }

    @Test("A ? inside a literal, a quoted name or a comment is text, not a placeholder")
    func placeholdersInTextStay() throws {
        let statement = try OracleDriver.boundStatement(
            "SELECT '?' AS \"Paid?\" FROM DUAL WHERE A = ? -- ?",
            parameters: [.text("x")],
            typeNames: nil,
            writesBooleans: false
        )

        #expect(statement.sql == "SELECT '?' AS \"Paid?\" FROM DUAL WHERE A = 'x' -- ?")
        #expect(statement.binds.isEmpty)
    }

    private static let appReplies: [String: [[PluginCellValue]]] = [
        OracleSchemaQueries.tables(schema: "APP"): [["ORDERS", "BASE TABLE", "N"], ["RECENT", "VIEW", "N"]],
        OracleObjectQueries.routineList(schema: "APP"): [["ARCHIVE", "APP", "PROCEDURE", "VALID"], ["TOTAL", "APP", "FUNCTION", "VALID"]],
        OracleObjectQueries.triggerList(schema: "APP", table: nil): [[
            "AUDIT_ORDERS", "ORDERS", "APP", "BEFORE EACH ROW", "INSERT", "ENABLED", nil,
            "AUDIT_ORDERS BEFORE INSERT ON ORDERS FOR EACH ROW", "PL/SQL     ", "APP", "BEGIN NULL; END;",
        ]],
    ]

    private static func catalog(_ reads: RecordedCatalogReads) -> OracleMobileExportCatalog {
        OracleMobileExportCatalog(
            catalog: OracleExportCatalog(
                run: { statement in
                    OracleRawResult(
                        columns: [],
                        rows: try reads.rows(statement).map { $0.map(Self.rawCell) },
                        affectedRows: 0,
                        isTruncated: false
                    )
                },
                currentSchema: "APP",
                fallbackSchema: "APP",
                release: OracleServerRelease(major: 23),
                principalState: OSAllocatedUnfairLock(initialState: OraclePrincipalState()),
                coreError: { $0 as? OracleCoreError }
            ),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.oracle.rawValue, session: nil)
        )
    }

    private static func rawCell(_ value: PluginCellValue) -> OracleRawCell {
        switch value {
        case .null: .null
        case .text(let text): .string(text)
        case .bytes(let data): .bytes(data)
        }
    }

    @Test("Tables, views, routines and triggers are listed under their owner (D14)")
    func listsObjectsWithTriggers() async throws {
        let objects = try await Self.catalog(RecordedCatalogReads(Self.appReplies))
            .exportObjects(database: "APP", schema: "APP")

        #expect(objects.map(\.name) == ["ORDERS", "RECENT", "ARCHIVE", "TOTAL", "AUDIT_ORDERS"])
        #expect(objects.map(\.kind) == [.table, .view, .routine, .routine, .trigger])
        #expect(objects.map(\.tableType) == ["table", "view", "procedure", "function", "trigger"])
        #expect(objects[4].parentTable == "ORDERS")
        #expect(objects.allSatisfy { $0.databaseName == "APP" && $0.schema == "APP" })
    }

    @Test("A trigger's definition is the one the listing read, and every object drops by its own verb")
    func triggerDefinitionAndDrops() async throws {
        let catalog = Self.catalog(RecordedCatalogReads(Self.appReplies))
        let objects = try await catalog.exportObjects(database: "APP", schema: "APP")

        let definition = try await catalog.fetchObjectDDL(objects[4])
        #expect(definition.contains("BEGIN NULL; END;"))
        #expect(catalog.dropStatement(for: objects[0]) == "DROP TABLE IF EXISTS \"ORDERS\"")
        #expect(catalog.dropStatement(for: objects[1]) == "DROP VIEW IF EXISTS \"RECENT\"")
        #expect(catalog.dropStatement(for: objects[4]) == "DROP TRIGGER IF EXISTS \"AUDIT_ORDERS\"")
        #expect(catalog.dropStatement(for: objects[2])?.contains("PROCEDURE") == true)
        #expect(catalog.dropStatement(for: objects[3])?.contains("FUNCTION") == true)
        #expect(!catalog.tableDDLIncludesForeignKeys)
    }

    // MARK: - Write dialect

    private static let dialect = OracleMobileWriteDialect(
        databaseTypeId: DatabaseType.oracle.rawValue, createTableSchema: "APP", supportsIdentity: true
    )

    @Test("Rows insert one per statement with each value's column type, for the binder to write it")
    func importStatementsCarryTypes() async throws {
        let columns = [ColumnInfo(name: "A", typeName: "NUMBER(10,2)", ordinalPosition: 0)]
        let statements = try await Self.dialect.importStatements(table: "T", schema: "APP", columns: columns)
        let insert = try #require(statements.insertStatement(columns: ["A"], values: [.text("1.5")]))

        #expect(insert.sql == "INSERT INTO \"APP\".\"T\" (\"A\") VALUES (?)")
        #expect(insert.parameterTypeNames == ["NUMBER(10,2)"])
        #expect(statements.maxRowsPerInsert == 1)
    }

    @Test("A new table goes into the session's schema when the import names none")
    func createTableInSessionSchema() throws {
        let definition = PluginCreateTableDefinition(
            tableName: "T", columns: [PluginColumnDefinition(name: "A", dataType: "NUMBER", isPrimaryKey: true)]
        )
        let statements = try Self.dialect.createTableStatements(definition: definition, schema: nil)

        #expect(statements.first?.hasPrefix("CREATE TABLE \"APP\".\"T\" (") == true)
    }
}
