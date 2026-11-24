//
//  RedshiftPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  Amazon Redshift PluginDatabaseDriver implementation.
//  Adapted from TablePro's RedshiftDriver for the plugin architecture.
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit
import TableProPostgreSQLCore

final class RedshiftPluginDriver: LibPQBackedDriver, @unchecked Sendable {
    let core: LibPQDriverCore

    private let connectedDatabase: String

    private let externalSchemaLock = NSLock()
    private var externalSchemaCache: Set<String>?

    /// Redshift forked PostgreSQL at 8.0.2 and `aclexplode` arrived in 8.4, so the schema ACL is
    /// the one thing the shared schema-management extension cannot read here.
    var supportsSchemaACLIntrospection: Bool { false }

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "RedshiftPluginDriver")

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .schemaCompare,
            .dataCompare,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.connectedDatabase = config.database
        self.core = LibPQDriverCore(
            config: config,
            schemaFallbackQueries: PostgreSQLSchemaQueries.schemaFallbackQueriesRedshift,
            pinsCatalogSearchPath: false
        )
        core.onPostConnect = { [weak self] in
            await self?.probeExternalSchemas()
        }
    }

    // MARK: - Schema

    // Refreshed on connect and with every schema list, so a schema made mid-session is classified; a failed probe
    // keeps the previous answer.
    private func probeExternalSchemas() async {
        do {
            let names = try await RedshiftCatalogExport.externalSchemaNames(read: catalogRows)
            externalSchemaLock.withLock { externalSchemaCache = names }
        } catch {
            Self.logger.warning(
                "Could not read svv_external_schemas; external schemas stay unresolved: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private var catalogRows: RedshiftCatalogExport.Read {
        { [self] statement in try await catalogRead(statement).rows }
    }

    var exportCatalog: RedshiftCatalogExport {
        RedshiftCatalogExport(
            read: catalogRows,
            currentSchema: core.currentSchema,
            database: connectedDatabase,
            serverVersionNumber: core.serverVersionNumber,
            externalSchemas: externalSchemaLock.withLock { externalSchemaCache } ?? []
        )
    }

    func fetchExternalSchemaNames() async throws -> Set<String> {
        externalSchemaLock.withLock { externalSchemaCache } ?? []
    }

    // Also read on the main actor, while a probe may be writing the cache.
    private func isExternalSchema(_ schema: String) -> Bool {
        externalSchemaLock.withLock { externalSchemaCache }?.contains(schema) ?? false
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await exportCatalog.fetchTables(schema: schema)
    }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        try await exportCatalog.fetchTables(inSchemas: schemas)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await exportCatalog.fetchColumns(table: table, schema: schema)
    }

    var fetchesAllColumnsInOneRequest: Bool { true }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await exportCatalog.fetchAllColumns(schema: schema)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        try await exportCatalog.fetchIndexes(table: table, schema: schema)
    }

    var tableDDLIncludesForeignKeys: Bool { RedshiftCatalogExport.tableDDLIncludesForeignKeys }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        try await exportCatalog.fetchForeignKeys(table: table, schema: schema)
    }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await exportCatalog.fetchApproximateRowCount(table: table, schema: schema)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await exportCatalog.fetchTableDDL(table: table, schema: schema)
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        try await exportCatalog.fetchViewDefinition(view: view, schema: schema)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let resolvedSchema = schema ?? core.currentSchema
        guard !isExternalSchema(resolvedSchema) else {
            return PluginTableMetadata(tableName: table, engine: "Redshift External")
        }
        let comment = try await fetchRelationComment(table: table, schema: resolvedSchema)
        let tableLiteral = PostgreSQLObjectQueries.quoteLiteral(table)
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(resolvedSchema)
        let query = """
            SELECT
                tbl_rows,
                size AS size_mb,
                pct_used,
                unsorted,
                stats_off
            FROM svv_table_info
            WHERE "table" = \(tableLiteral)
              AND schema = \(schemaLiteral)
            """
        let result = try await catalogRead(query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table, comment: comment)
        }

        let rowCount: Int64? = {
            guard let val = row[0].asText else { return nil }
            return Int64(val)
        }()

        let sizeMb = Int64(row[1].asText ?? "0") ?? 0
        let totalSize = sizeMb * 1_024 * 1_024

        return PluginTableMetadata(
            tableName: table,
            dataSize: totalSize,
            totalSize: totalSize,
            rowCount: rowCount,
            comment: comment,
            engine: "Redshift"
        )
    }

    // COMMENT ON takes TABLE and VIEW, never an external table:
    // https://docs.aws.amazon.com/redshift/latest/dg/r_COMMENT.html
    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        let resolvedSchema = schema ?? core.currentSchema
        guard !isExternalSchema(resolvedSchema) else { return nil }
        return PostgreSQLRelationSQL.commentStatement(
            name: name,
            schema: resolvedSchema,
            objectType: objectType,
            comment: comment,
            supportedKeywords: ["TABLE", "VIEW"]
        )
    }

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await catalogRead(
            "SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await catalogRead(PostgreSQLSchemaQueries.listSchemasRedshift)
        await probeExternalSchemas()
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let databaseLiteral = PostgreSQLObjectQueries.quoteLiteral(database)
        let countQuery = """
            SELECT pg_catalog.count(DISTINCT "table") AS table_count
            FROM svv_table_info
            WHERE schema NOT IN ('pg_internal', 'pg_catalog', 'information_schema')
              AND database = \(databaseLiteral)
            """
        let sizeQuery = """
            SELECT pg_catalog.sum(size) FROM svv_table_info WHERE database = pg_catalog.current_database()
            """
        async let countResult = catalogRead(countQuery)
        async let sizeResult = catalogRead(sizeQuery)
        let (countRes, sizeRes) = try await (countResult, sizeResult)

        let tableCount = Int(countRes.rows.first?[0].asText ?? "0") ?? 0
        let sizeMb = Int64(sizeRes.rows.first?[0].asText ?? "0") ?? 0
        let sizeBytes = sizeMb * 1_024 * 1_024

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: PostgreSQLSystemDatabases.redshift.contains(database)
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let dbResult = try await catalogRead(
            "SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false ORDER BY datname"
        )
        let dbNames = dbResult.rows.compactMap { $0.first?.asText }

        let infoQuery = """
            SELECT database, pg_catalog.count(DISTINCT "table"), COALESCE(pg_catalog.sum(size), 0)
            FROM svv_table_info
            WHERE schema NOT IN ('pg_internal', 'pg_catalog', 'information_schema')
            GROUP BY database
            """
        let infoResult = try await catalogRead(infoQuery)
        var metadataByName: [String: (tableCount: Int, sizeMb: Int64)] = [:]
        for row in infoResult.rows {
            guard let dbName = row[0].asText else { continue }
            let tableCount = Int(row[1].asText ?? "0") ?? 0
            let sizeMb = Int64(row[2].asText ?? "0") ?? 0
            metadataByName[dbName] = (tableCount: tableCount, sizeMb: sizeMb)
        }

        return dbNames.map { dbName in
            let info = metadataByName[dbName]
            return PluginDatabaseMetadata(
                name: dbName,
                tableCount: info?.tableCount,
                sizeBytes: info.map { $0.sizeMb * 1_024 * 1_024 },
                isSystemDatabase: PostgreSQLSystemDatabases.redshift.contains(dbName)
            )
        }
    }

    private static let supportedCollations: [String] = ["CASE_SENSITIVE", "CASE_INSENSITIVE"]

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let options = Self.supportedCollations.map {
            PluginCreateDatabaseFormSpec.Option(value: $0, label: $0)
        }
        let field = PluginCreateDatabaseFormSpec.Field(
            id: "collate",
            label: String(localized: "Collation"),
            kind: .picker(options: options, defaultValue: "CASE_SENSITIVE")
        )
        return PluginCreateDatabaseFormSpec(fields: [field])
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        guard let collate = request.values["collate"] else {
            throw LibPQPluginError(
                message: String(localized: "Collation is required"),
                sqlState: nil,
                detail: nil
            )
        }
        guard Self.supportedCollations.contains(collate) else {
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid collation: %@"), collate),
                sqlState: nil,
                detail: nil
            )
        }

        let sql = "CREATE DATABASE \(quoteIdentifier(request.name)) COLLATE \(collate)"
        _ = try await execute(query: sql)
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP DATABASE \(quoteIdentifier(name))")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema ?? currentSchema ?? "public")
        return """
        SELECT
            schema,
            "table" as name,
            'TABLE' as kind,
            tbl_rows as estimated_rows,
            size as size_mb,
            pct_used,
            unsorted,
            stats_off
        FROM svv_table_info
        WHERE schema = \(schemaLiteral)
        ORDER BY "table"
        """
    }
}
