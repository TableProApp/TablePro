import Foundation
import TableProDatabase
import TableProDuckDBCore
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

nonisolated extension DuckDBDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        let catalog = try await catalogQuery("SELECT current_database()").rows.first?[safe: 0]?.asText
        guard let catalog else { throw DuckDBDriverError.queryFailed("The database did not name its catalog") }
        return DuckDBTransferCatalog(
            driver: self, catalog: catalog, defaultSchema: context.schema ?? currentSchema ?? Self.defaultSchema
        )
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        DuckDBWriteDialect(defaultSchema: context.schema ?? currentSchema ?? Self.defaultSchema)
    }

    static let defaultSchema = "main"
}

// The Mac plugin's export answers (`DuckDBPlugin`), read through the driver the transfer runs on. Every read names the
// catalog, because `duckdb_*()` spans every attached database; an object's container is its schema, as on the Mac.
nonisolated struct DuckDBTransferCatalog: MobileExportCatalog {
    let driver: any CatalogQuerying
    let catalog: String
    let defaultSchema: String

    var databaseTypeId: String { duckdbDatabaseTypeId }

    private var run: DuckDBExportCatalog.Run {
        { [driver] sql, parameters in try await driver.catalogQuery(sql, parameters: parameters) }
    }

    private func schema(for databaseName: String) -> String {
        databaseName.isEmpty ? defaultSchema : databaseName
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = schema ?? defaultSchema
        let tables = try await DuckDBExportCatalog.tables(catalog: catalog, schema: container, run: run)
        let (catalog, run) = (catalog, run)
        return tables.compactMap { ExportCatalogItems.relation($0, container: container) }
            + (await ExportCatalogItems.listing("macros") {
                ExportCatalogItems.routines(
                    try await DuckDBExportCatalog.routines(catalog: catalog, schema: container, run: run),
                    container: container
                )
            })
    }

    func quoteIdentifier(_ identifier: String) -> String {
        DuckDBSchemaQueries.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await DuckDBExportCatalog.tableDDL(catalog: catalog, schema: schema(for: databaseName), table: table, run: run)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await DuckDBExportCatalog.columns(catalog: catalog, schema: schema(for: databaseName), table: table, run: run)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await DuckDBExportCatalog.allColumns(catalog: catalog, schema: schema(for: databaseName), run: run)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await DuckDBExportCatalog.foreignKeys(
            catalog: catalog, schema: schema(for: databaseName), table: table, run: run
        )
    }

    // The plugin has no schema-wide read, so PluginKit's default asks table by table; this does the same.
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        let container = schema(for: databaseName)
        var keys: [String: [PluginForeignKeyInfo]] = [:]
        for table in try await DuckDBExportCatalog.tables(catalog: catalog, schema: container, run: run) {
            try Task.checkCancellation()
            keys[table.name] = try await DuckDBExportCatalog.foreignKeys(
                catalog: catalog, schema: container, table: table.name, run: run
            )
        }
        return keys
    }

    var tableDDLIncludesForeignKeys: Bool { DuckDBExportCatalog.tableDDLIncludesForeignKeys }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await DuckDBExportCatalog.indexDDL(catalog: catalog, schema: schema(for: databaseName), table: table, run: run)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let container = schema(for: object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await DuckDBExportCatalog.tableDDL(catalog: catalog, schema: container, table: object.name, run: run)
        case .view, .materializedView:
            return try await DuckDBExportCatalog.viewDefinition(
                catalog: catalog, schema: container, view: object.name, run: run
            )
        case .routine:
            let routines = try await DuckDBExportCatalog.routines(catalog: catalog, schema: container, run: run)
            let routine = try ExportCatalogItems.routine(matching: object, in: routines)
            return try await DuckDBExportCatalog.routineDDL(routine, catalog: catalog, run: run)
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    // The identity is the shared listing's signature, which names a table macro's kind.
    func dropStatement(for object: PluginExportTable) -> String? {
        guard object.kind == .routine else { return nil }
        return DuckDBObjectQueries.dropMacro(
            name: object.name,
            schema: schema(for: object.databaseName),
            isTableMacro: DuckDBObjectQueries.namesTableMacro(object.identity)
        )
    }

    private var script: ExportCatalogScript {
        ExportCatalogScript(databaseTypeId: databaseTypeId, session: nil)
    }

    var lexicalFeatures: SQLLexicalFeatures { script.lexicalFeatures }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }
}

nonisolated struct DuckDBWriteDialect: MobileWriteDialect {
    let defaultSchema: String

    var databaseTypeId: String { duckdbDatabaseTypeId }

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        let quote = DuckDBSchemaQueries.quoteIdentifier
        return SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(table, schema: schema, quote: quote),
            parameterStyle: .dollar,
            quoteIdentifier: quote,
            columnTypeNames: ImportTableNames.columnTypeNames(columns)
        )
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard let statements = duckdbCreateTableStatements(
            definition: definition,
            schema: schema.flatMap(\.nilIfEmpty) ?? defaultSchema,
            quote: DuckDBSchemaQueries.quoteIdentifier
        ) else {
            throw ImportTableNames.noStatement
        }
        return statements
    }
}
