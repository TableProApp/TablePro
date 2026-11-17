import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

nonisolated extension SQLiteDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        SQLiteTransferCatalog(driver: self)
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        SQLiteWriteDialect()
    }
}

// The Mac plugin's export answers (`SQLitePlugin`), read through the driver the transfer runs on. iOS attaches no
// databases, so every read is of `main` and an object carries no container, as on the Mac's flat tree.
nonisolated struct SQLiteTransferCatalog: MobileExportCatalog {
    let driver: any CatalogQuerying

    var databaseTypeId: String { sqliteDatabaseTypeId }

    private var run: SQLiteCatalogReads.Run {
        { [driver] sql in try await driver.catalogQuery(sql) }
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let listed = try await run("""
            SELECT name, type FROM \(SQLiteMasterQueries.catalogTable(schema: nil))
            WHERE type IN ('table', 'view')
            AND name NOT GLOB 'sqlite_*'
            ORDER BY name
            """)
        let objects = listed.rows.compactMap { row -> PluginExportTable? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let kind: PluginExportObjectKind = row[safe: 1]?.asText?.lowercased() == "view" ? .view : .table
            return ExportCatalogItems.item(name, container: "", kind: kind)
        }
        let run = run
        return objects + (await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await SQLiteCatalogReads.triggers(table: nil, schema: nil, run: run), container: "")
        })
    }

    func quoteIdentifier(_ identifier: String) -> String {
        sqliteQuoteIdentifier(identifier)
    }

    // The driver's own body, so a NUL in a value lands in the dump as char(0) rather than being dropped.
    func escapeStringLiteral(_ value: String) -> String {
        SQLiteDriver.literalBody(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await SQLiteCatalogReads.tableDDL(table: table, schema: nil, run: run)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await SQLiteCatalogReads.columns(table: table, schema: nil, run: run)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await SQLiteCatalogReads.allColumns(schema: nil, run: run)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        let result = try await run(SQLiteForeignKeyGrouping.foreignKeysQuery(table: table, schema: nil))
        return SQLiteForeignKeyGrouping.foreignKeys(table: table, schema: nil, fromRows: result.rows)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await SQLiteCatalogReads.allForeignKeys(schema: nil, run: run)
    }

    var tableDDLIncludesForeignKeys: Bool { SQLiteCatalogReads.tableDDLIncludesForeignKeys }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await SQLiteCatalogReads.indexDDL(table: table, schema: nil, run: run)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        switch object.kind {
        case .table:
            return try await SQLiteCatalogReads.tableDDL(table: object.name, schema: nil, run: run)
        case .view:
            return try await SQLiteCatalogReads.viewDefinition(view: object.name, schema: nil, run: run)
        case .trigger:
            let triggers = try await SQLiteCatalogReads.triggers(table: object.parentTable, schema: nil, run: run)
            return try await SQLiteCatalogReads.triggerDDL(
                try ExportCatalogItems.trigger(matching: object, in: triggers), run: run
            )
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        guard object.kind == .trigger, object.parentTable != nil else { return nil }
        return SQLiteCatalogReads.dropTriggerStatement(name: object.name, schema: nil)
    }

    private var script: ExportCatalogScript {
        ExportCatalogScript(databaseTypeId: databaseTypeId, session: nil)
    }

    var lexicalFeatures: SQLLexicalFeatures { script.lexicalFeatures }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await SQLiteSessionScope.open(for: purpose, execute: run)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await SQLiteSessionScope.close(scope, execute: run)
    }
}

nonisolated struct SQLiteWriteDialect: MobileWriteDialect {
    var databaseTypeId: String { sqliteDatabaseTypeId }

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: SQLiteMasterQueries.qualifiedTable(table, schema: schema, quote: sqliteQuoteIdentifier),
            parameterStyle: .questionMark,
            quoteIdentifier: sqliteQuoteIdentifier,
            columnTypeNames: ImportTableNames.columnTypeNames(columns)
        )
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard let statement = sqliteCreateTableSQL(definition: definition) else { throw ImportTableNames.noStatement }
        return [statement]
    }
}
