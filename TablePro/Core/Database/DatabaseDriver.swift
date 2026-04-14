//
//  DatabaseDriver.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import OSLog
import TableProPluginKit

/// Protocol defining database driver operations
protocol DatabaseDriver: AnyObject {
    // MARK: - Properties

    /// The connection configuration
    var connection: DatabaseConnection { get }

    /// Current connection status
    var status: ConnectionStatus { get }

    /// Server version string (e.g., "8.0.35" for MySQL)
    /// Optional - not all drivers may implement this
    var serverVersion: String? { get }

    // MARK: - Connection Management

    /// Connect to the database
    func connect() async throws

    /// Disconnect from the database
    func disconnect()

    /// Test the connection (connect and immediately disconnect)
    func testConnection() async throws -> Bool

    // MARK: - Configuration

    /// Apply query execution timeout (seconds, 0 = no limit)
    func applyQueryTimeout(_ seconds: Int) async throws

    // MARK: - Query Execution

    /// Execute a SQL query and return results
    func execute(query: String) async throws -> QueryResult

    /// Execute a prepared statement with parameters (prevents SQL injection)
    /// - Parameters:
    ///   - query: SQL query with placeholders (? for MySQL/SQLite, $1/$2 for PostgreSQL)
    ///   - parameters: Array of parameter values to bind
    /// - Returns: Query result
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult

    /// Fetch total row count for a query (wraps with COUNT(*))
    func fetchRowCount(query: String) async throws -> Int

    /// Fetch rows with LIMIT/OFFSET pagination
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult

    // MARK: - Schema Operations

    /// Fetch all tables in the database
    func fetchTables() async throws -> [TableInfo]

    /// Fetch columns for a specific table
    func fetchColumns(table: String) async throws -> [ColumnInfo]

    /// Fetch columns for a table in a specific schema (for cross-schema FK lookups)
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo]

    /// Fetch columns for ALL tables in a single batch query (avoids N+1).
    /// Returns a dictionary keyed by table name.
    /// Default implementation falls back to per-table fetchColumns.
    func fetchAllColumns() async throws -> [String: [ColumnInfo]]

    /// Fetch indexes for a specific table
    func fetchIndexes(table: String) async throws -> [IndexInfo]

    /// Fetch foreign keys for a specific table
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo]

    /// Fetch foreign keys for all tables in the current database/schema in bulk.
    /// Default implementation falls back to per-table fetchForeignKeys.
    func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]]

    /// Fetch foreign keys for a specific set of tables.
    /// Default implementation calls fetchAllForeignKeys and filters, or falls back to per-table.
    func fetchForeignKeys(forTables tableNames: [String]) async throws -> [String: [ForeignKeyInfo]]

    /// Fetch an approximate row count using fast database-specific metadata.
    /// Returns nil if not available (e.g., SQLite). Used for instant pagination display.
    func fetchApproximateRowCount(table: String) async throws -> Int?

    /// Fetch the DDL (CREATE TABLE statement) for a specific table
    func fetchTableDDL(table: String) async throws -> String

    /// Fetch dependent type definitions (e.g., PostgreSQL enum types) for a table.
    /// Returns array of (typeName, labels) pairs. Default returns empty.
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])]

    /// Fetch dependent sequence definitions (e.g., PostgreSQL sequences used by table columns).
    /// Returns array of (sequenceName, CREATE SEQUENCE DDL) pairs. Default returns empty.
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)]

    /// Fetch the view definition (SELECT statement) for a specific view
    func fetchViewDefinition(view: String) async throws -> String

    /// Fetch table metadata (size, comment, engine, etc.)
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String]

    /// Fetch list of schemas in the current database (PostgreSQL only)
    func fetchSchemas() async throws -> [String]

    /// Fetch metadata for a specific database (table count, size, etc.)
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata

    /// Fetch metadata for all databases in a single batch (table count, size, etc.)
    /// Default implementation falls back to per-database calls.
    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata]

    /// Create a new database
    func createDatabase(name: String, charset: String, collation: String?) async throws

    // MARK: - Maintenance

    /// Returns the list of supported maintenance operations (e.g. "VACUUM", "ANALYZE").
    /// Returns nil if maintenance is not supported.
    func supportedMaintenanceOperations() -> [String]?

    /// Generates SQL statements for a maintenance operation.
    func maintenanceStatements(operation: String, table: String?, options: [String: String]) -> [String]?

    // MARK: - Query Cancellation

    /// Cancel the currently running query, if any.
    /// Default implementation is a no-op for drivers that don't support cancellation.
    func cancelQuery() throws

    // MARK: - Transaction Management

    /// Whether this driver supports transactions (e.g., Cloudflare D1, ClickHouse do not)
    var supportsTransactions: Bool { get }

    /// Begin a transaction
    func beginTransaction() async throws

    /// Commit the current transaction
    func commitTransaction() async throws

    /// Rollback the current transaction
    func rollbackTransaction() async throws

    /// Access to the underlying plugin driver for query building dispatch
    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? { get }

    /// Quote an identifier (table or column name) using the driver's quoting style
    func quoteIdentifier(_ name: String) -> String

    /// Escape a string value for safe use in SQL string literals
    func escapeStringLiteral(_ value: String) -> String

    func createViewTemplate() -> String?
    func editViewFallbackTemplate(viewName: String) -> String?
    func castColumnToText(_ column: String) -> String

    func foreignKeyDisableStatements() -> [String]?
    func foreignKeyEnableStatements() -> [String]?

    // Definition SQL for clipboard copy
    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String?
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String?
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String?
}

