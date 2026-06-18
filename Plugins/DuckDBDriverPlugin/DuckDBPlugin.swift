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
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "DuckDB analytical database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
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
    static let fileExtensions: [String] = ["duckdb", "ddb"]
    static let brandColorHex = "#FFD900"
    static let supportsDatabaseSwitching = false
    static let parameterStyle: ParameterStyle = .dollar
    static let systemDatabaseNames: [String] = ["information_schema", "pg_catalog"]
    static let databaseGroupingStrategy: GroupingStrategy = .flat
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
        paginationStyle: .limit
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

    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBPluginDriver")

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
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

        stateLock.lock()
        _currentSchema = "main"
        stateLock.unlock()

        await captureInterruptHandle()
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
        if let conn = await connectionActor.connectionHandleForInterrupt {
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
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = $1
            ORDER BY table_name
        """
        let result = try await executeParameterized(query: query, parameters: [.text(schemaName)])
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = (row[safe: 1]?.asText) ?? "BASE TABLE"
            let tableType = typeString.uppercased().contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT column_name, data_type, is_nullable, column_default, ordinal_position
            FROM information_schema.columns
            WHERE table_schema = $1
              AND table_name = $2
            ORDER BY ordinal_position
        """
        let result = try await executeParameterized(query: query, parameters: [.text(schemaName), .text(table)])

        let pkColumns = try await fetchPrimaryKeyColumns(table: table, schema: schemaName)
        let enumMap = try await fetchEnumLabelMap(schema: schemaName)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText else {
                return nil
            }

            let isNullable = (row[safe: 2]?.asText) == "YES"
            let defaultValue = row[safe: 3]?.asText
            let isPrimaryKey = pkColumns.contains(name)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                allowedValues: resolveEnumValues(dataType: dataType, enumMap: enumMap)
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT table_name, column_name, data_type, is_nullable, column_default, ordinal_position
            FROM information_schema.columns
            WHERE table_schema = $1
            ORDER BY table_name, ordinal_position
        """
        let result = try await executeParameterized(query: query, parameters: [.text(schemaName)])

        let pkQuery = """
            SELECT tc.table_name, kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
              AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = $1
        """
        let pkResult = try await executeParameterized(query: pkQuery, parameters: [.text(schemaName)])
        var pkMap: [String: Set<String>] = [:]
        for row in pkResult.rows {
            if let tableName = row[safe: 0]?.asText, let colName = row[safe: 1]?.asText {
                pkMap[tableName, default: []].insert(colName)
            }
        }

        let enumMap = try await fetchEnumLabelMap(schema: schemaName)
        var allColumns: [String: [PluginColumnInfo]] = [:]

        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let columnName = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText else {
                continue
            }

            let isNullable = (row[safe: 3]?.asText) == "YES"
            let defaultValue = row[safe: 4]?.asText
            let isPrimaryKey = pkMap[tableName]?.contains(columnName) ?? false

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                allowedValues: resolveEnumValues(dataType: dataType, enumMap: enumMap)
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    private func fetchEnumLabelMap(schema: String) async throws -> [String: [String]] {
        let typeNamesQuery = """
            SELECT type_name
            FROM duckdb_types()
            WHERE schema_name = $1 AND type_category = 'ENUM'
        """
        let typeResult: PluginQueryResult
        do {
            typeResult = try await executeParameterized(query: typeNamesQuery, parameters: [.text(schema)])
        } catch {
            return [:]
        }
        let typeNames = typeResult.rows.compactMap { $0[safe: 0]?.asText }
        guard !typeNames.isEmpty else { return [:] }

        let quotedSchema = quoteIdentifier(schema)
        var map: [String: [String]] = [:]
        for typeName in typeNames {
            let quoted = quoteIdentifier(typeName)
            let valuesQuery = "SELECT UNNEST(enum_range(NULL::\(quotedSchema).\(quoted)))::VARCHAR AS value"
            let valuesResult: PluginQueryResult
            do {
                valuesResult = try await execute(query: valuesQuery)
            } catch {
                continue
            }
            let labels = valuesResult.rows.compactMap { $0[safe: 0]?.asText }
            if !labels.isEmpty {
                map[typeName] = labels
            }
        }
        return map
    }

    private func resolveEnumValues(dataType: String, enumMap: [String: [String]]) -> [String]? {
        if let values = enumMap[dataType], !values.isEmpty {
            return values
        }
        return EnumValueParser.parseMySQLEnumOrSet(from: dataType)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT index_name, is_unique, sql, index_oid
            FROM duckdb_indexes()
            WHERE schema_name = $1
              AND table_name = $2
        """

        do {
            let result = try await executeParameterized(
                query: query, parameters: [.text(schemaName), .text(table)]
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
        let query = """
            SELECT
                rc.constraint_name,
                kcu.column_name,
                kcu2.table_name AS referenced_table,
                kcu2.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.referential_constraints rc
            JOIN information_schema.key_column_usage kcu
                ON rc.constraint_name = kcu.constraint_name
                AND rc.constraint_schema = kcu.constraint_schema
            JOIN information_schema.key_column_usage kcu2
                ON rc.unique_constraint_name = kcu2.constraint_name
                AND rc.unique_constraint_schema = kcu2.constraint_schema
                AND kcu.ordinal_position = kcu2.ordinal_position
            WHERE kcu.table_schema = $1
              AND kcu.table_name = $2
        """

        do {
            let result = try await executeParameterized(
                query: query, parameters: [.text(schemaName), .text(table)]
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
        let nativeQuery = "SELECT sql FROM duckdb_tables() WHERE schema_name = $1 AND table_name = $2"
        let nativeResult = try await executeParameterized(query: nativeQuery, parameters: [.text(schemaName), .text(table)])

        if let firstRow = nativeResult.rows.first, let sql = firstRow[0].asText {
            var ddl = sql.hasSuffix(";") ? sql : sql + ";"

            // Append index definitions
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
        let query = """
            SELECT view_definition
            FROM information_schema.views
            WHERE table_schema = $1
              AND table_name = $2
        """
        let result = try await executeParameterized(query: query, parameters: [.text(schemaName), .text(view)])

        guard let firstRow = result.rows.first,
              let definition = firstRow[0].asText else {
            throw DuckDBPluginError.queryFailed(
                "Failed to fetch definition for view '\(view)'"
            )
        }

        return "CREATE VIEW \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(view))\" AS\n\(definition)"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let schemaName = resolveSchema(schema)
        let safeTable = escapeIdentifier(table)
        let safeSchema = escapeIdentifier(schemaName)
        let countQuery =
            "SELECT COUNT(*) FROM (SELECT 1 FROM \"\(safeSchema)\".\"\(safeTable)\" LIMIT 100001) AS _t"
        let countResult = try await execute(query: countQuery)
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
        let query = "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name"
        if let remoteAlias {
            let schemas = (try? await execute(query: query))?.rows.compactMap { $0[safe: 0]?.asText } ?? []
            return schemas.isEmpty ? ["main"] : schemas
        }
        let result = try await execute(query: query)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func switchSchema(to schema: String) async throws {
        let safeSchema = escapeIdentifier(schema)
        _ = try await execute(query: "SET schema = \"\(safeSchema)\"")
        stateLock.lock()
        _currentSchema = schema
        stateLock.unlock()
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        if let remoteAlias {
            return [remoteAlias]
        }
        let query = "SELECT database_name FROM duckdb_databases() ORDER BY database_name"
        let result = try await execute(query: query)
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

    func allTablesMetadataSQL(schema: String?) -> String? {
        let s = (schema ?? currentSchema ?? "main").replacingOccurrences(of: "'", with: "''")
        return """
        SELECT
            table_schema as schema_name,
            table_name as name,
            table_type as kind
        FROM information_schema.tables
        WHERE table_schema = '\(s)'
        ORDER BY table_name
        """
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
        let query = """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
              AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = $1
              AND tc.table_name = $2
        """
        let result = try await executeParameterized(query: query, parameters: [.text(schema), .text(table)])
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
