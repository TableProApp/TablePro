//
//  DuckDBPlugin.swift
//  TablePro
//

import CDuckDB
import Foundation
import os
import TableProPluginKit

final class DuckDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Driver"
    static let pluginVersion = "1.1.0"
    static let pluginDescription = "DuckDB analytical database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"

    static let supportsRenameTable = true
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let connectionMode: ConnectionMode = .apiOnly
    static let urlSchemes: [String] = ["duckdb", "quack"]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "duckdbMode",
            label: String(localized: "Connection Type"),
            defaultValue: "local",
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(value: "local", label: String(localized: "Local File")),
                ConnectionField.DropdownOption(value: "remote", label: String(localized: "Remote (Quack, experimental)"))
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "duckdbFilePath",
            label: String(localized: "Database File"),
            placeholder: "/path/to/database.duckdb",
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
        ),
        ConnectionField(
            id: "duckdbHost",
            label: String(localized: "Host"),
            placeholder: "localhost",
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbPort",
            label: String(localized: "Port"),
            placeholder: "9494",
            defaultValue: "9494",
            fieldType: .number,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbToken",
            label: String(localized: "Token"),
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbAlias",
            label: String(localized: "Database Alias"),
            placeholder: "remotedb",
            required: true,
            defaultValue: "remotedb",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        )
    ]
    static let fileExtensions: [String] = DuckDBFileKinds.all
    static let brandColorHex = "#FFD900"
    static let parameterStyle: ParameterStyle = .dollar

    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let supportsRoutines = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let defaultSchemaName = "main"
    static let systemDatabaseNames: [String] = ["system", "temp"]
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC"],
        "String": ["VARCHAR", "TEXT", "CHAR", "BPCHAR"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "INTERVAL"],
        "Binary": ["BLOB", "BYTEA", "BIT", "BITSTRING"],
        "Boolean": ["BOOLEAN"],
        "JSON": ["JSON"],
        "UUID": ["UUID"],
        "List": ["LIST"],
        "Struct": ["STRUCT"],
        "Map": ["MAP"],
        "Union": ["UNION"],
        "Enum": ["ENUM"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "COPY", "PRAGMA", "DESCRIBE", "SUMMARIZE", "PIVOT", "UNPIVOT",
            "QUALIFY", "SAMPLE", "TABLESAMPLE", "RETURNING",
            "INSTALL", "LOAD", "FORCE", "ATTACH", "DETACH",
            "EXPORT", "IMPORT",
            "WITH", "RECURSIVE", "MATERIALIZED",
            "EXPLAIN", "ANALYZE",
            "WINDOW", "OVER", "PARTITION"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "LIST_AGG", "STRING_AGG", "ARRAY_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
            "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
            "EPOCH_MS",
            "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
            "CAST",
            "REGEXP_MATCHES", "READ_CSV", "READ_PARQUET", "READ_JSON",
            "GLOB", "STRUCT_PACK", "LIST_VALUE", "MAP", "UNNEST",
            "GENERATE_SERIES", "RANGE"
        ],
        dataTypes: [
            "INTEGER", "BIGINT", "HUGEINT", "UHUGEINT",
            "DOUBLE", "FLOAT", "DECIMAL",
            "VARCHAR", "TEXT", "BLOB",
            "BOOLEAN",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "INTERVAL",
            "UUID", "JSON",
            "LIST", "MAP", "STRUCT", "UNION", "ENUM", "BIT"
        ],
        regexSyntax: .regexpMatches,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DuckDBPluginDriver(config: config)
    }
}

// MARK: - DuckDB Plugin Driver

