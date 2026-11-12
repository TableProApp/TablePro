import Foundation
import os
import TableProPluginKit
import TableProTeradataCore

extension TeradataValue {
    var asPluginCell: PluginCellValue {
        switch self {
        case .null: return .null
        case .integer(let value): return .text(String(value))
        case .double(let value): return .text(String(value))
        case .text(let value): return .text(value)
        case .bytes(let value): return .bytes(Data(value))
        }
    }
}

extension TeradataColumn {
    var pluginTypeName: String { TeradataColumnType.wireTypeName(typeCode) }
}

extension TeradataResultSet {
    func toPluginResult(executionTime: TimeInterval, isTruncated: Bool = false) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns.map { $0.name },
            columnTypeNames: columns.map { $0.pluginTypeName },
            rows: rows.map { row in row.map { $0.asPluginCell } },
            rowsAffected: activityCount,
            executionTime: executionTime,
            isTruncated: isTruncated
        )
    }
}

final class TeradataPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Teradata Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Teradata Vantage support via a native Swift TD2 driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Teradata"

    static let supportsRenameTable = true
    static let databaseDisplayName = "Teradata"
    static let iconName = "teradata-icon"
    static let defaultPort = 1_025
    // TLS goes to the HTTPS port, which a tunnel does not forward; Preferred falls back to plaintext.
    static let sslModesThroughTunnel: [SSLMode] = [.disabled, .preferred]
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "teradataLogMech", label: "Logon Mechanism", placeholder: "TD2", defaultValue: "TD2"),
        ConnectionField(
            id: "teradataTMode", label: "Transaction Mode", placeholder: "DEFAULT", defaultValue: "DEFAULT"),
    ]

    static let brandColorHex = "#F37440"
    static let queryLanguageName = "SQL"
    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = false
    static let supportsHealthMonitor = false
    static let requiresReconnectForDatabaseSwitch = false
    static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    static let containerEntityName = "Database"
    static let supportsForeignKeys = true
    // Teradata has no session setting that suspends referential checks, so the option would add no statement.
    static let supportsForeignKeyDisable = false
    static let supportsRoutines = true
    static let supportsDatabaseTriggerBrowse = true
    static let supportsSchemaEditing = true
    static let supportsSSL = true
    static let systemDatabaseNames: [String] = [
        "DBC", "Sys", "SysAdmin", "SystemFe", "SYSLIB", "SYSUDTLIB", "SYSSPATIAL",
        "TD_SYSFNLIB", "TD_SERVER_DB", "TDStats", "TDMaps", "TDQCD", "SQLJ",
        "Sys_Calendar", "dbcmngr", "tdwm", "viewpoint", "console", "PUBLIC", "All", "Default",
    ]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["BYTEINT", "SMALLINT", "INTEGER", "BIGINT"],
        "Float": ["FLOAT", "REAL", "DOUBLE PRECISION", "DECIMAL", "NUMERIC", "NUMBER"],
        "String": ["CHAR", "VARCHAR", "LONG VARCHAR", "CLOB"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"],
        "Binary": ["BYTE", "VARBYTE", "BLOB"],
        "Interval": ["INTERVAL YEAR", "INTERVAL MONTH", "INTERVAL DAY", "INTERVAL HOUR", "INTERVAL MINUTE", "INTERVAL SECOND"],
        "Other": ["JSON", "XML", "PERIOD(DATE)", "PERIOD(TIMESTAMP)", "UDT"],
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "SAMPLE",
            "ORDER", "BY", "GROUP", "HAVING", "TOP", "QUALIFY", "WITH", "RECURSIVE",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "USER", "MACRO", "PROCEDURE",
            "PRIMARY", "KEY", "UNIQUE", "INDEX", "PARTITION", "BY", "HASH", "RANGE_N", "CASE_N",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT", "MINUS",
            "OVER", "ROW_NUMBER", "RANK", "DENSE_RANK", "HELP", "SHOW", "EXPLAIN", "COLLECT", "STATISTICS",
            "VOLATILE", "MULTISET", "SET", "GLOBAL", "TEMPORARY", "AS", "LOCKING", "FOR", "ACCESS",
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "CAST", "TRIM", "SUBSTRING", "SUBSTR",
            "CHARACTER_LENGTH", "CHAR_LENGTH", "COALESCE", "NULLIFZERO", "ZEROIFNULL",
            "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "EXTRACT", "ADD_MONTHS",
            "UPPER", "LOWER", "OREPLACE", "OTRANSLATE", "INDEX", "POSITION", "SOUNDEX",
        ],
        dataTypes: [
            "BYTEINT", "SMALLINT", "INTEGER", "BIGINT", "DECIMAL", "NUMERIC", "NUMBER",
            "FLOAT", "REAL", "DOUBLE PRECISION",
            "CHAR", "VARCHAR", "LONG VARCHAR", "CLOB",
            "BYTE", "VARBYTE", "BLOB",
            "DATE", "TIME", "TIMESTAMP", "INTERVAL", "PERIOD",
            "JSON", "XML", "ST_GEOMETRY",
        ],
        autoLimitStyle: .top,
        caseSensitivityStyle: .unsupported,
        textCastTypeName: nil,
        functionNamesAreCaseInsensitive: true,
        typeNamesAreCaseInsensitive: true
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeradataPlugin")

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        TeradataPluginDriver(config: config)
    }
}

