//
//  CassandraPlugin.swift
//  TablePro
//
//  Cassandra/ScyllaDB database driver plugin using the DataStax C driver.
//  Provides CQL query execution and schema introspection via system_schema tables.
//

#if canImport(CCassandra)
import CCassandra
#endif
import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

internal final class CassandraPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Cassandra Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Apache Cassandra and ScyllaDB support via DataStax C driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Cassandra"
    static let databaseDisplayName = "Cassandra / ScyllaDB"
    static let iconName = "cassandra-icon"
    static let defaultPort = 9_042
    static let additionalConnectionFields: [ConnectionField] = AWSAuthFields.standard()
    static let additionalDatabaseTypeIds: [String] = ["ScyllaDB"]

    // MARK: - UI/Capability Metadata

    static let urlSchemes: [String] = ["cassandra", "cql", "scylladb", "scylla"]
    static let requiresAuthentication = false
    static let supportsForeignKeys = false
    static let brandColorHex = "#26A0D8"
    static let queryLanguageName = "CQL"
    static let supportsDatabaseSwitching = true
    static let containerEntityName = "Keyspace"
    static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    static let defaultGroupName = "default"
    static let systemDatabaseNames: [String] = [
        "system", "system_schema", "system_auth",
        "system_distributed", "system_traces", "system_virtual_schema",
    ]
    static let supportsImport = false
    static let supportsExport = true
    static let supportsCascadeDrop = false
    static let supportsForeignKeyDisable = false
    static let supportsSSH = true
    static let supportsSSL = true
    static let columnTypesByCategory: [String: [String]] = [
        "Numeric": ["TINYINT", "SMALLINT", "INT", "BIGINT", "VARINT", "FLOAT", "DOUBLE", "DECIMAL", "COUNTER"],
        "String": ["TEXT", "VARCHAR", "ASCII"],
        "Date": ["TIMESTAMP", "DATE", "TIME"],
        "Binary": ["BLOB"],
        "Boolean": ["BOOLEAN"],
        "Other": ["UUID", "TIMEUUID", "INET", "LIST", "SET", "MAP", "TUPLE", "FROZEN"],
    ]

    static var sqlDialect: SQLDialectDescriptor? {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "AS",
                "ORDER", "BY", "LIMIT",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW",
                "PRIMARY", "KEY", "ADD", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT",
                "CASE", "WHEN", "THEN", "ELSE", "END",
                "KEYSPACE", "USE", "TRUNCATE", "BATCH", "GRANT", "REVOKE",
                "CLUSTERING", "PARTITION", "TTL", "WRITETIME",
                "ALLOW FILTERING", "IF NOT EXISTS", "IF EXISTS",
                "USING TIMESTAMP", "USING TTL",
                "MATERIALIZED VIEW", "CONTAINS", "FROZEN", "COUNTER", "TOKEN",
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN",
                "NOW", "UUID", "TOTIMESTAMP", "TOKEN", "TTL", "WRITETIME",
                "MINTIMEUUID", "MAXTIMEUUID", "TODATE", "TOUNIXTIMESTAMP",
                "CAST",
            ],
            dataTypes: [
                "TEXT", "VARCHAR", "ASCII",
                "INT", "BIGINT", "SMALLINT", "TINYINT", "VARINT",
                "FLOAT", "DOUBLE", "DECIMAL",
                "BOOLEAN", "UUID", "TIMEUUID",
                "TIMESTAMP", "DATE", "TIME",
                "BLOB", "INET", "COUNTER",
                "LIST", "SET", "MAP", "TUPLE", "FROZEN",
            ],
            regexSyntax: .unsupported,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit,
            autoLimitStyle: .limit
        )
    }

    static let supportsDropDatabase = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        CassandraPluginDriver(config: config)
    }
}

// MARK: - Plugin Driver

