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
    static let defaultPort = 9042
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "sslCaCertPath",
            label: "CA Certificate",
            placeholder: "/path/to/ca-cert.pem",
            section: .advanced
        ),
    ]
    static let additionalDatabaseTypeIds: [String] = ["ScyllaDB"]

    // MARK: - UI/Capability Metadata

    static let urlSchemes: [String] = ["cassandra", "cql", "scylladb", "scylla"]
    static let requiresAuthentication = false
    static let supportsForeignKeys = false
    static let brandColorHex = "#26A0D8"
    static let queryLanguageName = "CQL"
    static let supportsDatabaseSwitching = true
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

// MARK: - Connection Actor

private actor CassandraConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro.CassandraDriver", category: "Connection")

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var cluster: OpaquePointer? // CassCluster*
    private var session: OpaquePointer? // CassSession*
    private var currentKeyspace: String?

    var isConnected: Bool { session != nil }

    var keyspace: String? { currentKeyspace }

    func connect(
        host: String,
        port: Int,
        username: String?,
        password: String?,
        keyspace: String?,
        sslMode: String,
        sslCaCertPath: String?
    ) throws {
        cluster = cass_cluster_new()
        guard let cluster else {
            throw CassandraPluginError.connectionFailed("Failed to create cluster object")
        }

        cass_cluster_set_contact_points(cluster, host)
        cass_cluster_set_port(cluster, Int32(port))

        if let username, !username.isEmpty, let password {
            cass_cluster_set_credentials(cluster, username, password)
        }

        // SSL/TLS
        if sslMode != "Disabled" {
            guard let ssl = cass_ssl_new() else {
                cass_cluster_free(cluster)
                self.cluster = nil
                throw CassandraPluginError.connectionFailed("Failed to create SSL context")
            }

            if sslMode == "Verify CA" || sslMode == "Verify Identity" {
                if sslMode == "Verify Identity" {
                    let flags = Int32(CASS_SSL_VERIFY_PEER_CERT.rawValue | CASS_SSL_VERIFY_PEER_IDENTITY.rawValue)
                    cass_ssl_set_verify_flags(ssl, flags)
                } else {
                    cass_ssl_set_verify_flags(ssl, Int32(CASS_SSL_VERIFY_PEER_CERT.rawValue))
                }

                if let caCertPath = sslCaCertPath, !caCertPath.isEmpty,
                   let certData = FileManager.default.contents(atPath: caCertPath),
                   let certString = String(data: certData, encoding: .utf8) {
                    let rc = cass_ssl_add_trusted_cert(ssl, certString)
                    if rc != CASS_OK {
                        Self.logger.warning("Failed to add CA certificate, proceeding without verification")
                        cass_ssl_set_verify_flags(ssl, Int32(CASS_SSL_VERIFY_NONE.rawValue))
                    }
                }
            } else {
                // "Preferred" / "Required" — encrypt but skip cert verification
                cass_ssl_set_verify_flags(ssl, Int32(CASS_SSL_VERIFY_NONE.rawValue))
            }

            cass_cluster_set_ssl(cluster, ssl)
            cass_ssl_free(ssl)
        }

        // Connection timeout (10 seconds)
        cass_cluster_set_connect_timeout(cluster, 10_000)
        cass_cluster_set_request_timeout(cluster, 30_000)

        let newSession = cass_session_new()
        guard let newSession else {
            cass_cluster_free(cluster)
            self.cluster = nil
            throw CassandraPluginError.connectionFailed("Failed to create session")
        }

        let connectFuture: OpaquePointer?
        if let keyspace, !keyspace.isEmpty {
            connectFuture = cass_session_connect_keyspace(newSession, cluster, keyspace)
            currentKeyspace = keyspace
        } else {
            connectFuture = cass_session_connect(newSession, cluster)
            currentKeyspace = nil
        }

        guard let future = connectFuture else {
            cass_session_free(newSession)
            cass_cluster_free(cluster)
            self.cluster = nil
            throw CassandraPluginError.connectionFailed("Failed to initiate connection")
        }

        cass_future_wait(future)
        let rc = cass_future_error_code(future)

        if rc != CASS_OK {
            let errorMessage = extractFutureError(future)
            cass_future_free(future)
            cass_session_free(newSession)
            cass_cluster_free(cluster)
            self.cluster = nil
            throw CassandraPluginError.connectionFailed(errorMessage)
        }

        cass_future_free(future)
        session = newSession

        Self.logger.info("Connected to Cassandra at \(host):\(port)")
    }

    func close() {
        if let session {
            let closeFuture = cass_session_close(session)
            if let closeFuture {
                cass_future_wait(closeFuture)
                cass_future_free(closeFuture)
            }
            cass_session_free(session)
            self.session = nil
        }

        if let cluster {
            cass_cluster_free(cluster)
            self.cluster = nil
        }

        currentKeyspace = nil
        Self.logger.info("Disconnected from Cassandra")
    }

    func executeQuery(_ cql: String) throws -> CassandraRawResult {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let startTime = Date()
        let statement = cass_statement_new(cql, 0)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to create statement")
        }

        defer { cass_statement_free(statement) }

        let future = cass_session_execute(session, statement)
        guard let future else {
            throw CassandraPluginError.queryFailed("Failed to execute query")
        }

        defer { cass_future_free(future) }

        cass_future_wait(future)
        let rc = cass_future_error_code(future)

        if rc != CASS_OK {
            throw CassandraPluginError.queryFailed(extractFutureError(future))
        }

        let result = cass_future_get_result(future)
        defer {
            if let result { cass_result_free(result) }
        }

        guard let result else {
            let executionTime = Date().timeIntervalSince(startTime)
            return CassandraRawResult(
                columns: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: 0,
                executionTime: executionTime
            )
        }

        return extractResult(from: result, startTime: startTime)
    }

    func executePrepared(_ cql: String, parameters: [String?]) throws -> CassandraRawResult {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let startTime = Date()

        // Prepare
        let prepareFuture = cass_session_prepare(session, cql)
        guard let prepareFuture else {
            throw CassandraPluginError.queryFailed("Failed to prepare statement")
        }
        defer { cass_future_free(prepareFuture) }

        cass_future_wait(prepareFuture)
        let prepRc = cass_future_error_code(prepareFuture)
        if prepRc != CASS_OK {
            throw CassandraPluginError.queryFailed(extractFutureError(prepareFuture))
        }

        let prepared = cass_future_get_prepared(prepareFuture)
        guard let prepared else {
            throw CassandraPluginError.queryFailed("Failed to get prepared statement")
        }
        defer { cass_prepared_free(prepared) }

        // Bind parameters
        let statement = cass_prepared_bind(prepared)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to bind prepared statement")
        }
        defer { cass_statement_free(statement) }

        for (index, param) in parameters.enumerated() {
            if let value = param {
                cass_statement_bind_string(statement, index, value)
            } else {
                cass_statement_bind_null(statement, index)
            }
        }

        // Execute
        let future = cass_session_execute(session, statement)
        guard let future else {
            throw CassandraPluginError.queryFailed("Failed to execute prepared statement")
        }
        defer { cass_future_free(future) }

        cass_future_wait(future)
        let rc = cass_future_error_code(future)

        if rc != CASS_OK {
            throw CassandraPluginError.queryFailed(extractFutureError(future))
        }

        let result = cass_future_get_result(future)
        defer {
            if let result { cass_result_free(result) }
        }

        guard let result else {
            let executionTime = Date().timeIntervalSince(startTime)
            return CassandraRawResult(
                columns: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: 0,
                executionTime: executionTime
            )
        }

        return extractResult(from: result, startTime: startTime)
    }

    func switchKeyspace(_ keyspace: String) throws {
        _ = try executeQuery("USE \"\(escapeIdentifier(keyspace))\"")
        currentKeyspace = keyspace
    }

    func serverVersion() throws -> String? {
        let result = try executeQuery("SELECT release_version FROM system.local WHERE key = 'local'")
        return result.rows.first?.first ?? nil
    }

    // MARK: - Private Helpers

    private func extractResult(
        from result: OpaquePointer,
        startTime: Date
    ) -> CassandraRawResult {
        let colCount = cass_result_column_count(result)
        let rowCount = cass_result_row_count(result)

        var columns: [String] = []
        var columnTypeNames: [String] = []

        for i in 0..<colCount {
            var namePtr: UnsafePointer<CChar>?
            var nameLength: Int = 0
            cass_result_column_name(result, i, &namePtr, &nameLength)
            if let namePtr {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("column_\(i)")
            }

            let colType = cass_result_column_type(result, i)
            columnTypeNames.append(Self.cassTypeName(colType))
        }

        var rows: [[String?]] = []
        let iterator = cass_iterator_from_result(result)
        defer {
            if let iterator { cass_iterator_free(iterator) }
        }

        guard let iterator else {
            let executionTime = Date().timeIntervalSince(startTime)
            return CassandraRawResult(
                columns: columns,
                columnTypeNames: columnTypeNames,
                rows: [],
                rowsAffected: Int(rowCount),
                executionTime: executionTime
            )
        }

        let maxRows = min(Int(rowCount), 100_000)
        var count = 0

        while cass_iterator_next(iterator) == cass_true && count < maxRows {
            let row = cass_iterator_get_row(iterator)
            guard let row else { continue }

            var rowData: [String?] = []
            for col in 0..<colCount {
                let value = cass_row_get_column(row, col)
                if let value, cass_value_is_null(value) == cass_false {
                    rowData.append(Self.extractStringValue(value))
                } else {
                    rowData.append(nil)
                }
            }
            rows.append(rowData)
            count += 1
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return CassandraRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: Int(rowCount),
            executionTime: executionTime
        )
    }

    private static func extractStringValue(_ value: OpaquePointer) -> String? {
        let valueType = cass_value_type(value)

        switch valueType {
        case CASS_VALUE_TYPE_ASCII, CASS_VALUE_TYPE_TEXT, CASS_VALUE_TYPE_VARCHAR:
            var output: UnsafePointer<CChar>?
            var outputLength: Int = 0
            let rc = cass_value_get_string(value, &output, &outputLength)
            if rc == CASS_OK, let output {
                return String(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: output),
                    length: outputLength,
                    encoding: .utf8,
                    freeWhenDone: false
                )
            }
            return nil

        case CASS_VALUE_TYPE_INT:
            var intVal: Int32 = 0
            if cass_value_get_int32(value, &intVal) == CASS_OK {
                return String(intVal)
            }
            return nil

        case CASS_VALUE_TYPE_BIGINT, CASS_VALUE_TYPE_COUNTER:
            var bigintVal: Int64 = 0
            if cass_value_get_int64(value, &bigintVal) == CASS_OK {
                return String(bigintVal)
            }
            return nil

        case CASS_VALUE_TYPE_SMALL_INT:
            var smallVal: Int16 = 0
            if cass_value_get_int16(value, &smallVal) == CASS_OK {
                return String(smallVal)
            }
            return nil

        case CASS_VALUE_TYPE_TINY_INT:
            var tinyVal: Int8 = 0
            if cass_value_get_int8(value, &tinyVal) == CASS_OK {
                return String(tinyVal)
            }
            return nil

        case CASS_VALUE_TYPE_FLOAT:
            var floatVal: Float = 0
            if cass_value_get_float(value, &floatVal) == CASS_OK {
                return String(floatVal)
            }
            return nil

        case CASS_VALUE_TYPE_DOUBLE:
            var doubleVal: Double = 0
            if cass_value_get_double(value, &doubleVal) == CASS_OK {
                return String(doubleVal)
            }
            return nil

        case CASS_VALUE_TYPE_BOOLEAN:
            var boolVal: cass_bool_t = cass_false
            if cass_value_get_bool(value, &boolVal) == CASS_OK {
                return boolVal == cass_true ? "true" : "false"
            }
            return nil

        case CASS_VALUE_TYPE_UUID, CASS_VALUE_TYPE_TIMEUUID:
            var uuid = CassUuid()
            if cass_value_get_uuid(value, &uuid) == CASS_OK {
                var buffer = [CChar](repeating: 0, count: Int(CASS_UUID_STRING_LENGTH))
                cass_uuid_string(uuid, &buffer)
                return String(cString: buffer)
            }
            return nil

        case CASS_VALUE_TYPE_TIMESTAMP:
            var timestamp: Int64 = 0
            if cass_value_get_int64(value, &timestamp) == CASS_OK {
                let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
                return isoFormatter.string(from: date)
            }
            return nil

        case CASS_VALUE_TYPE_BLOB:
            var bytes: UnsafePointer<UInt8>?
            var length: Int = 0
            if cass_value_get_bytes(value, &bytes, &length) == CASS_OK, let bytes {
                let data = Data(bytes: bytes, count: length)
                return "0x" + data.map { String(format: "%02x", $0) }.joined()
            }
            return nil

        case CASS_VALUE_TYPE_INET:
            var inet = CassInet()
            if cass_value_get_inet(value, &inet) == CASS_OK {
                var buffer = [CChar](repeating: 0, count: Int(CASS_INET_STRING_LENGTH))
                cass_inet_string(inet, &buffer)
                return String(cString: buffer)
            }
            return nil

        case CASS_VALUE_TYPE_LIST, CASS_VALUE_TYPE_SET:
            return extractCollectionString(value, open: "[", close: "]")

        case CASS_VALUE_TYPE_MAP:
            return extractMapString(value)

        case CASS_VALUE_TYPE_TUPLE:
            return extractCollectionString(value, open: "(", close: ")")

        case CASS_VALUE_TYPE_DATE:
            var dateVal: UInt32 = 0
            if cass_value_get_uint32(value, &dateVal) == CASS_OK {
                let daysSinceEpoch = Int64(dateVal) - Int64(1 << 31)
                let epochSeconds = daysSinceEpoch * 86400
                let date = Date(timeIntervalSince1970: Double(epochSeconds))
                return dateFormatter.string(from: date)
            }
            return nil

        case CASS_VALUE_TYPE_TIME:
            var timeVal: Int64 = 0
            if cass_value_get_int64(value, &timeVal) == CASS_OK {
                // Cassandra time is nanoseconds since midnight
                let totalSeconds = timeVal / 1_000_000_000
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                let seconds = totalSeconds % 60
                let nanos = timeVal % 1_000_000_000
                if nanos > 0 {
                    let millis = nanos / 1_000_000
                    return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
                }
                return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
            }
            return nil

        case CASS_VALUE_TYPE_DECIMAL, CASS_VALUE_TYPE_VARINT:
            // Read as bytes and display as hex since proper numeric decoding
            // requires BigInteger support not available in the C driver API
            var bytes: UnsafePointer<UInt8>?
            var length: Int = 0
            if cass_value_get_bytes(value, &bytes, &length) == CASS_OK, let bytes {
                let data = Data(bytes: bytes, count: length)
                return "0x" + data.map { String(format: "%02x", $0) }.joined()
            }
            return nil

        default:
            // Fallback: try reading as string
            var output: UnsafePointer<CChar>?
            var outputLength: Int = 0
            if cass_value_get_string(value, &output, &outputLength) == CASS_OK, let output {
                return String(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: output),
                    length: outputLength,
                    encoding: .utf8,
                    freeWhenDone: false
                )
            }
            return "<unsupported type>"
        }
    }

    private static func extractCollectionString(
        _ value: OpaquePointer,
        open: String,
        close: String
    ) -> String {
        guard let iterator = cass_iterator_from_collection(value) else {
            return "\(open)\(close)"
        }
        defer { cass_iterator_free(iterator) }

        var elements: [String] = []
        while cass_iterator_next(iterator) == cass_true {
            if let elem = cass_iterator_get_value(iterator) {
                elements.append(extractStringValue(elem) ?? "null")
            }
        }
        return "\(open)\(elements.joined(separator: ", "))\(close)"
    }

    private static func extractMapString(_ value: OpaquePointer) -> String {
        guard let iterator = cass_iterator_from_map(value) else {
            return "{}"
        }
        defer { cass_iterator_free(iterator) }

        var pairs: [String] = []
        while cass_iterator_next(iterator) == cass_true {
            let key = cass_iterator_get_map_key(iterator)
            let val = cass_iterator_get_map_value(iterator)
            let keyStr = key.flatMap { extractStringValue($0) } ?? "null"
            let valStr = val.flatMap { extractStringValue($0) } ?? "null"
            pairs.append("\(keyStr): \(valStr)")
        }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private static func cassTypeName(_ type: CassValueType) -> String {
        switch type {
        case CASS_VALUE_TYPE_ASCII: return "ascii"
        case CASS_VALUE_TYPE_BIGINT: return "bigint"
        case CASS_VALUE_TYPE_BLOB: return "blob"
        case CASS_VALUE_TYPE_BOOLEAN: return "boolean"
        case CASS_VALUE_TYPE_COUNTER: return "counter"
        case CASS_VALUE_TYPE_DECIMAL: return "decimal"
        case CASS_VALUE_TYPE_DOUBLE: return "double"
        case CASS_VALUE_TYPE_FLOAT: return "float"
        case CASS_VALUE_TYPE_INT: return "int"
        case CASS_VALUE_TYPE_TEXT: return "text"
        case CASS_VALUE_TYPE_TIMESTAMP: return "timestamp"
        case CASS_VALUE_TYPE_UUID: return "uuid"
        case CASS_VALUE_TYPE_VARCHAR: return "varchar"
        case CASS_VALUE_TYPE_VARINT: return "varint"
        case CASS_VALUE_TYPE_TIMEUUID: return "timeuuid"
        case CASS_VALUE_TYPE_INET: return "inet"
        case CASS_VALUE_TYPE_DATE: return "date"
        case CASS_VALUE_TYPE_TIME: return "time"
        case CASS_VALUE_TYPE_SMALL_INT: return "smallint"
        case CASS_VALUE_TYPE_TINY_INT: return "tinyint"
        case CASS_VALUE_TYPE_LIST: return "list"
        case CASS_VALUE_TYPE_MAP: return "map"
        case CASS_VALUE_TYPE_SET: return "set"
        case CASS_VALUE_TYPE_TUPLE: return "tuple"
        case CASS_VALUE_TYPE_UDT: return "udt"
        default: return "text"
        }
    }

    private func extractFutureError(_ future: OpaquePointer) -> String {
        var message: UnsafePointer<CChar>?
        var messageLength: Int = 0
        cass_future_error_message(future, &message, &messageLength)
        if let message {
            return String(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: message),
                length: messageLength,
                encoding: .utf8,
                freeWhenDone: false
            ) ?? "Unknown error"
        }
        return "Unknown error"
    }

    func streamQuery(
        _ cql: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let pageSize: Int32 = 5_000
        let statement = cass_statement_new(cql, 0)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to create statement")
        }

        cass_statement_set_paging_size(statement, pageSize)

        var headerSent = false

        defer { cass_statement_free(statement) }

        while true {
            let future = cass_session_execute(session, statement)
            guard let future else {
                throw CassandraPluginError.queryFailed("Failed to execute query")
            }

            cass_future_wait(future)
            let rc = cass_future_error_code(future)

            if rc != CASS_OK {
                let errorMessage = extractFutureError(future)
                cass_future_free(future)
                throw CassandraPluginError.queryFailed(errorMessage)
            }

            let result = cass_future_get_result(future)
            cass_future_free(future)

            guard let result else { break }

            if !headerSent {
                let colCount = cass_result_column_count(result)
                var columns: [String] = []
                var columnTypeNames: [String] = []

                for i in 0..<colCount {
                    var namePtr: UnsafePointer<CChar>?
                    var nameLength: Int = 0
                    cass_result_column_name(result, i, &namePtr, &nameLength)
                    if let namePtr {
                        columns.append(String(cString: namePtr))
                    } else {
                        columns.append("column_\(i)")
                    }
                    let colType = cass_result_column_type(result, i)
                    columnTypeNames.append(Self.cassTypeName(colType))
                }

                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: columnTypeNames,
                    estimatedRowCount: nil
                )))
                headerSent = true
            }

            let colCount = cass_result_column_count(result)
            let iterator = cass_iterator_from_result(result)

            if let iterator {
                while cass_iterator_next(iterator) == cass_true {
                    let row = cass_iterator_get_row(iterator)
                    guard let row else { continue }

                    var rowData: [String?] = []
                    for col in 0..<colCount {
                        let value = cass_row_get_column(row, col)
                        if let value, cass_value_is_null(value) == cass_false {
                            rowData.append(Self.extractStringValue(value))
                        } else {
                            rowData.append(nil)
                        }
                    }
                    continuation.yield(.rows([rowData]))
                }
                cass_iterator_free(iterator)
            }

            let hasMore = cass_result_has_more_pages(result) == cass_true

            if hasMore {
                cass_statement_set_paging_state(statement, result)
            }

            cass_result_free(result)

            if !hasMore { break }
        }

        if !headerSent {
            continuation.yield(.header(PluginStreamHeader(
                columns: [],
                columnTypeNames: [],
                estimatedRowCount: nil
            )))
        }
    }

    private func escapeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }
}