// MARK: - Schema Switching

/// Protocol for drivers that support schema/search_path switching.
/// Eliminates repeated as? casting chains in DatabaseManager.
protocol SchemaSwitchable: DatabaseDriver {
    var currentSchema: String? { get }
    var escapedSchema: String? { get }
    func switchSchema(to schema: String) async throws
}

/// Default implementation for common operations
extension DatabaseDriver {
    /// Default implementation returns nil
    /// Override in drivers that support version querying
    var serverVersion: String? { nil }

    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? { nil }

    func quoteIdentifier(_ name: String) -> String {
        let q = "\""
        let escaped = name.replacingOccurrences(of: q, with: q + q)
        return "\(q)\(escaped)\(q)"
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    func createViewTemplate() -> String? { nil }
    func editViewFallbackTemplate(viewName: String) -> String? { nil }
    func castColumnToText(_ column: String) -> String { column }

    func foreignKeyDisableStatements() -> [String]? { nil }
    func foreignKeyEnableStatements() -> [String]? { nil }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? { nil }
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? { nil }
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? { nil }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        try await fetchColumns(table: table)
    }

    func testConnection() async throws -> Bool {
        try await connect()
        disconnect()
        return true
    }

    /// Default fetchAllDatabaseMetadata: falls back to per-database calls (N+1).
    /// Drivers should override with a single bulk query where possible.
    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        let dbNames = try await fetchDatabases()
        var results: [DatabaseMetadata] = []
        for dbName in dbNames {
            do {
                let metadata = try await fetchDatabaseMetadata(dbName)
                results.append(metadata)
            } catch {
                results.append(DatabaseMetadata.minimal(name: dbName))
            }
        }
        return results
    }

    func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]] {
        let allTables = try await fetchTables()
        var result: [String: [ForeignKeyInfo]] = [:]
        for table in allTables {
            do {
                let fks = try await fetchForeignKeys(table: table.name)
                if !fks.isEmpty { result[table.name] = fks }
            } catch {
                Logger(subsystem: "com.TablePro", category: "DatabaseDriver")
                    .debug("Failed to fetch foreign keys for \(table.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    func fetchForeignKeys(forTables tableNames: [String]) async throws -> [String: [ForeignKeyInfo]] {
        // For small subsets, per-table fetch avoids scanning the entire schema
        if tableNames.count <= 5 {
            var result: [String: [ForeignKeyInfo]] = [:]
            for tableName in tableNames {
                do {
                    let fks = try await fetchForeignKeys(table: tableName)
                    if !fks.isEmpty { result[tableName] = fks }
                } catch {
                    Logger(subsystem: "com.TablePro", category: "DatabaseDriver")
                        .debug("Failed to fetch foreign keys for \(tableName): \(error.localizedDescription)")
                }
            }
            return result
        }
        let all = try await fetchAllForeignKeys()
        let nameSet = Set(tableNames)
        return all.filter { nameSet.contains($0.key) }
    }

    /// Default fetchAllColumns: falls back to per-table fetchColumns (N+1).
    /// Drivers should override with a single bulk query where possible.
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let allTables = try await fetchTables()
        var result: [String: [ColumnInfo]] = [:]
        for table in allTables {
            do {
                let columns = try await fetchColumns(table: table.name)
                result[table.name] = columns
            } catch {
                Logger(subsystem: "com.TablePro", category: "DatabaseDriver")
                    .debug("Skipping columns for table '\(table.name)': \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Default: no dependent types (MySQL/SQLite don't have standalone enum types)
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] {
        []
    }

    /// Default: no dependent sequences (MySQL/SQLite don't use standalone sequences)
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] {
        []
    }

    func fetchAllDependentTypes(forTables tables: [String]) async throws -> [String: [(name: String, labels: [String])]] {
        var result: [String: [(name: String, labels: [String])]] = [:]
        for table in tables {
            let types = try await fetchDependentTypes(forTable: table)
            if !types.isEmpty { result[table] = types }
        }
        return result
    }

    func fetchAllDependentSequences(forTables tables: [String]) async throws -> [String: [(name: String, ddl: String)]] {
        var result: [String: [(name: String, ddl: String)]] = [:]
        for table in tables {
            let seqs = try await fetchDependentSequences(forTable: table)
            if !seqs.isEmpty { result[table] = seqs }
        }
        return result
    }

    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }

    func supportedMaintenanceOperations() -> [String]? { nil }
    func maintenanceStatements(operation: String, table: String?, options: [String: String]) -> [String]? { nil }

    /// Default: no schema support (MySQL/SQLite don't use schemas in the same way)
    func fetchSchemas() async throws -> [String] { [] }

    var supportsTransactions: Bool { true }

    /// Default no-op implementation for drivers that don't support query cancellation
    func cancelQuery() throws {
        // No-op by default
    }

    /// Default timeout implementation — delegates to each plugin's PluginDatabaseDriver.
    /// The PluginDriverAdapter bridges this call to the plugin.
    func applyQueryTimeout(_ seconds: Int) async throws {
        // No-op: each plugin's PluginDatabaseDriver implements its own timeout command.
        // The PluginDriverAdapter bridges this call to the plugin.
    }
}

/// Factory for creating database drivers via plugin lookup
@MainActor
enum DatabaseDriverFactory {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseDriverFactory")

    /// Async variant that awaits background plugin loading instead of blocking the main thread.
    /// Preferred for all call sites that are already in an async context.
    static func createDriver(
        for connection: DatabaseConnection,
        passwordOverride: String? = nil,
        awaitPlugins: Bool
    ) async throws -> DatabaseDriver {
        let pluginId = connection.type.pluginTypeId
        if PluginManager.shared.driverPlugins[pluginId] == nil,
           !PluginManager.shared.hasFinishedInitialLoad {
            logger.info("Plugin '\(pluginId)' not loaded yet — waiting for background load")
            await PluginManager.shared.waitForInitialLoad()
        }
        return try createDriverFromPlugin(for: connection, passwordOverride: passwordOverride)
    }

    /// Sync variant — falls back to synchronous plugin loading if needed.
    /// Only use when an async context is not available.
    static func createDriver(
        for connection: DatabaseConnection,
        passwordOverride: String? = nil
    ) throws -> DatabaseDriver {
        let pluginId = connection.type.pluginTypeId
        if PluginManager.shared.driverPlugins[pluginId] == nil,
           !PluginManager.shared.hasFinishedInitialLoad {
            logger.warning("Plugin '\(pluginId)' not loaded yet — performing synchronous load")
            PluginManager.shared.loadPendingPlugins()
        }
        return try createDriverFromPlugin(for: connection, passwordOverride: passwordOverride)
    }

    private static func createDriverFromPlugin(
        for connection: DatabaseConnection,
        passwordOverride: String? = nil
    ) throws -> DatabaseDriver {
        let pluginId = connection.type.pluginTypeId
        guard let plugin = PluginManager.shared.driverPlugins[pluginId] else {
            if connection.type.isDownloadablePlugin {
                throw PluginError.pluginNotInstalled(connection.type.rawValue)
            }
            throw DatabaseError.connectionFailed(
                "\(pluginId) driver plugin not loaded. The plugin may be disabled or missing from the PlugIns directory."
            )
        }
        let config = DriverConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: resolvePassword(for: connection, override: passwordOverride),
            database: connection.database,
            additionalFields: buildAdditionalFields(for: connection, plugin: plugin)
        )
        let pluginDriver = plugin.createDriver(config: config)
        return PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
    }

    private static func resolvePassword(
        for connection: DatabaseConnection,
        override: String? = nil
    ) -> String {
        if let override { return override }
        if connection.usePgpass {
            let pgpassHost = connection.additionalFields["pgpassOriginalHost"] ?? connection.host
            let pgpassPort = connection.additionalFields["pgpassOriginalPort"]
                .flatMap(Int.init) ?? connection.port
            return PgpassReader.resolve(
                host: pgpassHost.isEmpty ? "localhost" : pgpassHost,
                port: pgpassPort,
                database: connection.database,
                username: connection.username
            ) ?? ""
        }
        return ConnectionStorage.shared.loadPassword(for: connection.id) ?? ""
    }

    private static func buildAdditionalFields(
        for connection: DatabaseConnection,
        plugin: any DriverPlugin
    ) -> [String: String] {
        var fields: [String: String] = [:]

        let ssl = connection.sslConfig
        fields["sslMode"] = ssl.mode.rawValue
        fields["sslCaCertPath"] = ssl.caCertificatePath
        fields["sslClientCertPath"] = ssl.clientCertificatePath
        fields["sslClientKeyPath"] = ssl.clientKeyPath

        if let variant = type(of: plugin).driverVariant(for: connection.type.rawValue) {
            fields["driverVariant"] = variant
        }

        for (key, value) in connection.additionalFields {
            fields[key] = value
        }

        let secureFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
            .filter(\.isSecure)
        for field in secureFields {
            if fields[field.id] == nil || fields[field.id]?.isEmpty == true {
                if let secureValue = ConnectionStorage.shared.loadPluginSecureField(
                    fieldId: field.id, for: connection.id
                ) {
                    fields[field.id] = secureValue
                }
            }
        }

        switch connection.type {
        case .mongodb:
            fields["sslCACertPath"] = ssl.caCertificatePath
            fields["mongoReadPreference"] = connection.mongoReadPreference ?? ""
            fields["mongoWriteConcern"] = connection.mongoWriteConcern ?? ""
        case .redis:
            fields["redisDatabase"] = String(connection.redisDatabase ?? 0)
        case .mssql:
            fields["mssqlSchema"] = connection.mssqlSchema ?? "dbo"
        case .oracle:
            fields["oracleServiceName"] = connection.oracleServiceName ?? ""
        default:
            break
        }

        return fields
    }
}
