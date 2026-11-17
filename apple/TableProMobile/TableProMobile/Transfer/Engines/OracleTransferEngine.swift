import Foundation
import os
import TableProDatabase
import TableProModels
import TableProOracleCore
import TableProPluginKit
import TableProSQLQuoting

nonisolated extension OracleDriver: CatalogQuerying, ExportRowStreaming, MobileTransferEngine {
    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await catalogCells(sql, binds: parameters)
    }

    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        guard let release else { throw ConnectionError.notConnected }
        return OracleMobileExportCatalog(
            catalog: OracleExportCatalog(
                run: { [self] statement in try await catalogResult(statement) },
                currentSchema: currentSchema,
                fallbackSchema: fallbackSchema,
                release: release,
                principalState: principalState,
                coreError: { $0 as? OracleCoreError }
            ),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.oracle.rawValue, session: settledLexicalFacts)
        )
    }

    // An unknown release writes the identity, as on the Mac.
    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        OracleMobileWriteDialect(
            databaseTypeId: DatabaseType.oracle.rawValue,
            createTableSchema: currentSchema ?? fallbackSchema,
            supportsIdentity: release?.hasIdentityColumns ?? true
        )
    }
}

// The Mac's Oracle export answers, triggers listed (D14). A schema is what the connection lists as a database, so
// `databaseName` is the owner the export groups an object under; empty is the session's own.
nonisolated struct OracleMobileExportCatalog: MobileExportCatalog {
    let catalog: OracleExportCatalog
    let script: ExportCatalogScript
    private let routines = ExportCatalogListCache<PluginRoutineInfo>()
    private let triggers = ExportCatalogListCache<PluginTriggerInfo>()

    init(catalog: OracleExportCatalog, script: ExportCatalogScript) {
        self.catalog = catalog
        self.script = script
    }

    var databaseTypeId: String { script.databaseTypeId }

    private func schema(_ databaseName: String) -> String {
        catalog.effectiveSchema(databaseName.nilIfEmpty)
    }

    // MARK: - Listing

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = catalog.effectiveSchema(schema?.nilIfEmpty ?? database.nilIfEmpty)
        var items = try await catalog.run(OracleSchemaQueries.tables(schema: container)).rows
            .compactMap(OracleSchemaQueries.parseTableRow)
            .map { ExportCatalogItems.item($0.name, container: container, kind: $0.isView ? .view : .table) }
        items += await ExportCatalogItems.listing("routines") {
            ExportCatalogItems.routines(try await cachedRoutines(container), container: container)
        }
        items += await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await cachedTriggers(container), container: container)
        }
        items += await ExportCatalogItems.listing("principals") {
            ExportCatalogItems.principals(try await catalog.fetchPrincipals(), container: container)
        }
        return items
    }

    private func cachedRoutines(_ schema: String) async throws -> [PluginRoutineInfo] {
        try await routines.values(for: schema) { try await catalog.fetchRoutines(schema: schema) }
    }

    private func cachedTriggers(_ schema: String) async throws -> [PluginTriggerInfo] {
        try await triggers.values(for: schema) { try await catalog.fetchAllTriggers(schema: schema) }
    }

    // MARK: - Text

    func quoteIdentifier(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value)
    }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        script.lexicalFeatures
    }

    var tableDDLIncludesForeignKeys: Bool { OracleExportCatalog.tableDDLIncludesForeignKeys }

    // MARK: - Definitions

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await catalog.fetchTableDDL(table: table, schema: schema(databaseName))
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await catalog.fetchColumns(table: table, schema: schema(databaseName))
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await catalog.fetchAllColumns(schema: schema(databaseName))
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await catalog.fetchForeignKeys(table: table, schema: schema(databaseName))
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await catalog.fetchAllForeignKeys(schema: schema(databaseName))
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await catalog.fetchIndexDDL(table: table, schema: schema(databaseName))
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let schema = schema(object.databaseName)
        switch object.kind {
        case .table:
            return try await catalog.fetchTableDDL(table: object.name, schema: schema)
        case .view:
            return try await catalog.fetchViewDefinition(view: object.name, schema: schema)
        case .routine:
            let routine = try ExportCatalogItems.routine(matching: object, in: try await cachedRoutines(schema))
            return try await catalog.fetchRoutineDDL(routine)
        case .trigger:
            let trigger = try ExportCatalogItems.trigger(matching: object, in: try await cachedTriggers(schema))
            return try await catalog.fetchTriggerDDL(trigger)
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    // Guarded PL/SQL before 23ai, where the export's own `DROP TABLE IF EXISTS` does not parse.
    func dropStatement(for object: PluginExportTable) -> String? {
        catalog.dropStatement(for: object, schema: schema(object.databaseName))
    }

    // The roles the principal listing found, which a grant spells without a privilege keyword.
    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        try await ExportCatalogItems.grantStatements(
            principal: principal,
            host: host,
            fetchGrants: { try await catalog.fetchGrants(for: $0) },
            generate: {
                OracleExportCatalog.generateGrantSQL(changeSet: $0, roles: catalog.principalState.withLock { $0.roles })
            }
        )
    }
}

// One statement per call and one row per INSERT, the ceilings `SQLImportStatements` keys by type id. The column types
// reach `executeParameterized`, where the Mac's binder writes each value for its column.
nonisolated struct OracleMobileWriteDialect: MobileWriteDialect {
    let databaseTypeId: String
    let createTableSchema: String
    let supportsIdentity: Bool

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(table, schema: schema) { SQLQuoting.identifier($0) },
            parameterStyle: .questionMark,
            quoteIdentifier: { SQLQuoting.identifier($0) },
            columnTypeNames: ImportTableNames.columnTypeNames(columns)
        )
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard let statements = OracleCreateTableSQL.statements(
            definition: definition,
            schema: schema?.nilIfEmpty ?? createTableSchema,
            supportsIdentity: supportsIdentity
        ) else {
            throw ImportTableNames.noStatement
        }
        return statements
    }
}