final class DuckDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let connectionActor = DuckDBConnectionActor()
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _connectionForInterrupt: duckdb_connection?
    nonisolated(unsafe) private var _currentSchema: String = "main"
    nonisolated(unsafe) private var _currentDatabase: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBPluginDriver")

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }

    var currentDatabase: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentDatabase
    }
    var serverVersion: String? { String(cString: duckdb_library_version()) }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var parameterStyle: ParameterStyle { .dollar }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .schemaCompare,
            .dataCompare,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    private func resolveSchema(_ schema: String?) -> String {
        if let schema { return schema }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }

    /// Every metadata query filters on the catalog, because `duckdb_tables()` and its
    /// siblings span every attached database and a schema name alone matches all of them.
    private func requireCatalog() throws -> String {
        stateLock.lock()
        let catalog = _currentDatabase
        stateLock.unlock()
        guard let catalog, !catalog.isEmpty else { throw DuckDBPluginError.catalogUnresolved }
        return catalog
    }

    // MARK: - Connection

    private var isRemoteMode: Bool {
        config.additionalFields["duckdbMode"] == "remote"
    }

    private var remoteAlias: String? {
        guard isRemoteMode else { return nil }
        let alias = (config.additionalFields["duckdbAlias"] ?? "").trimmingCharacters(in: .whitespaces)
        return alias.isEmpty ? "remotedb" : alias
    }

    func connect() async throws {
        if isRemoteMode {
            try await connectRemote()
        } else {
            try await connectLocal()
        }
    }

    private func connectLocal() async throws {
        let rawPath = config.additionalFields["duckdbFilePath"].flatMap { $0.isEmpty ? nil : $0 } ?? config.database
        let path = expandPath(rawPath)

        if !FileManager.default.fileExists(atPath: path) {
            guard DuckDBFileKinds.canBeCreated(atPath: path) else {
                throw DuckDBPluginError.connectionFailed(
                    String(format: String(localized: "No file at %@"), path)
                )
            }
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }

        try await connectionActor.open(path: path)
        await enableExtensionAutoloading()
        // DuckDB holds an exclusive lock on the file for as long as the handle is open, and
        // nothing upstream disconnects a driver whose connect threw: DatabaseManager only
        // calls disconnect on a cancelled attempt. Without this, one failure here locks the
        // file against every later attempt until TablePro quits.
        do {
            try await refreshCurrentPosition()
        } catch {
            await connectionActor.close()
            throw error
        }
        await captureInterruptHandle()
    }

    private func connectRemote() async throws {
        let host = (config.additionalFields["duckdbHost"] ?? "").trimmingCharacters(in: .whitespaces)
        let aliasInput = (config.additionalFields["duckdbAlias"] ?? "").trimmingCharacters(in: .whitespaces)
        let portInput = config.additionalFields["duckdbPort"] ?? ""
        let token = config.additionalFields["duckdbToken"] ?? ""

        guard QuackConnectBuilder.isValidHost(host) else {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "Host is required for a remote DuckDB connection")
            )
        }
        guard let port = QuackConnectBuilder.normalizedPort(portInput) else {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "Port must be a number between 1 and 65535")
            )
        }
        let alias = aliasInput.isEmpty ? "remotedb" : aliasInput

        try await connectionActor.open(path: ":memory:")
        await enableExtensionAutoloading()
        await loadQuackExtension()

        if !token.isEmpty {
            try await connectionActor.executeQuery(QuackConnectBuilder.secretSQL(token: token))
        }

        try await connectionActor.executeQuery(QuackConnectBuilder.attachSQL(host: host, port: port, alias: alias))
        try await connectionActor.executeQuery(QuackConnectBuilder.useSQL(alias: alias))

        stateLock.withLock {
            _currentSchema = "main"
            _currentDatabase = alias
        }

        await captureInterruptHandle()
    }

    /// Every metadata query is anchored to the catalog, and the app seeds the browsed
    /// database from `currentDatabase`, so the driver has to know which catalog the file
    /// opened as. DuckDB names it after the file stem, which is not derivable from the
    /// path alone once an alias or a URL is involved.
    ///
    /// This throws rather than logging and carrying on. Swallowing it left the connection
    /// reporting success with no catalog, which every later query then filtered on, so the
    /// sidebar came up empty and nothing said why.
    private func refreshCurrentPosition() async throws {
        let position = try await readPosition()
        let catalog = try await resolveOpenedCatalog(named: position.catalog)

        stateLock.withLock {
            _currentDatabase = catalog
            if let schema = position.schema { _currentSchema = schema }
        }
    }

    /// Nothing has run `USE` yet at connect, so `search_path` is usually empty and the catalog
    /// comes from the one non-internal database the file opened as. Anything other than exactly
    /// one is reported rather than guessed at: picking a row would anchor every metadata query
    /// to a database the connection is not on, which is the empty sidebar this all started from.
    private func resolveOpenedCatalog(named: String?) async throws -> String {
        if let named, let canonical = await canonicalCatalogName(matching: named) {
            return canonical
        }

        let databases = try await connectionActor.executeQuery(DuckDBSchemaQueries.listDatabases)
        let names = databases.rows.compactMap { $0[safe: 0]?.asText?.nilIfEmpty }
        guard names.count == 1, let only = names.first else {
            throw DuckDBPluginError.connectionFailed(
                names.isEmpty
                    ? String(localized: "DuckDB opened the file but reported no catalog to browse")
                    : String(
                        format: String(localized: "DuckDB opened %d catalogs and none of them is current"),
                        names.count
                    )
            )
        }
        return only
    }

    private func readPosition() async throws -> DuckDBPositionParser.Position {
        let result = try await connectionActor.executeQuery(DuckDBSchemaQueries.currentPosition)
        var settings: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, let value = row[safe: 1]?.asText else { continue }
            settings[name] = value
        }
        return DuckDBPositionParser.parse(settings: settings)
    }

    private func enableExtensionAutoloading() async {
        do {
            try await connectionActor.executeQuery("SET autoinstall_known_extensions=1")
            try await connectionActor.executeQuery("SET autoload_known_extensions=1")
        } catch {
            Self.logger.warning("Failed to enable DuckDB extension autoloading: \(error.localizedDescription)")
        }
    }

    private func loadQuackExtension() async {
        for statement in ["INSTALL quack", "LOAD quack"] {
            do {
                try await connectionActor.executeQuery(statement)
            } catch {
                Self.logger.warning("DuckDB '\(statement)' failed: \(error.localizedDescription)")
            }
        }
    }

    private func captureInterruptHandle() async {
        if let conn = await connectionActor.connectionHandleForInterrupt.connection {
            setInterruptHandle(conn)
        }
    }

    func disconnect() {
        stateLock.lock()
        _connectionForInterrupt = nil
        stateLock.unlock()
        let actor = connectionActor
        Task { await actor.close() }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        // DuckDB doesn't have a session-level query timeout like network databases
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeQuery(query)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue]
    ) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executePrepared(query, parameters: parameters)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func cancelQuery() throws {
        stateLock.lock()
        let conn = _connectionForInterrupt
        stateLock.unlock()
        guard let conn else { return }
        duckdb_interrupt(conn)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let actor = connectionActor

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                do {
                    try await actor.streamQuery(query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let schemaName = resolveSchema(schema)
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.listTables,
            parameters: [.text(try requireCatalog()), .text(schemaName)]
        )
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = (row[safe: 1]?.asText) ?? "BASE TABLE"
            let tableType = typeString.uppercased().contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let schemaName = resolveSchema(schema)
        let catalog = try requireCatalog()
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.columnsForTable,
            parameters: [.text(catalog), .text(schemaName), .text(table)]
        )

        let pkColumns = try await fetchPrimaryKeyColumns(table: table, schema: schemaName)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText else {
                return nil
            }

            let isNullable = Self.isNullableFlag(row[safe: 2]?.asText)
            let defaultValue = row[safe: 3]?.asText
            let isPrimaryKey = pkColumns.contains(name)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                allowedValues: resolveEnumValues(dataType: dataType)
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let schemaName = resolveSchema(schema)
        let catalog = try requireCatalog()
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.columnsForSchema,
            parameters: [.text(catalog), .text(schemaName)]
        )

        let pkResult = try await executeParameterized(
            query: DuckDBSchemaQueries.primaryKeyColumnsForSchema,
            parameters: [.text(catalog), .text(schemaName)]
        )
        var pkMap: [String: Set<String>] = [:]
        for row in pkResult.rows {
            if let tableName = row[safe: 0]?.asText, let colName = row[safe: 1]?.asText {
                pkMap[tableName, default: []].insert(colName)
            }
        }

        var allColumns: [String: [PluginColumnInfo]] = [:]

        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let columnName = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText else {
                continue
            }

            let isNullable = Self.isNullableFlag(row[safe: 3]?.asText)
            let defaultValue = row[safe: 4]?.asText
            let isPrimaryKey = pkMap[tableName]?.contains(columnName) ?? false

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                allowedValues: resolveEnumValues(dataType: dataType)
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    /// `duckdb_columns()` types `is_nullable` as BOOLEAN, so the value arrives as `true`.
    private static func isNullableFlag(_ value: String?) -> Bool {
        value == "true"
    }

    /// DuckDB spells an ENUM column's type as `ENUM('ok', 'bad')`, members included, so the
    /// allowed values are already in hand. The driver used to also query `duckdb_types()` for
    /// them and key the result on `type_name`, which is `mood`, so that map never matched a
    /// column and every value came from this parse anyway. The query is gone rather than
    /// repaired: it cost a round trip per column fetch and answered nothing.
    private func resolveEnumValues(dataType: String) -> [String]? {
        EnumValueParser.parseMySQLEnumOrSet(from: dataType)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let schemaName = resolveSchema(schema)
        let catalog = try requireCatalog()
        do {
            let result = try await executeParameterized(
                query: DuckDBSchemaQueries.indexesForTable,
                parameters: [.text(catalog), .text(schemaName), .text(table)]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0]?.asText else { return nil }
                let isUnique = (row[safe: 1]?.asText) == "true"
                let sql = row[safe: 2]?.asText
                let isPrimary = name.lowercased().contains("primary")
                    || (sql?.uppercased().contains("PRIMARY KEY") ?? false)

                let columns = extractIndexColumns(from: sql)

                return PluginIndexInfo(
                    name: name,
                    columns: columns,
                    isUnique: isUnique || isPrimary,
                    isPrimary: isPrimary,
                    type: "ART"
                )
            }.sorted { $0.isPrimary && !$1.isPrimary }
        } catch {
            return []
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let schemaName = resolveSchema(schema)
        let catalog = try requireCatalog()
        do {
            let result = try await executeParameterized(
                query: DuckDBSchemaQueries.foreignKeysForTable,
                parameters: [.text(catalog), .text(schemaName), .text(table)]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0]?.asText,
                      let column = row[safe: 1]?.asText,
                      let refTable = row[safe: 2]?.asText,
                      let refColumn = row[safe: 3]?.asText else {
                    return nil
                }

                let onDelete = (row[safe: 4]?.asText) ?? "NO ACTION"
                let onUpdate = (row[safe: 5]?.asText) ?? "NO ACTION"

                return PluginForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: refTable,
                    referencedColumn: refColumn,
                    onDelete: onDelete,
                    onUpdate: onUpdate
                )
            }
        } catch {
            return []
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)

        // Try native DDL from duckdb_tables() first (preserves complex types like LIST, STRUCT, MAP)
        let nativeResult = try await executeParameterized(
            query: DuckDBSchemaQueries.tableDDL,
            parameters: [.text(try requireCatalog()), .text(schemaName), .text(table)]
        )

        if let firstRow = nativeResult.rows.first, let sql = firstRow[0].asText {
            var ddl = sql.hasSuffix(";") ? sql : sql + ";"

            let indexes = try await fetchIndexes(table: table, schema: schemaName)
            for index in indexes where !index.isPrimary {
                let uniqueStr = index.isUnique ? "UNIQUE " : ""
                let cols = index.columns.map { "\"\(escapeIdentifier($0))\"" }.joined(separator: ", ")
                ddl += "\n\nCREATE \(uniqueStr)INDEX \"\(escapeIdentifier(index.name))\""
                    + " ON \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\""
                    + " (\(cols));"
            }

            return ddl
        }

        // Fallback: synthesize DDL from schema metadata
        let columns = try await fetchColumns(table: table, schema: schemaName)
        let indexes = try await fetchIndexes(table: table, schema: schemaName)
        let fks = try await fetchForeignKeys(table: table, schema: schemaName)

        var ddl = "CREATE TABLE \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\" (\n"

        let columnDefs = columns.map { col in
            var def = "  \"\(escapeIdentifier(col.name))\" \(col.dataType)"
            if !col.isNullable { def += " NOT NULL" }
            if let defaultVal = col.defaultValue { def += " DEFAULT \(defaultVal)" }
            return def
        }

        var allDefs = columnDefs

        let pkColumns = columns.filter(\.isPrimaryKey)
        if !pkColumns.isEmpty {
            let pkCols = pkColumns.map { "\"\(escapeIdentifier($0.name))\"" }
                .joined(separator: ", ")
            allDefs.append("  PRIMARY KEY (\(pkCols))")
        }

        for fk in fks {
            let fkDef = "  FOREIGN KEY (\"\(escapeIdentifier(fk.column))\")"
                + " REFERENCES \"\(escapeIdentifier(fk.referencedTable))\""
                + "(\"\(escapeIdentifier(fk.referencedColumn))\")"
                + " ON DELETE \(fk.onDelete) ON UPDATE \(fk.onUpdate)"
            allDefs.append(fkDef)
        }

        ddl += allDefs.joined(separator: ",\n")
        ddl += "\n);"

        for index in indexes where !index.isPrimary {
            let uniqueStr = index.isUnique ? "UNIQUE " : ""
            let cols = index.columns.map { "\"\(escapeIdentifier($0))\"" }.joined(separator: ", ")
            ddl += "\n\nCREATE \(uniqueStr)INDEX \"\(escapeIdentifier(index.name))\""
                + " ON \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\""
                + " (\(cols));"
        }

        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.viewDefinition,
            parameters: [.text(try requireCatalog()), .text(schemaName), .text(view)]
        )

        guard let firstRow = result.rows.first,
              let definition = firstRow[0].asText?.nilIfEmpty else {
            throw DuckDBPluginError.queryFailed(
                "Failed to fetch definition for view '\(view)'"
            )
        }

        return DuckDBViewDefinition.makeReplaceable(definition)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let schemaName = resolveSchema(schema)
        let countResult = try await execute(
            query: DuckDBSchemaQueries.rowCountProbe(schema: schemaName, table: table, limit: 100_001)
        )
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let firstCell = row.first else { return nil }
            return Int64(firstCell.asText ?? "0")
        }()

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            engine: "DuckDB"
        )
    }

    // MARK: - Schema Navigation

    func fetchSchemas() async throws -> [String] {
        let query = DuckDBSchemaQueries.listSchemas
        let parameters: [PluginCellValue] = [.text(try requireCatalog())]
        if remoteAlias != nil {
            let result = try? await executeParameterized(query: query, parameters: parameters)
            let schemas = result?.rows.compactMap { $0[safe: 0]?.asText } ?? []
            return schemas.isEmpty ? ["main"] : schemas
        }
        let result = try await executeParameterized(query: query, parameters: parameters)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func switchSchema(to schema: String) async throws {
        _ = try await execute(query: DuckDBSchemaQueries.useSchema(schema, in: currentDatabase))
        stateLock.withLock { _currentSchema = schema }
    }

    // MARK: - Database Operations

    /// `USE` on a catalog also moves the connection onto that catalog's default schema, so
    /// the tracked schema has to follow or the next `pin` skips a switch it still needs.
    /// The new schema is read back rather than assumed to be `main`: a catalog attached
    /// through the postgres or mysql scanner defaults to that engine's own schema.
    /// The name is canonicalised against `duckdb_databases()` rather than stored as typed.
    /// DuckDB resolves a catalog case-insensitively, so `USE "FIXTURE"` moves to `fixture`
    /// and writes `FIXTURE.main` into `search_path`, but `duckdb_tables()` compares
    /// `database_name` exactly: every metadata query would then filter on `FIXTURE` and
    /// return nothing, which is an empty sidebar on a connection that switched fine.
    ///
    /// The reads run before the state is committed and each falls back rather than throwing.
    /// The `USE` has already moved the connection by then, so an early return would leave the
    /// tracked catalog pointing at the database the connection just left.
    func switchDatabase(to database: String) async throws {
        _ = try await execute(query: DuckDBSchemaQueries.useDatabase(database))
        let canonical = await canonicalCatalogName(matching: database) ?? database
        let landedSchema = try? await readPosition().schema
        stateLock.withLock {
            _currentDatabase = canonical
            _currentSchema = landedSchema.flatMap { $0 } ?? "main"
        }
    }

    private func canonicalCatalogName(matching database: String) async -> String? {
        guard let result = try? await execute(query: DuckDBSchemaQueries.listDatabases) else { return nil }
        let names = result.rows.compactMap { $0[safe: 0]?.asText }
        return names.first { $0 == database } ?? names.first { $0.lowercased() == database.lowercased() }
    }

    func fetchDatabases() async throws -> [String] {
        if let remoteAlias {
            return [remoteAlias]
        }
        let result = try await execute(query: DuckDBSchemaQueries.listDatabases)
        return result.rows.compactMap { row in
            row[safe: 0]?.asText
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - All Tables Metadata

    /// The app hands this an already escaped schema literal, so it is passed through rather
    /// than escaped a second time.
    func allTablesMetadataSQL(schema: String?) -> String? {
        guard let catalog = currentDatabase?.nilIfEmpty else { return nil }
        let escapedSchema = schema ?? escapeStringLiteral(currentSchema ?? "main")
        return DuckDBSchemaQueries.allTablesMetadata(catalog: catalog, escapedSchema: escapedSchema)
    }

    // MARK: - Private Helpers

    nonisolated private func setInterruptHandle(_ handle: duckdb_connection?) {
        stateLock.lock()
        _connectionForInterrupt = handle
        stateLock.unlock()
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    private func escapeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func fetchPrimaryKeyColumns(
        table: String,
        schema: String
    ) async throws -> Set<String> {
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.primaryKeyColumnsForTable,
            parameters: [.text(try requireCatalog()), .text(schema), .text(table)]
        )
        return Set(result.rows.compactMap { $0[safe: 0]?.asText })
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = resolveSchema(nil)
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { duckdbColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(duckdbForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(duckdbIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func duckdbColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var dataType = col.dataType
        if col.autoIncrement {
            let upper = dataType.uppercased()
            if upper == "BIGINT" || upper == "INT8" {
                dataType = "BIGSERIAL"
            } else {
                dataType = "SERIAL"
            }
        }

        var def = "\(quoteIdentifier(col.name)) \(dataType)"
        if !col.autoIncrement {
            if col.isNullable {
                def += " NULL"
            } else {
                def += " NOT NULL"
            }
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(duckdbDefaultValue(defaultValue))"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func duckdbDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
            || upper == "CURRENT_TIMESTAMP" || upper == "NOW()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func duckdbIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
    }

    private func duckdbForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(quoteIdentifier(fk.referencedTable)) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    private func qualifiedTableName(_ table: String) -> String {
        "\(quoteIdentifier(resolveSchema(nil))).\(quoteIdentifier(table))"
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        let colDef = duckdbColumnDefinition(column, inlinePK: false)
        return "ALTER TABLE \(qt) ADD COLUMN \(colDef)"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        let colName = quoteIdentifier(newColumn.name)

        if oldColumn.dataType.uppercased() != newColumn.dataType.uppercased() {
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) TYPE \(newColumn.dataType)")
        }

        if oldColumn.isNullable != newColumn.isNullable {
            let clause = newColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(clause)")
        }

        if oldColumn.defaultValue != newColumn.defaultValue {
            if let defaultValue = newColumn.defaultValue {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) SET DEFAULT \(duckdbDefaultValue(defaultValue))")
            } else {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) DROP DEFAULT")
            }
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        duckdbIndexDefinition(index, qualifiedTable: qualifiedTableName(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) ADD \(duckdbForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
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

    private static let indexColumnsRegex = try? NSRegularExpression(
        pattern: #"ON\s+(?:(?:"[^"]*"|[^\s(]+)\s*\.\s*)*(?:"[^"]*"|[^\s(]+)\s*\(([^)]+)\)"#,
        options: .caseInsensitive
    )

    private func extractIndexColumns(from sql: String?) -> [String] {
        guard let sql, let regex = Self.indexColumnsRegex else { return [] }

        let range = NSRange(sql.startIndex..., in: sql)
        guard let match = regex.firstMatch(in: sql, range: range),
              match.numberOfRanges > 1,
              let columnsRange = Range(match.range(at: 1), in: sql) else {
            return []
        }

        return String(sql[columnsRange]).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
        }
    }
}
