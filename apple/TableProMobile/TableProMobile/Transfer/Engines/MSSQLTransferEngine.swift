import Foundation
import TableProDatabase
import TableProModels
import TableProMSSQLCore
import TableProPluginKit
import TableProSQLQuoting

nonisolated extension MSSQLDriver: CatalogQuerying, ExportRowStreaming, MobileTransferEngine {
    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await catalogCells(sql, parameters: parameters, in: nil)
    }

    // Every read runs in the export's database through `sp_executesql`, whatever a `USE` moved the session to.
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        let database = context.database
        return MSSQLMobileExportCatalog(
            catalog: MSSQLExportCatalog(
                run: { [self] statement in try await catalogCells(statement, in: database) },
                currentSchema: effectiveSchema,
                principalState: principalState
            ),
            script: ExportCatalogScript(databaseTypeId: DatabaseType.mssql.rawValue, session: settledLexicalFacts)
        )
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        MSSQLMobileWriteDialect(databaseTypeId: DatabaseType.mssql.rawValue, currentSchema: effectiveSchema)
    }
}

// The Mac's SQL Server export answers. `databaseName` is the schema the export groups an object under; empty is the
// session's own.
nonisolated struct MSSQLMobileExportCatalog: MobileExportCatalog {
    let catalog: MSSQLExportCatalog
    let script: ExportCatalogScript
    private let routines = ExportCatalogListCache<PluginRoutineInfo>()
    private let triggers = ExportCatalogListCache<PluginTriggerInfo>()
    private let userTypes = ExportCatalogListCache<PluginUserDefinedTypeInfo>()

    init(catalog: MSSQLExportCatalog, script: ExportCatalogScript) {
        self.catalog = catalog
        self.script = script
    }

    var databaseTypeId: String { script.databaseTypeId }

    private func schema(_ databaseName: String) -> String {
        catalog.effectiveSchema(databaseName)
    }

    // MARK: - Listing

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = catalog.effectiveSchema(schema)
        var items = try await catalog.run(MSSQLSchemaQueries.tables(schema: container)).rows.compactMap { row in
            MSSQLSchemaQueries.parseTableRow(row.map(\.asText)).map {
                ExportCatalogItems.item($0.name, container: container, kind: $0.isView ? .view : .table)
            }
        }
        items += await ExportCatalogItems.listing("routines") {
            ExportCatalogItems.routines(try await cachedRoutines(container), container: container)
        }
        items += await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await cachedTriggers(container), container: container)
        }
        items += await ExportCatalogItems.listing("user-defined types") {
            try await cachedUserTypes(container).map { ExportCatalogItems.item($0.name, container: container, kind: .userType) }
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

    private func cachedUserTypes(_ schema: String) async throws -> [PluginUserDefinedTypeInfo] {
        try await userTypes.values(for: schema) { try await catalog.fetchUserDefinedTypes(schema: schema) }
    }

    // MARK: - Text

    func quoteIdentifier(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier, quote: .bracket)
    }

    func escapeStringLiteral(_ value: String) -> String {
        MSSQLStringLiteral.escaped(value)
    }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        script.lexicalFeatures
    }

    var tableDDLIncludesForeignKeys: Bool { MSSQLExportCatalog.tableDDLIncludesForeignKeys }

    // MARK: - Definitions

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await catalog.fetchTableDDL(table: table, schema: schema(databaseName))
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await catalog.fetchApproximateRowCount(table: table, schema: schema(databaseName))
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
        case .userType:
            guard let type = try await cachedUserTypes(schema).first(where: { $0.name == object.name }),
                  let definition = try await catalog.fetchUserDefinedType(type).definition,
                  !definition.isEmpty
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return definition
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        let schema = schema(object.databaseName)
        switch object.kind {
        case .trigger:
            guard let parent = object.parentTable else { return nil }
            return catalog.generateDropTriggerSQL(name: object.name, table: parent, schema: schema)
        case .routine:
            guard let kind = ExportCatalogItems.routineKind(of: object) else { return nil }
            return catalog.generateDropRoutineSQL(
                name: object.name, signature: object.identity, schema: schema, isFunction: kind == .function
            )
        default:
            return nil
        }
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        try await ExportCatalogItems.grantStatements(
            principal: principal,
            host: host,
            fetchGrants: { try await catalog.fetchGrants(for: $0) },
            generate: { catalog.generateGrantSQL(changeSet: $0) }
        )
    }
}

// Quoting, the bind and row ceilings of `SQLImportStatements`, and the Mac's CREATE TABLE writer.
nonisolated struct MSSQLMobileWriteDialect: MobileWriteDialect {
    let databaseTypeId: String
    let currentSchema: String

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(table, schema: schema, quote: Self.quote),
            parameterStyle: .questionMark,
            quoteIdentifier: Self.quote,
            columnTypeNames: ImportTableNames.columnTypeNames(columns)
        )
    }

    // A column the writer cannot spell names its reason, as the Mac's schema editor refuses it.
    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        let target = MSSQLExportCatalog.effectiveSchema(schema, current: currentSchema)
        guard let statements = MSSQLTableDefinitionSQL.createTableStatements(definition, schema: target) else {
            let reason = definition.columns.lazy.compactMap { MSSQLTableDefinitionSQL.refusal(for: $0) }.first
            throw reason.map { MobileTransferRefusal(reason: $0) } ?? ImportTableNames.noStatement
        }
        return statements
    }

    private static func quote(_ name: String) -> String {
        SQLQuoting.identifier(name, quote: .bracket)
    }
}
