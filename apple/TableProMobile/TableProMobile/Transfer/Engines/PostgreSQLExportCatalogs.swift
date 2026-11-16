import Foundation
import os
import TableProPluginKit
import TableProPostgreSQLCore
import TableProSQLQuoting

// The Mac's PostgreSQL export answers, over the iOS session's raw reads. `databaseName` is the schema the export groups
// an object under; empty is the session's own.
nonisolated struct PostgreSQLMobileExportCatalog: MobileExportCatalog {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PostgreSQLExportCatalog")

    let catalog: PostgreSQLCatalogExport
    let sessionScope: PostgreSQLSessionScope?
    let script: ExportCatalogScript
    let standardConformingStrings: Bool
    private let routines = ExportCatalogListCache<PluginRoutineInfo>()
    private let triggers = ExportCatalogListCache<PluginTriggerInfo>()
    private let sequences = ExportCatalogListCache<PluginSequenceInfo>()
    private let userTypes = ExportCatalogListCache<PluginUserDefinedTypeInfo>()

    init(
        catalog: PostgreSQLCatalogExport,
        sessionScope: PostgreSQLSessionScope?,
        script: ExportCatalogScript,
        standardConformingStrings: Bool
    ) {
        self.catalog = catalog
        self.sessionScope = sessionScope
        self.script = script
        self.standardConformingStrings = standardConformingStrings
    }

    var databaseTypeId: String { script.databaseTypeId }

    private func schema(_ databaseName: String) -> String {
        databaseName.isEmpty ? catalog.currentSchema : databaseName
    }

    // MARK: - Listing

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = schema?.nilIfEmpty ?? catalog.currentSchema
        var items = try await relations(in: container)
        items += await ExportCatalogItems.listing("routines") {
            ExportCatalogItems.routines(try await cachedRoutines(container), container: container)
        }
        items += await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await cachedTriggers(container), container: container)
        }
        items += await ExportCatalogItems.listing("sequences") {
            try await cachedSequences(container).map { ExportCatalogItems.item($0.name, container: container, kind: .sequence) }
        }
        items += await ExportCatalogItems.listing("user-defined types") {
            try await cachedUserTypes(container).map { ExportCatalogItems.item($0.name, container: container, kind: .userType) }
        }
        items += await ExportCatalogItems.listing("principals") {
            ExportCatalogItems.principals(try await catalog.fetchPrincipals(), container: container)
        }
        return items
    }

    // Partition-aware, so a partition is written once, inside its parent's definition. A server that refuses the
    // catalog form is listed from information_schema, as the iOS sidebar falls back.
    private func relations(in schema: String) async throws -> [PluginExportTable] {
        let listing = PostgreSQLTableListing.query(
            schema: schema,
            includeMaterializedViews: catalog.includesMaterializedViews,
            includeForeignTables: catalog.catalogPresence?.hasForeignTables ?? catalog.capabilities.hasForeignTablesCatalog,
            includeComments: false,
            includePartitionAwareness: true
        )
        let rows: [[PluginCellValue]]
        do {
            rows = try await catalog.read(listing, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.debug("Export listing fell back to information_schema: \(error.localizedDescription, privacy: .private)")
            rows = try await catalog.read(PostgreSQLTableListing.informationSchemaQuery(in: .schema(schema)), nil)
        }
        return rows
            .compactMap { PostgreSQLTableListing.table(fromRow: $0.map(\.asText)) }
            .compactMap { ExportCatalogItems.relation($0, container: schema) }
    }

    private func cachedRoutines(_ schema: String) async throws -> [PluginRoutineInfo] {
        try await routines.values(for: schema) { try await catalog.fetchRoutines(schema: schema) }
    }

    private func cachedTriggers(_ schema: String) async throws -> [PluginTriggerInfo] {
        try await triggers.values(for: schema) { try await catalog.fetchAllTriggers(schema: schema) }
    }

    private func cachedSequences(_ schema: String) async throws -> [PluginSequenceInfo] {
        try await sequences.values(for: schema) { try await catalog.fetchSequences(schema: schema) }
    }

    private func cachedUserTypes(_ schema: String) async throws -> [PluginUserDefinedTypeInfo] {
        try await userTypes.values(for: schema) { try await catalog.fetchUserDefinedTypes(schema: schema) }
    }

    // MARK: - Text

    func quoteIdentifier(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        LibPQStringConformance.escape(value, standardConformingStrings: standardConformingStrings)
    }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        script.lexicalFeatures
    }

    var supportsCascadeDrop: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { PostgreSQLCatalogExport.tableDDLIncludesForeignKeys }

    // MARK: - Definitions

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await catalog.fetchTableDDL(table: table, schema: schema(databaseName))
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await catalog.fetchApproximateRowCount(table: table, schema: schema(databaseName))
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await catalog.fetchDependentSequences(table: table, schema: schema(databaseName))
            .map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        try await catalog.fetchDependentTypes(table: table, schema: schema(databaseName))
            .map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
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

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        try await catalog.fetchCommentDDL(table: table, schema: schema(databaseName))
    }

    // A materialized view never falls back to the table DDL, which would restore an empty table in its place.
    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let schema = schema(object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await catalog.fetchTableDDL(table: object.name, schema: schema)
        case .view, .materializedView:
            return try await catalog.fetchViewDefinition(view: object.name, schema: schema)
        case .routine:
            let routine = try ExportCatalogItems.routine(matching: object, in: try await cachedRoutines(schema))
            return try await catalog.fetchRoutineDDL(routine)
        case .trigger:
            let trigger = try ExportCatalogItems.trigger(matching: object, in: try await cachedTriggers(schema))
            return try await catalog.fetchTriggerDDL(trigger)
        case .sequence:
            guard let sequence = try await cachedSequences(schema).first(where: { $0.name == object.name }) else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return sequence.ddl
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
            generate: { PostgreSQLCatalogExport.generateGrantSQL(changeSet: $0) }
        )
    }

    // MARK: - Session

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await sessionScope?.open(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await sessionScope?.close(scope)
    }
}

// Redshift lists tables and views, external ones included, and exports nothing else, as the Mac's Redshift driver.
nonisolated struct RedshiftMobileExportCatalog: MobileExportCatalog {
    let catalog: RedshiftCatalogExport
    let script: ExportCatalogScript
    let standardConformingStrings: Bool

    var databaseTypeId: String { script.databaseTypeId }

    private func schema(_ databaseName: String) -> String {
        databaseName.isEmpty ? catalog.currentSchema : databaseName
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = schema?.nilIfEmpty ?? catalog.currentSchema
        return try await catalog.fetchTables(schema: container)
            .compactMap { ExportCatalogItems.relation($0, container: container) }
    }

    func quoteIdentifier(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        LibPQStringConformance.escape(value, standardConformingStrings: standardConformingStrings)
    }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        script.lexicalFeatures
    }

    var supportsCascadeDrop: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { RedshiftCatalogExport.tableDDLIncludesForeignKeys }

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

    // The Mac's Redshift driver has no bulk read, so PluginKit's default asks table by table.
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        let schema = schema(databaseName)
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for table in try await catalog.fetchTables(schema: schema) {
            try Task.checkCancellation()
            let foreignKeys = try await catalog.fetchForeignKeys(table: table.name, schema: schema)
            if !foreignKeys.isEmpty { grouped[table.name] = foreignKeys }
        }
        return grouped
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let schema = schema(object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await catalog.fetchTableDDL(table: object.name, schema: schema)
        case .view, .materializedView:
            return try await catalog.fetchViewDefinition(view: object.name, schema: schema)
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }
}
