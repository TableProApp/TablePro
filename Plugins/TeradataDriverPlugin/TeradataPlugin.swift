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

extension TeradataResultSet {
    func toPluginResult(executionTime: TimeInterval) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns.map { $0.name },
            columnTypeNames: columns.map { TeradataColumnType.wireTypeName($0.typeCode) },
            rows: rows.map { row in row.map { $0.asPluginCell } },
            rowsAffected: activityCount,
            executionTime: executionTime,
            isTruncated: false
        )
    }
}

final class TeradataPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Teradata Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Teradata Vantage support via a native Swift TD2 driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Teradata"
    static let databaseDisplayName = "Teradata"
    static let iconName = "teradata-icon"
    static let defaultPort = 1_025
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
    static let requiresReconnectForDatabaseSwitch = false
    static let databaseGroupingStrategy: GroupingStrategy = .byDatabase
    static let containerEntityName = "Database"
    static let supportsForeignKeys = true
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
        autoLimitStyle: .top
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
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [.cancelQuery, .transactions, .alterTableDDL]
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
            tls: TeradataSSLMapping.tlsOptions(for: config.ssl))
        let connection = TeradataAsyncConnection(config: coreConfig)
        try await connection.connect()
        self.connection = connection

        if let result = try? await connection.execute("SELECT InfoData FROM DBC.DBCInfoV WHERE InfoKey = 'VERSION'"),
           case .text(let version)? = result.rows.first?.first {
            _serverVersion = version
        }
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        guard let connection else { throw TeradataWireError.connectionFailed("not connected") }
        let start = Date()
        let result = try await connection.execute(query)
        return result.toPluginResult(executionTime: Date().timeIntervalSince(start))
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else { return try await execute(query: query) }
        var rendered = ""
        var index = 0
        for character in query {
            if character == "?", index < parameters.count {
                rendered += sqlLiteral(parameters[index])
                index += 1
            } else {
                rendered.append(character)
            }
        }
        return try await execute(query: rendered)
    }

    func cancelQuery() throws {
        connection?.cancel()
    }

    func beginTransaction() async throws { _ = try await execute(query: "BEGIN TRANSACTION") }
    func commitTransaction() async throws { _ = try await execute(query: "END TRANSACTION") }
    func rollbackTransaction() async throws { _ = try await execute(query: "ROLLBACK") }
}
