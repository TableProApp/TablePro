//
//  CassandraConnection.swift
//  CassandraDriverPlugin
//

#if canImport(CCassandra)
import CCassandra
#endif
import Foundation
import os
import TableProPluginKit

actor CassandraConnectionActor {
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
        sslMode: SSLMode,
        sslCaCertPath: String?,
        sslClientCertPath: String?,
        sslClientKeyPath: String?,
        sslClientKeyPassphrase: String?,
        awsCredentials: AWSCredentials? = nil,
        awsRegion: String? = nil
    ) throws {
        cluster = cass_cluster_new()
        guard let cluster else {
            throw CassandraPluginError.connectionFailed("Failed to create cluster object")
        }

        cass_cluster_set_contact_points(cluster, host)
        cass_cluster_set_port(cluster, Int32(port))

        if let awsCredentials, let awsRegion, !awsRegion.isEmpty {
            CassandraSigV4Authenticator.apply(to: cluster, credentials: awsCredentials, region: awsRegion)
        } else if let username, !username.isEmpty, let password {
            cass_cluster_set_credentials(cluster, username, password)
        }

        if sslMode != .disabled {
            guard let ssl = cass_ssl_new() else {
                cass_cluster_free(cluster)
                self.cluster = nil
                throw CassandraPluginError.connectionFailed("Failed to create SSL context")
            }

            cass_ssl_set_verify_flags(ssl, CassandraSSLMapping.verifyFlags(for: sslMode))

            if sslMode == .verifyCa || sslMode == .verifyIdentity {
                guard let caCertPath = sslCaCertPath, !caCertPath.isEmpty else {
                    cass_ssl_free(ssl)
                    cass_cluster_free(cluster)
                    self.cluster = nil
                    throw SSLHandshakeError.untrustedCertificate(serverMessage: "Verify CA or Verify Identity requires a CA certificate path")
                }
                guard let certData = FileManager.default.contents(atPath: caCertPath),
                      let certString = String(data: certData, encoding: .utf8) else {
                    cass_ssl_free(ssl)
                    cass_cluster_free(cluster)
                    self.cluster = nil
                    throw SSLHandshakeError.untrustedCertificate(serverMessage: "Could not read CA certificate at \(caCertPath)")
                }
                let rc = cass_ssl_add_trusted_cert(ssl, certString)
                if rc != CASS_OK {
                    cass_ssl_free(ssl)
                    cass_cluster_free(cluster)
                    self.cluster = nil
                    throw SSLHandshakeError.untrustedCertificate(serverMessage: "CA certificate at \(caCertPath) is not a valid PEM")
                }
            }

            let trimmedClientCertPath = sslClientCertPath?.trimmingCharacters(in: .whitespaces) ?? ""
            let trimmedClientKeyPath = sslClientKeyPath?.trimmingCharacters(in: .whitespaces) ?? ""
            if !trimmedClientCertPath.isEmpty || !trimmedClientKeyPath.isEmpty {
                try applyClientCertificate(
                    to: ssl,
                    certPath: trimmedClientCertPath,
                    keyPath: trimmedClientKeyPath,
                    keyPassphrase: sslClientKeyPassphrase
                ) {
                    cass_ssl_free(ssl)
                    cass_cluster_free(cluster)
                    self.cluster = nil
                }
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
            if let sslError = Self.classifySSLError(rc: rc, message: errorMessage) {
                throw sslError
            }
            throw CassandraPluginError.connectionFailed(errorMessage)
        }

        cass_future_free(future)
        session = newSession

        Self.logger.info("Connected to Cassandra at \(host):\(port)")
    }

    private func applyClientCertificate(
        to ssl: OpaquePointer,
        certPath: String,
        keyPath: String,
        keyPassphrase: String?,
        cleanup: () -> Void
    ) throws {
        guard !certPath.isEmpty else {
            cleanup()
            throw SSLHandshakeError.clientCertRequired(serverMessage: "A client certificate is required when a client key is set")
        }
        guard !keyPath.isEmpty else {
            cleanup()
            throw SSLHandshakeError.clientCertRequired(serverMessage: "A client key is required when a client certificate is set")
        }

        guard let certData = FileManager.default.contents(atPath: certPath),
              let certString = String(data: certData, encoding: .utf8) else {
            cleanup()
            throw SSLHandshakeError.clientCertRequired(serverMessage: "Could not read client certificate at \(certPath)")
        }
        let certResult = cass_ssl_set_cert(ssl, certString)
        if certResult != CASS_OK {
            cleanup()
            throw SSLHandshakeError.clientCertRequired(serverMessage: "Client certificate at \(certPath) is not a valid PEM")
        }

        guard let keyData = FileManager.default.contents(atPath: keyPath),
              let keyString = String(data: keyData, encoding: .utf8) else {
            cleanup()
            throw SSLHandshakeError.clientKeyInvalid(serverMessage: "Could not read client key at \(keyPath)")
        }
        let passphrase = keyPassphrase?.isEmpty == false ? keyPassphrase : nil
        let keyResult = cass_ssl_set_private_key(ssl, keyString, passphrase)
        if keyResult != CASS_OK {
            cleanup()
            throw Self.privateKeyLoadError(keyPEM: keyString, hasPassphrase: passphrase != nil, keyPath: keyPath)
        }
    }

    static func isEncryptedPrivateKey(_ pem: String) -> Bool {
        pem.contains("ENCRYPTED PRIVATE KEY") || (pem.contains("Proc-Type:") && pem.contains("ENCRYPTED"))
    }

    static func privateKeyLoadError(keyPEM: String, hasPassphrase: Bool, keyPath: String) -> SSLHandshakeError {
        guard isEncryptedPrivateKey(keyPEM) else {
            return .clientKeyInvalid(serverMessage: "The client key at \(keyPath) is not a valid private key")
        }
        if hasPassphrase {
            return .clientKeyPassphraseIncorrect(serverMessage: "The passphrase for the client key at \(keyPath) is incorrect")
        }
        return .clientKeyPassphraseRequired(serverMessage: "The client key at \(keyPath) is encrypted. Enter its passphrase.")
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

    func executePrepared(_ cql: String, parameters: [PluginCellValue]) throws -> CassandraRawResult {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let startTime = Date()

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

        let statement = cass_prepared_bind(prepared)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to bind prepared statement")
        }
        defer { cass_statement_free(statement) }

        for (index, param) in parameters.enumerated() {
            switch param {
            case .text(let value):
                cass_statement_bind_string(statement, index, value)
            case .bytes(let data):
                data.withUnsafeBytes { rawBuffer in
                    if let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        cass_statement_bind_bytes(statement, index, base, data.count)
                    } else {
                        cass_statement_bind_null(statement, index)
                    }
                }
            case .null:
                cass_statement_bind_null(statement, index)
            }
        }

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
        return result.rows.first?.first?.asText
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

        var rows: [[PluginCellValue]] = []
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

            var rowData: [PluginCellValue] = []
            for col in 0..<colCount {
                let value = cass_row_get_column(row, col)
                if let value, cass_value_is_null(value) == cass_false {
                    if cass_value_type(value) == CASS_VALUE_TYPE_BLOB,
                       let data = Self.extractBlobValue(value) {
                        rowData.append(.bytes(data))
                    } else {
                        rowData.append(PluginCellValue.fromOptional(Self.extractStringValue(value)))
                    }
                } else {
                    rowData.append(.null)
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

    private static func extractBlobValue(_ value: OpaquePointer) -> Data? {
        var bytes: UnsafePointer<UInt8>?
        var length: Int = 0
        guard cass_value_get_bytes(value, &bytes, &length) == CASS_OK, let bytes else {
            return nil
        }
        return Data(bytes: bytes, count: length)
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
            if let data = extractBlobValue(value) {
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

                    var rowData: [PluginCellValue] = []
                    for col in 0..<colCount {
                        let value = cass_row_get_column(row, col)
                        if let value, cass_value_is_null(value) == cass_false {
                            if cass_value_type(value) == CASS_VALUE_TYPE_BLOB,
                               let data = Self.extractBlobValue(value) {
                                rowData.append(.bytes(data))
                            } else {
                                rowData.append(PluginCellValue.fromOptional(Self.extractStringValue(value)))
                            }
                        } else {
                            rowData.append(.null)
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

    static func classifySSLError(rc: CassError, message: String) -> SSLHandshakeError? {
        switch rc {
        case CASS_ERROR_SSL_NO_PEER_CERT, CASS_ERROR_SSL_INVALID_PEER_CERT:
            return .untrustedCertificate(serverMessage: message)
        case CASS_ERROR_SSL_IDENTITY_MISMATCH:
            return .hostnameMismatch(serverMessage: message)
        case CASS_ERROR_SSL_INVALID_PRIVATE_KEY, CASS_ERROR_SSL_INVALID_CERT:
            return .clientCertRequired(serverMessage: message)
        case CASS_ERROR_SSL_PROTOCOL_ERROR:
            return .cipherMismatch(serverMessage: message)
        default:
            break
        }
        let lower = message.lowercased()
        if lower.contains("ssl handshake") || lower.contains("tls handshake") || lower.contains("ssl_connect") {
            return .cipherMismatch(serverMessage: message)
        }
        return nil
    }
}

// MARK: - Raw Result

struct CassandraRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
}
