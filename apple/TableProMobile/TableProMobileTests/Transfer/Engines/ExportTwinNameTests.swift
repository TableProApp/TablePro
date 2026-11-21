import Foundation
import os
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProMSSQLCore
import TableProMySQLCore
import TableProOracleCore
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

// An export catalog's schema-wide column and key reads throw when one answer names a table in two Unicode forms, so
// the export reads each table alone instead of merging the two under one String key.
struct ExportTwinNameTests {
    @Test("SQLite: the export reads throw on two tables named alike in different Unicode forms")
    func sqliteThrowsOnTwins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-twins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = SQLiteDriver(source: .file(directory.appendingPathComponent("twins.db")), openMode: .createNew)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE p (id INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: "CREATE TABLE \"\(composed)\" (id INTEGER PRIMARY KEY, r INTEGER REFERENCES p (id))")
        _ = try await driver.execute(query: "CREATE TABLE \"\(decomposed)\" (id INTEGER PRIMARY KEY, s INTEGER REFERENCES p (id))")
        let catalog = SQLiteTransferCatalog(driver: driver)

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "")
        }
        let own = try await catalog.fetchColumns(table: decomposed, databaseName: "")
        try await driver.disconnect()
        #expect(own.map { $0.name } == ["id", "s"])
    }

    @Test("DuckDB: the export reads throw on two tables named alike in different Unicode forms")
    func duckDBThrowsOnTwins() async throws {
        let driver = DuckDBBackedDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE p (id INTEGER PRIMARY KEY)")
        _ = try await driver.execute(query: "CREATE TABLE \"\(composed)\" (id INTEGER PRIMARY KEY, r INTEGER REFERENCES p (id))")
        _ = try await driver.execute(query: "CREATE TABLE \"\(decomposed)\" (id INTEGER PRIMARY KEY, s INTEGER REFERENCES p (id))")
        let catalog = try await driver.makeExportCatalog(
            context: MobileTransferContext(databaseType: .duckdb, database: nil, schema: nil)
        )

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "main")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "main")
        }
        let keys = try await catalog.fetchForeignKeys(table: decomposed, databaseName: "main")
        try await driver.disconnect()
        #expect(keys.map { $0.column } == ["s"])
    }

    @Test("DuckDB: only the key column is a key when another column is named alike in another Unicode form")
    func duckDBTwinColumnIsNotAKey() async throws {
        let driver = DuckDBBackedDriver(source: .inMemory)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE t (\"\u{E9}\" INTEGER PRIMARY KEY, \"e\u{301}\" INTEGER, v INTEGER)")
        let catalog = try await driver.makeExportCatalog(
            context: MobileTransferContext(databaseType: .duckdb, database: nil, schema: nil)
        )

        let own = try await catalog.fetchColumns(table: "t", databaseName: "main")
        let all = try await catalog.fetchAllColumns(databaseName: "main")
        try await driver.disconnect()

        #expect(own.map { $0.isPrimaryKey } == [true, false, false])
        #expect(all["t"]?.map { $0.isPrimaryKey } == [true, false, false])
    }

    @Test("MySQL: the export reads throw on two tables named alike in different Unicode forms")
    func mysqlThrowsOnTwins() async throws {
        let reads = RecordedCatalogReads([
            MySQLObjectQueries.columnCatalog(schema: "shop", table: nil, projectsGenerationExpression: true): [
                [.text(composed), "id", "int", nil, "NO", "PRI", nil, "", "", nil],
                [.text(decomposed), "id", "int", nil, "NO", "PRI", nil, "", "", nil],
            ],
            MySQLObjectQueries.foreignKeyColumns(schema: "shop", table: nil): [
                [.text(composed), "fk_a", "a", "shop", "p", "id"],
                [.text(decomposed), "fk_b", "b", "shop", "p", "id"],
            ],
        ])
        let catalog = MySQLTransferCatalog(
            driver: MySQLDriver(host: "db.example.com", port: 3_306, user: "u", password: "p", database: "shop"),
            reader: MySQLExportCatalog(
                banner: "8.0.36",
                flavor: .mysql,
                activeDatabase: "shop",
                quote: { "`\($0)`" },
                run: { try reads.result($0) },
                schemaNamesAreCaseSensitive: { false },
                settlesBlindness: { _ in false }
            ),
            openedDatabase: "shop"
        )

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "shop")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "shop")
        }
    }

    @Test("SQL Server: the export reads throw on two tables named alike in different Unicode forms")
    func mssqlThrowsOnTwins() async throws {
        func columnRow(_ table: String) -> [PluginCellValue] {
            var row = [PluginCellValue](repeating: .null, count: MSSQLSchemaQueries.allColumnsTableNameIndex + 1)
            row[0] = "id"
            row[1] = "int"
            row[MSSQLSchemaQueries.allColumnsTableNameIndex] = .text(table)
            return row
        }
        let reads = RecordedCatalogReads([
            MSSQLSchemaQueries.allColumns(schema: "sales"): [columnRow(composed), columnRow(decomposed)],
            MSSQLSchemaQueries.foreignKeys(schema: "sales", table: nil): [
                ["fk_a", "a", "p", "id", "sales", nil, nil, .text(composed)],
                ["fk_b", "b", "p", "id", "sales", nil, nil, .text(decomposed)],
            ],
        ])
        let catalog = MSSQLMobileExportCatalog(
            catalog: MSSQLExportCatalog(run: { try reads.result($0) }, currentSchema: "dbo"),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.mssql.rawValue, session: nil)
        )

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "sales")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "sales")
        }
    }

    @Test("Oracle: the export reads throw on two tables named alike in different Unicode forms")
    func oracleThrowsOnTwins() async throws {
        let release = OracleServerRelease(major: 23)
        let reads = RecordedCatalogReads([
            OracleSchemaQueries.allColumns(schema: "APP", release: release): [
                [.text(composed), "ID"],
                [.text(decomposed), "ID"],
            ],
            OracleSchemaQueries.allForeignKeys(schema: "APP"): [
                [.text(composed), "FK_A", "A", "P", "ID", "NO ACTION", "APP"],
                [.text(decomposed), "FK_B", "B", "P", "ID", "NO ACTION", "APP"],
            ],
        ])
        let catalog = OracleMobileExportCatalog(
            catalog: OracleExportCatalog(
                run: { statement in
                    OracleRawResult(
                        columns: [],
                        rows: try reads.rows(statement).map { row in
                            row.map { cell -> OracleRawCell in
                                switch cell {
                                case .null: .null
                                case .text(let text): .string(text)
                                case .bytes(let data): .bytes(data)
                                }
                            }
                        },
                        affectedRows: 0,
                        isTruncated: false
                    )
                },
                currentSchema: "APP",
                fallbackSchema: "APP",
                release: release,
                principalState: OSAllocatedUnfairLock(initialState: OraclePrincipalState()),
                coreError: { $0 as? OracleCoreError }
            ),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.oracle.rawValue, session: nil)
        )

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "APP")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "APP")
        }
    }

    @Test("Redshift: the export reads throw on two tables named alike, and read no key of either")
    func redshiftThrowsOnTwins() async throws {
        let listing = RedshiftTableCatalog.listingQuery(schema: "public")
        let reads = RecordedCatalogReads([
            RedshiftSchemaQueries.columnsQuery(schema: "public", table: nil): [
                [.text(composed), "id", "integer", "NO", nil, nil, nil, nil, "YES"],
                [.text(decomposed), "id", "integer", "NO", nil, nil, nil, nil, "YES"],
            ],
            listing: [[.text(composed), "BASE TABLE"], [.text(decomposed), "BASE TABLE"]],
        ])
        let catalog = RedshiftMobileExportCatalog(
            catalog: RedshiftCatalogExport(
                read: { try reads.rows($0) },
                currentSchema: "public",
                database: "dev",
                serverVersionNumber: 80_002,
                externalSchemas: []
            ),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.redshift.rawValue, session: nil),
            standardConformingStrings: true
        )

        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllColumns(databaseName: "")
        }
        await #expect(throws: PluginCatalogNameCollision.self) {
            try await catalog.fetchAllForeignKeys(databaseName: "")
        }
        #expect(reads.statements.last == listing)
    }
}