internal final class CassandraPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let connectionActor = CassandraConnectionActor()
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _currentKeyspace: String?

    private static let logger = Logger(subsystem: "com.TablePro.CassandraDriver", category: "Driver")

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentKeyspace
    }

    var serverVersion: String? {
        // Fetched lazily and cached
        stateLock.lock()
        let cached = _cachedVersion
        stateLock.unlock()
        return cached
    }

    nonisolated(unsafe) private var _cachedVersion: String?

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .materializedViews,
            .alterTableDDL,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        let keyspace = config.database.isEmpty ? nil : config.database
        let legacyCaPath = config.additionalFields["sslCaCertPath"]
        let resolvedCaPath = config.ssl.caCertificatePath.isEmpty ? legacyCaPath : config.ssl.caCertificatePath
        let clientCertPath = config.ssl.clientCertificatePath.isEmpty ? nil : config.ssl.clientCertificatePath
        let clientKeyPath = config.ssl.clientKeyPath.isEmpty ? nil : config.ssl.clientKeyPath
        let clientKeyPassphrase = config.additionalFields["sslClientKeyPassphrase"]

        var awsCredentials: AWSCredentials?
        var awsRegion: String?
        let awsAuth = config.additionalFields["awsAuth"] ?? "off"
        if awsAuth != "off", !awsAuth.isEmpty {
            guard let region = config.additionalFields["awsRegion"].flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw AWSAuthError.regionUnknown(host: config.host)
            }
            guard config.ssl.mode != .disabled else {
                throw AWSAuthError.missingConfiguration(
                    String(localized: "Amazon Keyspaces IAM authentication requires TLS. Enable SSL in the connection's SSL settings.")
                )
            }
            awsRegion = region
            awsCredentials = try await AWSCredentialResolver.resolve(source: awsAuth, fields: config.additionalFields)
        }

        try await connectionActor.connect(
            host: config.host,
            port: Int(config.port) ?? 9_042,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            keyspace: keyspace,
            sslMode: config.ssl.mode,
            sslCaCertPath: resolvedCaPath,
            sslClientCertPath: clientCertPath,
            sslClientKeyPath: clientKeyPath,
            sslClientKeyPassphrase: clientKeyPassphrase,
            awsCredentials: awsCredentials,
            awsRegion: awsRegion
        )

        if let keyspace {
            stateLock.lock()
            _currentKeyspace = keyspace
            stateLock.unlock()
        }

        if let version = try? await connectionActor.serverVersion() {
            stateLock.lock()
            _cachedVersion = version
            stateLock.unlock()
        }

        let caps = CassandraCapabilities(
            releaseVersionMajor: CassandraCapabilities.parseMajorVersion(serverVersion)
        )
        guard caps.hasSystemSchemaKeyspace else {
            throw CassandraPluginError.connectionFailed(String(
                format: String(localized: "Cassandra %@ is not supported. TablePro requires Cassandra 3.0 or later (the system_schema keyspace was introduced in 3.0)."),
                serverVersion ?? "<unknown>"
            ))
        }
    }

    func disconnect() {
        Task.detached(priority: .utility) { [connectionActor] in
            await connectionActor.close()
        }
        stateLock.lock()
        _currentKeyspace = nil
        _cachedVersion = nil
        stateLock.unlock()
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT key FROM system.local WHERE key = 'local'")
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        // Cassandra doesn't support session-level query timeouts via CQL.
        // The request timeout is set at connection time via cass_cluster_set_request_timeout.
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeQuery(query)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime
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
            executionTime: rawResult.executionTime
        )
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let cql = stripTrailingSemicolon(query)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.connectionActor.streamQuery(cql, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let ks = resolveKeyspace(schema)

        let tablesQuery = """
            SELECT table_name FROM system_schema.tables WHERE keyspace_name = '\(escapeSingleQuote(ks))'
        """
        let tablesResult = try await execute(query: tablesQuery)

        let tables = tablesResult.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginTableInfo(name: name, type: "TABLE")
        }

        return tables.sorted { $0.name < $1.name }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let ks = resolveKeyspace(schema)
        let query = """
            SELECT column_name, type, kind, clustering_order, position
            FROM system_schema.columns
            WHERE keyspace_name = '\(escapeSingleQuote(ks))'
              AND table_name = '\(escapeSingleQuote(table))'
        """
        let result = try await execute(query: query)

        struct RawColumn {
            let name: String
            let dataType: String
            let kind: String
            let position: Int
            let isPrimaryKey: Bool
        }

        let rawColumns = result.rows.compactMap { row -> RawColumn? in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText else {
                return nil
            }
            let kind = row[safe: 2]?.asText ?? "regular"
            let position = Int(row[safe: 4]?.asText ?? "0") ?? 0
            let isPrimaryKey = kind == "partition_key" || kind == "clustering"
            return RawColumn(name: name, dataType: dataType, kind: kind, position: position, isPrimaryKey: isPrimaryKey)
        }.sorted { lhs, rhs in
            let lhsOrder = columnKindOrder(lhs.kind)
            let rhsOrder = columnKindOrder(rhs.kind)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.position < rhs.position
        }

        return rawColumns.map { col in
            PluginColumnInfo(
                name: col.name,
                dataType: col.dataType,
                isNullable: !col.isPrimaryKey,
                isPrimaryKey: col.isPrimaryKey,
                defaultValue: nil
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let ks = resolveKeyspace(schema)
        let query = """
            SELECT table_name, column_name, type, kind, clustering_order, position
            FROM system_schema.columns
            WHERE keyspace_name = '\(escapeSingleQuote(ks))'
        """
        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]

        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let columnName = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText else {
                continue
            }
            let kind = row[safe: 3]?.asText
            let isPrimaryKey = kind == "partition_key" || kind == "clustering"

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: !isPrimaryKey,
                isPrimaryKey: isPrimaryKey,
                defaultValue: nil
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let ks = resolveKeyspace(schema)
        let query = """
            SELECT index_name, kind, options
            FROM system_schema.indexes
            WHERE keyspace_name = '\(escapeSingleQuote(ks))'
              AND table_name = '\(escapeSingleQuote(table))'
        """

        do {
            let result = try await execute(query: query)
            return result.rows.compactMap { row in
                guard let name = row[safe: 0]?.asText else { return nil }
                let kind = row[safe: 1]?.asText ?? "COMPOSITES"
                let options = row[safe: 2]?.asText ?? ""

                var targetColumns: [String] = []
                if let targetRange = options.range(of: "target: ") {
                    let target = String(options[targetRange.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "{},' "))
                    targetColumns = [target]
                }

                return PluginIndexInfo(
                    name: name,
                    columns: targetColumns,
                    isUnique: false,
                    isPrimary: false,
                    type: kind
                )
            }
        } catch {
            return []
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        // Cassandra does not support foreign keys
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let ks = resolveKeyspace(schema)

        let columns = try await fetchColumns(table: table, schema: ks)

        let partitionKeys = columns.filter(\.isPrimaryKey)
        let regularColumns = columns.filter { !$0.isPrimaryKey }

        var ddl = "CREATE TABLE \"\(escapeIdentifier(ks))\".\"\(escapeIdentifier(table))\" (\n"

        let allCols = partitionKeys + regularColumns
        let colDefs = allCols.map { col in
            "    \"\(escapeIdentifier(col.name))\" \(col.dataType)"
        }

        var allDefs = colDefs

        if !partitionKeys.isEmpty {
            let pkCols = partitionKeys.map { "\"\(escapeIdentifier($0.name))\"" }
                .joined(separator: ", ")
            allDefs.append("    PRIMARY KEY (\(pkCols))")
        }

        ddl += allDefs.joined(separator: ",\n")
        ddl += "\n);"

        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let ks = resolveKeyspace(schema)
        let query = """
            SELECT base_table_name, where_clause, include_all_columns
            FROM system_schema.views
            WHERE keyspace_name = '\(escapeSingleQuote(ks))'
              AND view_name = '\(escapeSingleQuote(view))'
        """
        let result = try await execute(query: query)

        guard let row = result.rows.first else {
            throw CassandraPluginError.queryFailed("View '\(view)' not found")
        }

        let baseTable = row[safe: 0]?.asText ?? "unknown"
        let whereClause = row[safe: 1]?.asText ?? ""

        let columns = try await fetchColumns(table: view, schema: ks)
        let colNames = columns.map { "\"\(escapeIdentifier($0.name))\"" }.joined(separator: ", ")
        let pkColumns = columns.filter(\.isPrimaryKey)
        let pkStr = pkColumns.map { "\"\(escapeIdentifier($0.name))\"" }.joined(separator: ", ")

        var ddl = "CREATE MATERIALIZED VIEW \"\(escapeIdentifier(ks))\".\"\(escapeIdentifier(view))\" AS\n"
        ddl += "    SELECT \(colNames)\n"
        ddl += "    FROM \"\(escapeIdentifier(ks))\".\"\(escapeIdentifier(baseTable))\"\n"
        if !whereClause.isEmpty {
            ddl += "    WHERE \(whereClause)\n"
        }
        ddl += "    PRIMARY KEY (\(pkStr));"

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let ks = resolveKeyspace(schema)
        // Cassandra doesn't have a cheap row count — use a bounded count
        let countQuery = "SELECT COUNT(*) FROM \"\(escapeIdentifier(ks))\".\"\(escapeIdentifier(table))\" LIMIT 100001"
        let countResult = try? await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult?.rows.first, let countStr = row.first?.asText else { return nil }
            return Int64(countStr)
        }()

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            engine: "Cassandra"
        )
    }

    // MARK: - Database (Keyspace) Operations

    func fetchDatabases() async throws -> [String] {
        let query = "SELECT keyspace_name FROM system_schema.keyspaces"
        let result = try await execute(query: query)
        let systemKeyspaces: Set<String> = [
            "system", "system_schema", "system_auth",
            "system_distributed", "system_traces", "system_virtual_schema",
        ]
        return result.rows.compactMap { $0[safe: 0]?.asText }
            .filter { !systemKeyspaces.contains($0) }
            .sorted()
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let databases = try await fetchDatabases()
        return databases.map { PluginDatabaseMetadata(name: $0) }
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let safeKs = escapeIdentifier(request.name)
        let query = """
            CREATE KEYSPACE "\(safeKs)"
            WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3}
        """
        _ = try await execute(query: query)
    }

    func dropDatabase(name: String) async throws {
        let safeKs = escapeIdentifier(name)
        _ = try await execute(query: "DROP KEYSPACE \"\(safeKs)\"")
    }

    func switchDatabase(to database: String) async throws {
        try await connectionActor.switchKeyspace(database)
        stateLock.lock()
        _currentKeyspace = database
        stateLock.unlock()
    }

    // MARK: - Schemas (Cassandra uses keyspaces, not schemas)

    func fetchSchemas() async throws -> [String] {
        []
    }

    func switchSchema(to schema: String) async throws {
        // Cassandra uses keyspaces instead of schemas
        try await switchDatabase(to: schema)
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) ADD \(quoteIdentifier(column.name)) \(column.dataType)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP \(quoteIdentifier(columnName))"
    }

    private func qualifiedTableName(_ table: String) -> String {
        let ks = resolveKeyspace(nil)
        return "\(quoteIdentifier(ks)).\(quoteIdentifier(table))"
    }

    // MARK: - Private Helpers

    private func resolveKeyspace(_ schema: String?) -> String {
        if let schema, !schema.isEmpty { return schema }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentKeyspace ?? "system"
    }

    private func escapeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func escapeSingleQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func stripTrailingSemicolon(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(";") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func columnKindOrder(_ kind: String) -> Int {
        switch kind {
        case "partition_key": return 0
        case "clustering": return 1
        case "static": return 2
        default: return 3
        }
    }
}