final class TeradataPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let config: DriverConnectionConfig
    var connection: TeradataAsyncConnection?
    var currentDatabaseName: String?
    private var _serverVersion: String?

    static let logger = Logger(subsystem: "com.TablePro", category: "TeradataPluginDriver")

    var serverVersion: String? { _serverVersion }
    var hasLostConnection: Bool { connection?.hasLostConnection ?? false }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [
            .cancelQuery, .transactions, .alterTableDDL, .dataCompare, .cellExpressions, .uuidCellText, .rowWrites,
            .columnDefaultMarks,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.currentDatabaseName = config.database.isEmpty ? nil : config.database
    }

    private var logMech: TeradataLogMech {
        TeradataLogMech(rawValue: config.additionalFields["teradataLogMech"] ?? "TD2") ?? .td2
    }

    private var transactionMode: TeradataTransactionMode {
        TeradataTransactionMode(rawValue: config.additionalFields["teradataTMode"] ?? "DEFAULT") ?? .default
    }

    func connect() async throws {
        guard let port = UInt16(exactly: config.port) else {
            throw TeradataWireError.connectionFailed("port \(config.port) is out of range 0...65535")
        }
        let coreConfig = TeradataConnectionConfig(
            host: config.host,
            port: port,
            username: config.username,
            password: config.password,
            database: config.database.isEmpty ? nil : config.database,
            logMech: logMech,
            transactionMode: transactionMode,
            tls: try TeradataSSLMapping.tlsOptions(
                for: config.ssl,
                tunneled: config.additionalFields["preTunnelHost"]?.isEmpty == false
            ),
            connectTimeoutMilliseconds: TeradataConnectTimeout(
                additionalFields: config.additionalFields
            ).milliseconds)
        let connection = TeradataAsyncConnection(config: coreConfig)
        do {
            try await connection.connect()
            do {
                let result = try await connection.execute(
                    "SELECT InfoData FROM DBC.DBCInfoV WHERE InfoKey = 'VERSION'"
                )
                if case .text(let version)? = result.rows.first?.first {
                    _serverVersion = version
                }
            } catch where TeradataVersionProbe.mayIgnore(error) {
                Self.logger.debug("DBCInfoV VERSION is unavailable to this account")
            }
            try await connection.finishConnecting()
            try Task.checkCancellation()
        } catch {
            connection.disconnect()
            throw error
        }
        logSessionMode(connection)
        self.connection = connection
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await execute(query, rowCap: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await execute(bound(query, parameters ?? []), rowCap: rowCap)
    }

    // Not the stream: a Stop cancels the reading task, which ends a stream before a rollback error can cross it.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await execute(query, rowCap: rowCap)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(bound(query, parameters), rowCap: nil)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let connection = self.connection
        return PluginRowStream.make { continuation, abort in
            let task = Task {
                guard let connection else {
                    continuation.finish(throwing: TeradataWireError.connectionFailed("not connected"))
                    return
                }
                do {
                    // Each reply's rows go out as it arrives, before the next one is asked for.
                    try await connection.stream(
                        query,
                        onColumns: { columns in
                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns.map { $0.name },
                                columnTypeNames: columns.map { $0.pluginTypeName }
                            )))
                        },
                        onRows: { rows in
                            guard !abort.isAborted else { return false }
                            continuation.yield(.rows(rows.map { row in row.map { $0.asPluginCell } }))
                            return true
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort { task.cancel() }
        }
    }

    // Teradata reads quotes, names and comments the ANSI way, which is no lexical feature.
    private func bound(_ query: String, _ parameters: [PluginCellValue]) throws -> String {
        guard !parameters.isEmpty else { return query }
        return try PluginParameterBinder.bind(
            query,
            literals: parameters.map(TeradataRowEditSQL.literal),
            style: .questionMark,
            features: []
        )
    }

    private func execute(_ query: String, rowCap: Int?) async throws -> PluginQueryResult {
        guard let connection else { throw TeradataWireError.connectionFailed("not connected") }
        let start = Date()
        let capped = try await connection.execute(query, rowCap: rowCap)
        return capped.resultSet.toPluginResult(
            executionTime: Date().timeIntervalSince(start), isTruncated: capped.isTruncated)
    }

    func cancelQuery() throws {
        connection?.cancel()
    }

    func beginTransaction() async throws {
        try await liveConnection().beginTransaction()
    }

    func commitTransaction() async throws {
        try await liveConnection().commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await liveConnection().rollbackTransaction()
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        guard let connection, !connection.hasLostConnection else { return .unknown }
        switch connection.transactionState {
        case .idle: return .idle
        case .open: return .inTransaction
        case .unknown: return .unknown
        }
    }

    func liveConnection() throws -> TeradataAsyncConnection {
        guard let connection else { throw TeradataWireError.connectionFailed("not connected") }
        return connection
    }

    private func logSessionMode(_ connection: TeradataAsyncConnection) {
        let mode = connection.sessionTransactionMode.rawValue
        switch connection.sessionModeSource {
        case .configured:
            Self.logger.debug("Transaction mode \(mode, privacy: .public) as configured")
        case .helpSession:
            Self.logger.info("Transaction mode \(mode, privacy: .public) read from HELP SESSION")
        case .sessionInfoView:
            Self.logger.info("Transaction mode \(mode, privacy: .public) read from DBC.SessionInfoV")
        case .unresolved:
            Self.logger.warning("Neither HELP SESSION nor DBC.SessionInfoV gave the transaction mode; using Teradata semantics")
        }
    }
}
