//
//  PostgreSQLPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL PluginDatabaseDriver implementation.
//  Adapted from TablePro's PostgreSQLDriver for the plugin architecture.
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit
import TableProPostgreSQLCore

class PostgreSQLPluginDriver: LibPQBackedDriver, @unchecked Sendable {
    let core: LibPQDriverCore

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLPluginDriver")

    private var catalogPresence: PostgreSQLCatalogPresence?
    let sessionFacts = OSAllocatedUnfairLock(initialState: PostgreSQLSessionFacts.unknown)
    private let listingDegradeReported = OSAllocatedUnfairLock(initialState: false)

    var sessionLexicalState: PluginSessionLexicalState? { core.sessionLexicalState }

    var serverVersionNumber: Int32 {
        let reported = core.serverVersionNumber
        return sessionFacts.withLock { $0.resolvedServerVersion(reported: reported) }
    }

    var versionedCapabilities: PostgreSQLCapabilities {
        PostgreSQLCapabilities(serverVersion: serverVersionNumber)
    }
    var catalogCapabilities: PostgreSQLCapabilities {
        .assumingModernWhenUnknown(core.serverVersionNumber)
    }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .materializedViews,
            .foreignTables,
            .storedProcedures,
            .userFunctions,
            .userManagement,
            .schemaCompare,
            .dataCompare,
            .temporaryTables,
            .readOnlyStatements,
            .enforcesReadOnlyMode,
            .copyFromStandardInput,
        ]
    }

    // In the class body so PGlite, which inherits the debugger conformance, can turn it off.
    var canDebugRoutines: Bool { true }
    var canFollowNotifications: Bool { true }

    // In the class body so KingbaseES, whose catalog is not established, can answer none.
    var serverObjectKinds: [PluginServerObjectKind] {
        PostgreSQLExtensions.isDeclared(capabilities: catalogCapabilities) ? [PostgreSQLExtensions.kind] : []
    }

    init(config: DriverConnectionConfig, singleConnectionMode: Bool = false) {
        self.core = LibPQDriverCore(config: config, singleConnectionMode: singleConnectionMode)
    }

    // MARK: - Connection

    func connect() async throws {
        core.onPostConnect = { [weak self] in
            try await self?.probeAfterConnect()
        }
        try await core.connect()
    }

    /// Runs inside the connect's deadline and cancellation, before the connection is handed out.
    func probeAfterConnect() async throws {
        let probes: [(statement: String, apply: (Result<PluginQueryResult, Error>) -> Void)] = [
            (PostgreSQLSessionFacts.probeQuery, applySessionFactsProbe),
            (PostgreSQLCatalogPresence.probeQuery, applyCatalogPresenceProbe),
            (PostGISTypes.probeQuery, applyPostgisProbe),
            (PostgreSQLSchemaQueries.enumTypeOidQuery, applyEnumProbe),
            (PgvectorTypes.probeQuery, applyVectorTypesProbe)
        ]
        let reads = await core.executeCatalogReads(probes.map { $0.statement })
        for (probe, read) in zip(probes, reads) {
            probe.apply(read)
        }
    }

    private func applyCatalogPresenceProbe(_ read: Result<PluginQueryResult, Error>) {
        do {
            let result = try read.get()
            let relationNames = result.rows.compactMap { $0.first?.asText }
            catalogPresence = PostgreSQLCatalogPresence(relationNames: relationNames)
        } catch {
            Self.logger.debug("Catalog presence probe failed; using version-based capabilities: \(error.localizedDescription)")
        }
    }

    private func applyPostgisProbe(_ read: Result<PluginQueryResult, Error>) {
        do {
            let result = try read.get()
            core.setPostgisOidMap(PostGISTypes.names(fromProbeRows: result.rows.map { row in row.map(\.asText) }))
        } catch {
            Self.logger.debug("PostGIS type probe failed; spatial values stay as hex: \(error.localizedDescription)")
        }
    }

    private func applyVectorTypesProbe(_ read: Result<PluginQueryResult, Error>) {
        do {
            let result = try read.get()
            let rows = result.rows.map { row in row.map(\.asText) }
            core.mergeCatalogTypeNames(PgvectorTypes.names(fromProbeRows: rows))
        } catch {
            Self.logger.debug("pgvector type probe failed; vector columns resolve on first use: \(error.localizedDescription)")
        }
    }

    var exportCatalog: PostgreSQLCatalogExport {
        PostgreSQLCatalogExport(
            read: { [self] statement, schema in try await catalogRead(statement, namesRelativeTo: schema).rows },
            currentSchema: core.currentSchema,
            capabilities: versionedCapabilities,
            catalogCapabilities: catalogCapabilities,
            catalogPresence: catalogPresence
        )
    }

    func includesMaterializedViews() -> Bool {
        catalogPresence?.hasMaterializedViews ?? versionedCapabilities.hasMaterializedViewsCatalog
    }

    private func includesForeignTables() -> Bool {
        catalogPresence?.hasForeignTables ?? versionedCapabilities.hasForeignTablesCatalog
    }

    // MARK: - Foreign Keys

    func foreignKeyDisableStatements() -> [String]? {
        PostgreSQLForeignKeyChecks.disableStatements
    }

    func foreignKeyEnableStatements() -> [String]? {
        PostgreSQLForeignKeyChecks.enableStatements
    }

    /// A duplicated database arrives with `public` alone, so every other schema its tables are
    /// qualified with has to be made before the first `CREATE TABLE` names one.
    ///
    /// Overrides the protocol's plain `IF NOT EXISTS` form because PostgreSQL before 9.3 has no
    /// such clause and needs the `DO` block instead. Redshift and CockroachDB both accept the
    /// plain form, so they keep the shared one.
    func createSchemaStatement(name: String) -> String? {
        PostgreSQLVersionedStatements.createSchema(name, capabilities: versionedCapabilities)
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        PostgreSQLMaintenance.operations(capabilities: versionedCapabilities).map(\.name)
    }

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        PostgreSQLMaintenance.operations(capabilities: versionedCapabilities)
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        PostgreSQLMaintenance.statements(
            operation: operation,
            table: table,
            schema: schema,
            options: options,
            connectedDatabase: connectedDatabase,
            capabilities: versionedCapabilities
        )
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS TEXT)"
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await listTables(in: .schema(schema ?? core.currentSchema))
    }

    func fetchTablesInAllSchemas() async throws -> [PluginTableInfo]? {
        try await listTables(in: .allSchemas)
    }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        guard !schemas.isEmpty else { return [] }
        return try await listTables(in: .schemas(schemas))
    }

    func fetchTemporaryTables() async throws -> [PluginTableInfo] {
        let result = try await catalogRead(PostgreSQLTableListing.temporaryTables)
        return result.rows.compactMap { PostgreSQLTableListing.table(fromRow: $0.map(\.asText)) }
    }

    private func listTables(in scope: PostgreSQLTableListingScope) async throws -> [PluginTableInfo] {
        let includeMaterializedViews = includesMaterializedViews()
        let includeForeignTables = includesForeignTables()
        func query(_ attempt: PostgreSQLTableListingAttempt) -> String {
            PostgreSQLTableListingLadder.query(
                for: attempt,
                in: scope,
                includeMaterializedViews: includeMaterializedViews,
                includeForeignTables: includeForeignTables
            )
        }

        var result: PluginQueryResult?
        var answered = PostgreSQLTableListingLadder.leastCapableAttempt
        for attempt in PostgreSQLTableListingLadder.degradableAttempts where result == nil {
            do {
                result = try await catalogRead(query(attempt))
                answered = attempt
            } catch let error as LibPQPluginError where PostgreSQLTableListingLadder.isDegradable(sqlState: error.sqlState) {
                reportListingDegrade(past: attempt, error: error)
            }
        }
        if result == nil {
            result = try await catalogRead(query(PostgreSQLTableListingLadder.leastCapableAttempt))
        }

        guard let result else { return [] }
        return result.rows.compactMap {
            PostgreSQLTableListing.table(fromRow: $0.map(\.asText), includesSequences: answered.includeSequences)
        }
    }

    /// The first degrade on a connection is a warning: an undefined column in the plugin's own SQL
    /// degrades exactly like an engine that lacks the column, and would otherwise pass unnoticed.
    private func reportListingDegrade(past attempt: PostgreSQLTableListingAttempt, error: LibPQPluginError) {
        let isFirst = listingDegradeReported.withLock { reported in
            defer { reported = true }
            return !reported
        }
        let sqlState = error.sqlState ?? "none"
        if isFirst {
            Self.logger.warning(
                "Table listing degrading past \(attempt.label, privacy: .public), SQLSTATE \(sqlState, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        } else {
            Self.logger.debug(
                "Table listing degrading past \(attempt.label, privacy: .public), SQLSTATE \(sqlState, privacy: .public)"
            )
        }
    }

    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] {
        try await partitionRows(table: table, schema: schema).map { row in
            PluginTableInfo(
                name: row.name,
                type: row.relationType,
                rowCount: row.rowCount,
                schema: row.schema,
                comment: nil
            )
        }
    }

    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PluginPartitionInfo] {
        try await partitionRows(table: table, schema: schema).map { row in
            PluginPartitionInfo(
                name: row.name,
                schema: row.schema,
                bound: row.bound,
                rowCount: row.rowCount,
                relationType: row.relationType,
                isSubpartitioned: row.isSubpartitioned
            )
        }
    }

    private struct PostgreSQLPartitionRow {
        let name: String
        let schema: String?
        let bound: String?
        let rowCount: Int?
        let relationType: String
        var isSubpartitioned: Bool { relationType == "PARTITIONED TABLE" }
    }

    /// A partition is whatever `relkind` says it is. From PostgreSQL 11 a foreign table can be a
    /// partition, and it is read-only, so reporting one as an ordinary table offers Truncate on a
    /// table that lives on another server.
    private static func partitionRelationType(relkind: String?) -> String {
        switch relkind {
        case "p": return "PARTITIONED TABLE"
        case "f": return "FOREIGN TABLE"
        default:  return "TABLE"
        }
    }

    private func partitionRows(table: String, schema: String?) async throws -> [PostgreSQLPartitionRow] {
        guard versionedCapabilities.hasDeclarativePartitioning else { return [] }
        let resolvedSchema = schema ?? core.currentSchema
        let result = try await catalogRead(
            PostgreSQLSchemaQueries.fetchPartitions(schema: resolvedSchema, table: table),
            namesRelativeTo: resolvedSchema
        )
        return result.rows.compactMap { row -> PostgreSQLPartitionRow? in
            guard let name = row[0].asText else { return nil }
            let approximateRows = PostgreSQLSchemaQueries.rowEstimate(reltuples: row[safe: 4]?.asText).map { Int($0) }
            return PostgreSQLPartitionRow(
                name: name,
                schema: row[safe: 2]?.asText?.nilIfEmpty ?? schema ?? core.currentSchema,
                bound: PostgreSQLPartitionBound.display(rawExpression: row[safe: 3]?.asText),
                rowCount: approximateRows,
                relationType: Self.partitionRelationType(relkind: row[safe: 1]?.asText)
            )
        }
    }

    /// The namespace predicate is not optional. Without it the read matched `relname` alone, so two
    /// schemas holding a table of the same name returned each other's indexes merged into one list,
    /// which a comparison between those two schemas reports as neither side differing.
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let resolvedSchema = schema ?? core.currentSchema
        let query = PostgreSQLIndexQueries.indexList(
            schema: resolvedSchema, table: table, capabilities: catalogCapabilities
        )
        let result = try await catalogRead(query, namesRelativeTo: resolvedSchema)
        let ddl = try await fetchIndexSpellings(schema: resolvedSchema, table: table)
        return result.rows.compactMap { PostgreSQLIndexRow.index(from: $0, ddl: ddl)?.index }
    }

    func fetchIndexSpellings(
        schema: String,
        table: String?
    ) async throws -> [String: [String: PostgreSQLCatalogIndexDDL]] {
        let query = PostgreSQLIndexQueries.indexDDLQuery(schema: schema, table: table)
        let result = try await catalogRead(query)
        return PostgreSQLIndexQueries.indexDDL(rows: result.rows)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        try await exportCatalog.fetchForeignKeys(table: table, schema: schema)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.fetchTriggers(table: table, schema: schema)
    }

    func generateDropRoutineSQL(
        name: String,
        signature: String?,
        schema: String?,
        isFunction: Bool
    ) -> String? {
        exportCatalog.generateDropRoutineSQL(name: name, signature: signature, schema: schema, isFunction: isFunction)
    }

    var providesBulkForeignKeyFetch: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await exportCatalog.fetchAllForeignKeys(schema: schema)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await exportCatalog.fetchApproximateRowCount(table: table, schema: schema)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await exportCatalog.fetchTableDDL(table: table, schema: schema)
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        try await exportCatalog.fetchIndexDDL(table: table, schema: schema)
    }

    func fetchStandaloneIndexes(table: String, schema: String) async throws -> PostgreSQLStandaloneIndexes {
        try await exportCatalog.fetchStandaloneIndexes(table: table, schema: schema)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let query = PostgreSQLSchemaQueries.tableMetadata(schema: schema ?? core.currentSchema, table: table)
        let result = try await catalogRead(query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let totalSize = !row.isEmpty ? Int64(row[0].asText ?? "0") : nil
        let dataSize = row.count > 1 ? Int64(row[1].asText ?? "0") : nil
        let indexSize = row.count > 2 ? Int64(row[2].asText ?? "0") : nil
        let rowCount = PostgreSQLSchemaQueries.rowEstimate(reltuples: row[safe: 3]?.asText)
        let comment = row.count > 4 ? row[4].asText : nil

        return PluginTableMetadata(
            tableName: table,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: "PostgreSQL"
        )
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await catalogRead(PostgreSQLSchemaQueries.databases)
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await catalogRead(PostgreSQLSchemaQueries.listSchemas)
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let result = try await catalogRead(PostgreSQLSchemaQueries.databaseMetadata(database: database))
        let row = result.rows.first
        return PluginDatabaseMetadata(
            name: database,
            tableCount: (row?[safe: 0]?.asText).flatMap { Int($0) },
            sizeBytes: (row?[safe: 1]?.asText).flatMap { Int64($0) },
            isSystemDatabase: PostgreSQLSystemDatabases.postgreSQL.contains(database)
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let result = try await catalogRead(PostgreSQLSchemaQueries.allDatabaseMetadata)
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let dbName = row[safe: 0]?.asText else { return nil }
            return PluginDatabaseMetadata(
                name: dbName,
                sizeBytes: (row[safe: 1]?.asText).flatMap { Int64($0) },
                isSystemDatabase: PostgreSQLSystemDatabases.postgreSQL.contains(dbName)
            )
        }
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        try await exportCatalog.fetchDependentTypes(table: table, schema: schema)
    }

    private static let supportedEncodings: [String] = [
        "UTF8", "LATIN1", "SQL_ASCII", "WIN1252", "EUC_JP",
        "EUC_KR", "ISO_8859_5", "KOI8R", "SJIS", "BIG5", "GBK"
    ]

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let supportsProvider = versionedCapabilities.hasDatabaseICULocale

        async let templateDefaultsTask = fetchTemplate1Defaults()
        async let collationsTask = fetchCollations()
        let templateDefaults = await templateDefaultsTask
        let collations = await collationsTask
        let serverCollate = templateDefaults?.collate
        let serverIcuLocale = templateDefaults?.iculocale
        let libcCollations = collations.libc
        let icuCollations = collations.icu

        let encodingOptions = Self.supportedEncodings.map {
            PluginCreateDatabaseFormSpec.Option(value: $0, label: $0)
        }

        var fields: [PluginCreateDatabaseFormSpec.Field] = [
            PluginCreateDatabaseFormSpec.Field(
                id: "encoding",
                label: String(localized: "Encoding"),
                kind: .picker(options: encodingOptions, defaultValue: "UTF8")
            )
        ]

        if supportsProvider {
            let providerOptions: [PluginCreateDatabaseFormSpec.Option] = [
                PluginCreateDatabaseFormSpec.Option(value: "libc", label: "libc"),
                PluginCreateDatabaseFormSpec.Option(value: "icu", label: "icu")
            ]
            let defaultProvider = templateDefaults?.provider == "i" ? "icu" : "libc"
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "provider",
                label: String(localized: "Locale Provider"),
                kind: .picker(options: providerOptions, defaultValue: defaultProvider)
            ))
        }

        let serverDefaultSubtitle = String(localized: "(server default)")
        let libcOptions: [PluginCreateDatabaseFormSpec.Option] = libcCollations.map { name in
            PluginCreateDatabaseFormSpec.Option(
                value: name,
                label: name,
                subtitle: name == serverCollate ? serverDefaultSubtitle : nil
            )
        }

        fields.append(PluginCreateDatabaseFormSpec.Field(
            id: "collation",
            label: String(localized: "Collation"),
            kind: .searchable(options: libcOptions, defaultValue: serverCollate),
            visibleWhen: supportsProvider
                ? PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "libc")
                : nil
        ))

        if supportsProvider {
            let icuOptions: [PluginCreateDatabaseFormSpec.Option] = icuCollations.map { name in
                PluginCreateDatabaseFormSpec.Option(
                    value: name,
                    label: name,
                    subtitle: name == serverIcuLocale ? serverDefaultSubtitle : nil
                )
            }
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "icu_locale",
                label: String(localized: "ICU Locale"),
                kind: .searchable(options: icuOptions, defaultValue: serverIcuLocale),
                visibleWhen: PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "icu")
            ))
        }

        return PluginCreateDatabaseFormSpec(fields: fields)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = quoteIdentifier(request.name)

        guard let encoding = request.values["encoding"] else {
            throw LibPQPluginError(
                message: String(localized: "Encoding is required"),
                sqlState: nil,
                detail: nil
            )
        }
        guard Self.supportedEncodings.contains(encoding) else {
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid encoding: %@"), encoding),
                sqlState: nil,
                detail: nil
            )
        }

        var sql = "CREATE DATABASE \(quotedName) ENCODING \(PostgreSQLObjectQueries.quoteLiteral(encoding))"

        let supportsProvider = versionedCapabilities.hasDatabaseICULocale
        let provider = supportsProvider ? (request.values["provider"] ?? "libc") : "libc"

        switch provider {
        case "libc":
            guard let collation = request.values["collation"], !collation.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "Collation is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            async let allowedCollationsTask = fetchCollations().libc
            async let templateDefaultsTask = fetchTemplate1Defaults()
            let allowedCollations = await allowedCollationsTask
            guard allowedCollations.contains(collation) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid collation: %@"), collation),
                    sqlState: nil,
                    detail: nil
                )
            }
            let collationLiteral = PostgreSQLObjectQueries.quoteLiteral(collation)
            sql += " LC_COLLATE \(collationLiteral) LC_CTYPE \(collationLiteral)"

            guard let templateDefaults = await templateDefaultsTask else {
                throw LibPQPluginError(
                    message: String(localized: "Failed to read template1 collation defaults"),
                    sqlState: nil,
                    detail: nil
                )
            }
            if templateDefaults.collate != collation {
                sql += " TEMPLATE template0"
            }

        case "icu":
            guard supportsProvider else {
                throw LibPQPluginError(
                    message: String(localized: "ICU provider requires PostgreSQL 15 or later"),
                    sqlState: nil,
                    detail: nil
                )
            }
            guard let icuLocale = request.values["icu_locale"], !icuLocale.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "ICU locale is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            let allowedIcu = await fetchCollations().icu
            guard allowedIcu.contains(icuLocale) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid ICU locale: %@"), icuLocale),
                    sqlState: nil,
                    detail: nil
                )
            }
            let icuLiteral = PostgreSQLObjectQueries.quoteLiteral(icuLocale)
            if versionedCapabilities.hasModernICUSyntax {
                sql += " LOCALE_PROVIDER 'icu' LOCALE \(icuLiteral) TEMPLATE template0"
            } else {
                sql += " LOCALE_PROVIDER 'icu' ICU_LOCALE \(icuLiteral) LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
            }

        default:
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid locale provider: %@"), provider),
                sqlState: nil,
                detail: nil
            )
        }

        _ = try await execute(query: sql)
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP DATABASE \(quoteIdentifier(name))")
    }

    private struct Template1Defaults {
        let collate: String
        let ctype: String
        let provider: String?
        let iculocale: String?
    }

    private func fetchTemplate1Defaults() async -> Template1Defaults? {
        let caps = versionedCapabilities
        let selectColumns: String
        if caps.hasDatabaseLocale {
            selectColumns = "datcollate, datctype, datlocprovider, datlocale"
        } else if caps.hasDatabaseICULocale {
            selectColumns = "datcollate, datctype, datlocprovider, daticulocale"
        } else {
            selectColumns = "datcollate, datctype, NULL, NULL"
        }
        do {
            let result = try await catalogRead(
                "SELECT \(selectColumns) FROM pg_catalog.pg_database WHERE datname = 'template1'"
            )
            guard let row = result.rows.first,
                  row.count >= 4,
                  let collate = row[0].asText,
                  let ctype = row[1].asText else {
                return nil
            }
            return Template1Defaults(
                collate: collate,
                ctype: ctype,
                provider: row[2].asText,
                iculocale: row[3].asText
            )
        } catch {
            Self.logger.error(
                "Failed to read template1 defaults: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func fetchCollations() async -> (libc: [String], icu: [String]) {
        do {
            let result = try await catalogRead(PostgreSQLSchemaQueries.collationList(capabilities: catalogCapabilities))
            var libc: [String] = []
            var icu: [String] = []
            for row in result.rows {
                guard row.count >= 2, let name = row[0].asText, let provider = row[1].asText else { continue }
                switch provider {
                case "b", "c":
                    libc.append(name)
                case "i":
                    icu.append(name)
                default:
                    continue
                }
            }
            return (libc: libc, icu: icu)
        } catch {
            Self.logger.error(
                "Failed to read pg_collation: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return (libc: [], icu: [])
        }
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        PostgreSQLSchemaQueries.allTablesMetadata(schema: schema ?? currentSchema ?? "public")
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        PostgreSQLCreateTableSQL.script(definition, schema: core.currentSchema, capabilities: versionedCapabilities)
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        PostgreSQLCreateTableSQL.statements(definition, schema: core.currentSchema, capabilities: versionedCapabilities)
    }

    private func pgColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        PostgreSQLCreateTableSQL.columnDefinition(col, inlinePK: inlinePK, capabilities: versionedCapabilities)
    }

    /// PostgreSQL 17 added ALTER COLUMN ... SET EXPRESSION AS, which rewrites the column in place.
    /// Nothing else is expressible: making a plain column generated, or a generated one plain, needs
    /// the column dropped and re-added, so those return nil and the operation is refused rather than
    /// silently applying the rest of the edit.
    private func pgGenerationChangeSQL(
        qt: String,
        colName: String,
        old: PluginColumnDefinition,
        new: PluginColumnDefinition
    ) -> String? {
        let oldExpression = old.generationExpression?.nilIfEmpty
        let newExpression = new.generationExpression?.nilIfEmpty
        guard oldExpression != newExpression || old.generationKind != new.generationKind else { return nil }
        guard newExpression != nil, oldExpression != nil else { return nil }
        guard versionedCapabilities.hasSetGeneratedExpression,
              let expression = PostgreSQLColumnClauses.generationExpression(for: new) else { return nil }
        return "ALTER TABLE \(qt) ALTER COLUMN \(colName) SET EXPRESSION AS (\(expression))"
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        guard schemaOperationRefusal(.addColumn(column)) == nil else { return nil }
        return pgColumnDefinition(column, inlinePK: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        guard schemaOperationRefusal(.addIndex(index)) == nil else { return nil }
        let qualifiedTable = tableName.map { quoteIdentifier($0) } ?? "\"table\""
        return PostgreSQLIndexClauses.createStatement(for: index, qualifiedTable: qualifiedTable)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        PostgreSQLCreateTableSQL.foreignKeyDefinition(fk)
    }

    // MARK: - ALTER TABLE DDL

    private func qualifiedTableName(_ table: String) -> String {
        "\(quoteIdentifier(core.currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        guard schemaOperationRefusal(.addColumn(column)) == nil else { return nil }
        let qt = qualifiedTableName(table)
        let colDef = pgColumnDefinition(column, inlinePK: false)
        let add = "ALTER TABLE \(qt) ADD COLUMN \(colDef)"
        guard let comment = column.comment, !comment.isEmpty else { return add }
        let commentStatement = PostgreSQLRelationSQL.columnCommentStatement(
            qualifiedTable: qt,
            column: column.name,
            comment: comment
        )
        return add + ";\n" + commentStatement
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        let colName = quoteIdentifier(newColumn.name)

        if let type = PostgreSQLColumnClauses.alterType(old: oldColumn, new: newColumn) {
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) TYPE \(type)")
        }

        if oldColumn.isNullable != newColumn.isNullable {
            let clause = newColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(clause)")
        }

        if oldColumn.defaultValue != newColumn.defaultValue {
            if let defaultValue = PostgreSQLColumnClauses.defaultExpression(for: newColumn) {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) SET DEFAULT \(defaultValue)")
            } else {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) DROP DEFAULT")
            }
        }

        if let generationStatement = pgGenerationChangeSQL(qt: qt, colName: colName, old: oldColumn, new: newColumn) {
            stmts.append(generationStatement)
        }

        if let newComment = newColumn.comment, !newComment.isEmpty, newColumn.comment != oldColumn.comment {
            stmts.append(PostgreSQLRelationSQL.columnCommentStatement(
                qualifiedTable: qt, column: newColumn.name, comment: newComment
            ))
        } else if oldColumn.comment != nil && (newColumn.comment == nil || newColumn.comment?.isEmpty == true) {
            stmts.append(PostgreSQLRelationSQL.columnCommentStatement(
                qualifiedTable: qt, column: newColumn.name, comment: nil
            ))
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard schemaOperationRefusal(.addIndex(index)) == nil else { return nil }
        return PostgreSQLIndexClauses.createStatement(for: index, qualifiedTable: qualifiedTableName(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(core.currentSchema)).\(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) ADD \(PostgreSQLCreateTableSQL.foreignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTableName(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String? {
        PostgreSQLVersionedStatements.renameConstraint(
            qualifiedTable: qualifiedTableName(table),
            from: oldName,
            to: newName,
            capabilities: versionedCapabilities
        )
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            stmts.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
    }
}