// MARK: - Raw Result

private struct CassandraRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
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

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        let sslMode = config.additionalFields["sslMode"] ?? "Disabled"
        let sslCaCertPath = config.additionalFields["sslCaCertPath"]

        let keyspace = config.database.isEmpty ? nil : config.database

        try await connectionActor.connect(
            host: config.host,
            port: Int(config.port) ?? 9042,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            keyspace: keyspace,
            sslMode: sslMode,
            sslCaCertPath: sslCaCertPath
        )

        if let keyspace {
            stateLock.lock()
            _currentKeyspace = keyspace
            stateLock.unlock()
        }

        // Cache server version
        if let version = try? await connectionActor.serverVersion() {
            stateLock.lock()
            _cachedVersion = version
            stateLock.unlock()
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
        parameters: [String?]
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

    // MARK: - Pagination

    func fetchRowCount(query: String) async throws -> Int {
        // CQL does not support subqueries, so we can't wrap an arbitrary query in SELECT COUNT(*) FROM (...).
        // Return -1 to signal unknown count; the UI will hide the total page count.
        -1
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        // CQL does not support OFFSET. Only the first page (offset=0) can be fetched via simple LIMIT.
        // For offset>0, throw so the caller knows pagination is unsupported for arbitrary queries.
        if offset > 0 {
            throw CassandraPluginError.unsupportedOperation
        }
        let baseQuery = stripTrailingSemicolon(query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let ks = resolveKeyspace(schema)

        // Fetch tables
        let tablesQuery = """
            SELECT table_name FROM system_schema.tables WHERE keyspace_name = '\(escapeSingleQuote(ks))'
        """
        let tablesResult = try await execute(query: tablesQuery)

        var tables = tablesResult.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            return PluginTableInfo(name: name, type: "TABLE")
        }

        // Fetch materialized views
        let viewsQuery = """
            SELECT view_name FROM system_schema.views WHERE keyspace_name = '\(escapeSingleQuote(ks))'
        """
        if let viewsResult = try? await execute(query: viewsQuery) {
            let views = viewsResult.rows.compactMap { row -> PluginTableInfo? in
                guard let name = row[safe: 0] ?? nil else { return nil }
                return PluginTableInfo(name: name, type: "VIEW")
            }
            tables.append(contentsOf: views)
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

        // Parse and sort by kind order then position before mapping to PluginColumnInfo
        struct RawColumn {
            let name: String
            let dataType: String
            let kind: String
            let position: Int
            let isPrimaryKey: Bool
        }

        let rawColumns = result.rows.compactMap { row -> RawColumn? in
            guard let name = row[safe: 0] ?? nil,
                  let dataType = row[safe: 1] ?? nil else {
                return nil
            }
            let kind = (row[safe: 2] ?? nil) ?? "regular"
            let position = Int((row[safe: 4] ?? nil) ?? "0") ?? 0
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
            guard let tableName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let dataType = row[safe: 2] ?? nil else {
                continue
            }
            let kind = row[safe: 3] ?? nil
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
                guard let name = row[safe: 0] ?? nil else { return nil }
                let kind = (row[safe: 1] ?? nil) ?? "COMPOSITES"
                let options = (row[safe: 2] ?? nil) ?? ""

                // Extract target column from options map
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

        // Build DDL from schema metadata
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

        let baseTable = (row[safe: 0] ?? nil) ?? "unknown"
        let whereClause = (row[safe: 1] ?? nil) ?? ""

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
            guard let row = countResult?.rows.first, let countStr = row.first else { return nil }
            return Int64(countStr ?? "0")
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
        return result.rows.compactMap { $0[safe: 0] ?? nil }
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

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let safeKs = escapeIdentifier(name)
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

// MARK: - Errors

internal enum CassandraPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension CassandraPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported by Cassandra")
        }
    }
}
