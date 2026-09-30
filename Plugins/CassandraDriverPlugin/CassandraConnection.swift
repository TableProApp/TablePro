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
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var cluster: OpaquePointer? // CassCluster*
    private var session: OpaquePointer? // CassSession*
    private var currentKeyspace: String?
    private var resumePoints = CassandraResumePoints()
    private static let cancellationPollMicroseconds: cass_duration_t = 50_000
    private static let queryPageSize: Int32 = 5_000

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
        awsRegion: String? = nil,
        connectTimeout: CassandraConnectTimeout = CassandraConnectTimeout(
            milliseconds: CassandraConnectTimeout.defaultMilliseconds
        )
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
                do {
                    try applyClientCertificate(
                        to: ssl,
                        certPath: trimmedClientCertPath,
                        keyPath: trimmedClientKeyPath,
                        keyPassphrase: sslClientKeyPassphrase
                    )
                } catch {
                    cass_ssl_free(ssl)
                    cass_cluster_free(cluster)
                    self.cluster = nil
                    throw error
                }
            }

            cass_cluster_set_ssl(cluster, ssl)
            cass_ssl_free(ssl)
        }

        let nativeTimeout = connectTimeout.nativeConfiguration
        cass_cluster_set_connect_timeout(cluster, nativeTimeout.connectMilliseconds)
        cass_cluster_set_resolve_timeout(cluster, nativeTimeout.resolveMilliseconds)
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

        let didFinish = cass_future_wait_timed(future, cass_duration_t(nativeTimeout.waitMicroseconds))
        guard didFinish == cass_true else {
            cass_future_free(future)
            cass_session_free(newSession)
            cass_cluster_free(cluster)
            self.cluster = nil
            throw CassandraPluginError.connectionFailed(String(localized: "Timed out while connecting to the server"))
        }
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
        keyPassphrase: String?
    ) throws {
        guard !certPath.isEmpty else {
            throw SSLHandshakeError.clientCertRequired(serverMessage: "A client certificate is required when a client key is set")
        }
        guard !keyPath.isEmpty else {
            throw SSLHandshakeError.clientCertRequired(serverMessage: "A client key is required when a client certificate is set")
        }

        guard let certData = FileManager.default.contents(atPath: certPath),
              let certString = String(data: certData, encoding: .utf8) else {
            throw SSLHandshakeError.clientCertRequired(serverMessage: "Could not read client certificate at \(certPath)")
        }
        let certResult = cass_ssl_set_cert(ssl, certString)
        if certResult != CASS_OK {
            throw SSLHandshakeError.clientCertRequired(serverMessage: "Client certificate at \(certPath) is not a valid PEM")
        }

        guard let keyData = FileManager.default.contents(atPath: keyPath),
              let keyString = String(data: keyData, encoding: .utf8) else {
            throw SSLHandshakeError.clientKeyInvalid(serverMessage: "Could not read client key at \(keyPath)")
        }
        let passphrase = keyPassphrase?.isEmpty == false ? keyPassphrase : nil
        let keyResult = cass_ssl_set_private_key(ssl, keyString, passphrase)
        if keyResult != CASS_OK {
            throw CassandraClientKeyClassifier.privateKeyLoadError(keyPEM: keyString, hasPassphrase: passphrase != nil, keyPath: keyPath)
        }
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
        resumePoints.removeAll()
        Self.logger.info("Disconnected from Cassandra")
    }

    /// Reads every row a statement returns, a page at a time, so a large result neither stops at a count of the
    /// driver's choosing nor asks the server for more than it answers unpaged: ScyllaDB aborts an unpaged read past
    /// 100 MB. A statement the server will not page, `IN` with `ORDER BY` on the partition key, is read unpaged.
    func executeQuery(_ cql: String, cancellation: CassandraCancellation? = nil) throws -> CassandraRawResult {
        guard let session else {
            throw CassandraPluginError.notConnected
        }
        forgetResumePointsUnlessRead(cql)

        let startTime = Date()
        do {
            return try executePaged(cql, pageSize: Self.queryPageSize, session: session, cancellation: cancellation,
                                    startTime: startTime)
        } catch let error as CassandraPluginError where error.refusesPaging {
            return try executePaged(cql, pageSize: nil, session: session, cancellation: cancellation,
                                    startTime: startTime)
        }
    }

    private func executePaged(
        _ cql: String,
        pageSize: Int32?,
        session: OpaquePointer,
        cancellation: CassandraCancellation?,
        startTime: Date
    ) throws -> CassandraRawResult {
        guard let statement = cass_statement_new(cql, 0) else {
            throw CassandraPluginError.queryFailed("Failed to create statement")
        }
        defer { cass_statement_free(statement) }
        if let pageSize {
            cass_statement_set_paging_size(statement, pageSize)
        }

        var header: (columns: [String], typeNames: [String])?
        var rows: [[PluginCellValue]] = []
        while true {
            try cancellation?.check()
            guard let result = try executePage(statement, on: session, cancellation: cancellation) else { break }
            defer { cass_result_free(result) }

            if header == nil {
                header = Self.columnHeader(of: result)
            }
            rows += Self.decodeRows(of: result, skipping: 0, taking: Int.max)
            guard pageSize != nil, cass_result_has_more_pages(result) == cass_true else { break }
            guard cass_statement_set_paging_state(statement, result) == CASS_OK else {
                throw CassandraPluginError.queryFailed("Failed to read the next page")
            }
        }

        return CassandraRawResult(
            columns: header?.columns ?? [],
            columnTypeNames: header?.typeNames ?? [],
            rows: rows,
            rowsAffected: rows.count,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }


    func executePrepared(
        _ cql: String,
        parameters: [PluginCellValue],
        cancellation: CassandraCancellation? = nil
    ) throws -> CassandraRawResult {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let startTime = Date()
        forgetResumePointsUnlessRead(cql)
        try cancellation?.check()
        let prepared = try prepare(cql, on: session, cancellation: cancellation)
        defer { cass_prepared_free(prepared) }

        let statement = cass_prepared_bind(prepared)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to bind prepared statement")
        }
        defer { cass_statement_free(statement) }

        try CassandraStatementBinder.bind(parameters, to: statement, prepared: prepared)
        try cancellation?.check()

        guard let result = try executePage(statement, on: session, cancellation: cancellation) else {
            return CassandraRawResult(
                columns: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
        defer { cass_result_free(result) }

        return extractResult(from: result, startTime: startTime)
    }

    /// Reads the rows a table browse shows, walking the paging state past the ones before its offset. A page
    /// is counted by the rows it carried rather than by its size, because ScyllaDB answers a filtered page short.
    func executeBrowse(
        _ browse: CassandraBrowseStatement,
        cancellation: CassandraCancellation
    ) throws -> CassandraRawResult {
        if let refusal = browse.window.refusal {
            throw CassandraBrowseRefusal(pluginErrorMessage: refusal)
        }
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        let startTime = Date()
        try cancellation.check()
        let prepared = try prepare(browse.cql, on: session, cancellation: cancellation)
        defer { cass_prepared_free(prepared) }

        let pageSize = CassandraResumePoints.pageSize(forLimit: browse.window.limit)
        let key = CassandraResumePoints.key(
            keyspace: currentKeyspace, cql: browse.cql, values: browse.window.values, pageSize: pageSize
        )
        if browse.window.offset == 0 {
            resumePoints.remove(key)
        }
        let walk = CassandraBrowseWalk(browse: browse, pageSize: pageSize, key: key)
        let resume = resumePoints.nearest(atOrBefore: browse.window.offset, for: key)

        let read: (header: (columns: [String], typeNames: [String])?, rows: [[PluginCellValue]])
        do {
            read = try self.walk(walk, from: resume, prepared: prepared, session: session, cancellation: cancellation)
        } catch let error where resume != nil && !(error is CancellationError) {
            Self.logger.info("Browse resume point refused, walking from the first row: \(error.localizedDescription)")
            resumePoints.remove(key)
            read = try self.walk(walk, from: nil, prepared: prepared, session: session, cancellation: cancellation)
        }

        return CassandraRawResult(
            columns: read.header?.columns ?? [],
            columnTypeNames: read.header?.typeNames ?? [],
            rows: read.rows,
            rowsAffected: read.rows.count,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func walk(
        _ walk: CassandraBrowseWalk,
        from resume: (position: Int, token: Data)?,
        prepared: OpaquePointer,
        session: OpaquePointer,
        cancellation: CassandraCancellation
    ) throws -> (header: (columns: [String], typeNames: [String])?, rows: [[PluginCellValue]]) {
        guard let statement = cass_prepared_bind(prepared) else {
            throw CassandraPluginError.queryFailed("Failed to bind prepared statement")
        }
        defer { cass_statement_free(statement) }

        try CassandraStatementBinder.bind(walk.browse.window.values.map { .text($0) }, to: statement, prepared: prepared)
        cass_statement_set_paging_size(statement, Int32(walk.pageSize))

        let offset = walk.browse.window.offset
        let limit = walk.browse.window.limit
        var position = 0
        if let resume {
            position = resume.position
            try setPagingToken(resume.token, on: statement)
        }

        var header: (columns: [String], typeNames: [String])?
        var rows: [[PluginCellValue]] = []

        while true {
            try cancellation.check()
            guard let result = try executePage(statement, on: session, cancellation: cancellation) else { break }
            defer { cass_result_free(result) }

            if header == nil {
                header = Self.columnHeader(of: result)
            }
            let pageRowCount = cass_result_row_count(result)
            if rows.count < limit, position + pageRowCount > offset {
                rows += Self.decodeRows(
                    of: result,
                    skipping: max(offset - position, 0),
                    taking: limit - rows.count
                )
            }
            position += pageRowCount

            guard cass_result_has_more_pages(result) == cass_true else { break }
            let token = Self.pagingToken(of: result)
            resumePoints.record(token, at: position, for: walk.key)
            guard rows.count < limit else { break }
            try setPagingToken(token, on: statement)
        }
        return (header, rows)
    }

    /// A statement that is not a read can change the rows a walk counted, so the points it left no longer mark
    /// the rows they did.
    private func forgetResumePointsUnlessRead(_ cql: String) {
        let leading = cql.drop { $0.isWhitespace || $0 == "(" }.prefix(6).uppercased()
        guard leading != "SELECT" else { return }
        resumePoints.removeAll()
    }

    private func prepare(
        _ cql: String,
        on session: OpaquePointer,
        cancellation: CassandraCancellation? = nil
    ) throws -> OpaquePointer {
        guard let prepareFuture = cass_session_prepare(session, cql) else {
            throw CassandraPluginError.queryFailed("Failed to prepare statement")
        }
        defer { cass_future_free(prepareFuture) }

        try wait(for: prepareFuture, cancellation: cancellation)
        guard cass_future_error_code(prepareFuture) == CASS_OK else {
            throw CassandraPluginError.queryFailed(extractFutureError(prepareFuture))
        }
        guard let prepared = cass_future_get_prepared(prepareFuture) else {
            throw CassandraPluginError.queryFailed("Failed to get prepared statement")
        }
        return prepared
    }

    private func executePage(
        _ statement: OpaquePointer,
        on session: OpaquePointer,
        cancellation: CassandraCancellation? = nil
    ) throws -> OpaquePointer? {
        guard let future = cass_session_execute(session, statement) else {
            throw CassandraPluginError.queryFailed("Failed to execute prepared statement")
        }
        defer { cass_future_free(future) }

        try wait(for: future, cancellation: cancellation)
        guard cass_future_error_code(future) == CASS_OK else {
            throw CassandraPluginError.queryFailed(extractFutureError(future))
        }
        return cass_future_get_result(future)
    }

    /// A request blocks until the server answers, so one that is cancelled stops being waited for instead: the
    /// future is freed, which the driver allows at any time, and the server's answer is dropped when it arrives.
    private func wait(for future: OpaquePointer, cancellation: CassandraCancellation?) throws {
        guard let cancellation else {
            cass_future_wait(future)
            return
        }
        while cass_future_wait_timed(future, Self.cancellationPollMicroseconds) == cass_false {
            try cancellation.check()
        }
        try cancellation.check()
    }

    private func setPagingToken(_ token: Data, on statement: OpaquePointer) throws {
        let rc = token.withUnsafeBytes { buffer in
            cass_statement_set_paging_state_token(
                statement,
                buffer.bindMemory(to: CChar.self).baseAddress,
                token.count
            )
        }
        guard rc == CASS_OK else {
            throw CassandraPluginError.queryFailed("Failed to resume the browse from its paging state")
        }
    }

    private static func pagingToken(of result: OpaquePointer) -> Data {
        var token: UnsafePointer<CChar>?
        var length: Int = 0
        guard cass_result_paging_state_token(result, &token, &length) == CASS_OK, let token else { return Data() }
        return Data(bytes: token, count: length)
    }

    private static func columnHeader(of result: OpaquePointer) -> (columns: [String], typeNames: [String]) {
        let columnCount = cass_result_column_count(result)
        var columns: [String] = []
        var typeNames: [String] = []
        for index in 0..<columnCount {
            var namePtr: UnsafePointer<CChar>?
            var nameLength: Int = 0
            cass_result_column_name(result, index, &namePtr, &nameLength)
            columns.append(namePtr.map { String(cString: $0) } ?? "column_\(index)")
            typeNames.append(cassTypeName(cass_result_column_type(result, index)))
        }
        return (columns, typeNames)
    }

    private static func decodeRows(of result: OpaquePointer, skipping skip: Int, taking take: Int) -> [[PluginCellValue]] {
        guard take > 0, let iterator = cass_iterator_from_result(result) else { return [] }
        defer { cass_iterator_free(iterator) }

        let columnCount = cass_result_column_count(result)
        var skipped = 0
        var rows: [[PluginCellValue]] = []
        while rows.count < take, cass_iterator_next(iterator) == cass_true {
            guard skipped >= skip else {
                skipped += 1
                continue
            }
            guard let row = cass_iterator_get_row(iterator) else { continue }
            rows.append(decodeRow(row, columnCount: columnCount))
        }
        return rows
    }

    func switchKeyspace(_ keyspace: String) throws {
        _ = try executeQuery("USE \"\(escapeIdentifier(keyspace))\"")
        currentKeyspace = keyspace
    }

    func serverVersion(requestTimeoutMilliseconds: UInt32) throws -> String? {
        guard let session else {
            throw CassandraPluginError.notConnected
        }
        let cql = "SELECT release_version FROM system.local WHERE key = 'local'"
        guard let statement = cass_statement_new(cql, 0) else {
            throw CassandraPluginError.queryFailed("Failed to create server version probe")
        }
        defer { cass_statement_free(statement) }
        guard cass_statement_set_request_timeout(statement, UInt64(requestTimeoutMilliseconds)) == CASS_OK else {
            throw CassandraPluginError.queryFailed("Failed to set the server version probe timeout")
        }
        guard let result = try executePage(statement, on: session) else { return nil }
        defer { cass_result_free(result) }
        return Self.decodeRows(of: result, skipping: 0, taking: 1).first?.first?.asText
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

        while cass_iterator_next(iterator) == cass_true {
            let row = cass_iterator_get_row(iterator)
            guard let row else { continue }

            rows.append(Self.decodeRow(row, columnCount: colCount))
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

    static func decodeRow(_ row: OpaquePointer, columnCount: Int) -> [PluginCellValue] {
        (0..<columnCount).map { column in
            guard let value = cass_row_get_column(row, column), cass_value_is_null(value) == cass_false else {
                return .null
            }
            if cass_value_type(value) == CASS_VALUE_TYPE_BLOB, let data = extractBlobValue(value) {
                return .bytes(data)
            }
            return PluginCellValue.fromOptional(extractStringValue(value))
        }
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
                let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000.0)
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
            return extractTupleString(value)

        case CASS_VALUE_TYPE_UDT:
            return extractUserTypeString(value)

        case CASS_VALUE_TYPE_DURATION:
            var months: Int32 = 0
            var days: Int32 = 0
            var nanoseconds: Int64 = 0
            guard cass_value_get_duration(value, &months, &days, &nanoseconds) == CASS_OK else { return nil }
            return CassandraCellText.durationText(months: months, days: days, nanoseconds: nanoseconds)

        case CASS_VALUE_TYPE_CUSTOM:
            var bytes: UnsafePointer<UInt8>?
            var length: Int = 0
            guard cass_value_get_bytes(value, &bytes, &length) == CASS_OK, let bytes else { return nil }
            return CassandraCellText.customText(
                className: customClassName(of: value), bytes: Data(bytes: bytes, count: length)
            )

        case CASS_VALUE_TYPE_DATE:
            var dateVal: UInt32 = 0
            if cass_value_get_uint32(value, &dateVal) == CASS_OK {
                let daysSinceEpoch = Int64(dateVal) - Int64(1 << 31)
                let epochSeconds = daysSinceEpoch * 86_400
                let date = Date(timeIntervalSince1970: Double(epochSeconds))
                return dateFormatter.string(from: date)
            }
            return nil

        case CASS_VALUE_TYPE_TIME:
            var timeVal: Int64 = 0
            guard cass_value_get_int64(value, &timeVal) == CASS_OK else { return nil }
            return CassandraValueParser.timeText(nanoseconds: timeVal)

        case CASS_VALUE_TYPE_VARINT:
            var bytes: UnsafePointer<UInt8>?
            var length: Int = 0
            guard cass_value_get_bytes(value, &bytes, &length) == CASS_OK, let bytes else { return nil }
            return CassandraVarint.decimalString(fromTwosComplement: Data(bytes: bytes, count: length))

        case CASS_VALUE_TYPE_DECIMAL:
            var unscaled: UnsafePointer<UInt8>?
            var length: Int = 0
            var scale: Int32 = 0
            guard cass_value_get_decimal(value, &unscaled, &length, &scale) == CASS_OK, let unscaled else { return nil }
            return CassandraVarint.decimalString(unscaled: Data(bytes: unscaled, count: length), scale: scale)

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

    private static func extractTupleString(_ value: OpaquePointer) -> String {
        guard let iterator = cass_iterator_from_tuple(value) else { return "()" }
        defer { cass_iterator_free(iterator) }

        var elements: [String] = []
        while cass_iterator_next(iterator) == cass_true {
            elements.append(cass_iterator_get_value(iterator).flatMap(nestedText) ?? "null")
        }
        return "(\(elements.joined(separator: ", ")))"
    }

    private static func extractUserTypeString(_ value: OpaquePointer) -> String {
        guard let iterator = cass_iterator_fields_from_user_type(value) else { return "{}" }
        defer { cass_iterator_free(iterator) }

        var fields: [String] = []
        while cass_iterator_next(iterator) == cass_true {
            var namePointer: UnsafePointer<CChar>?
            var nameLength: Int = 0
            let name = cass_iterator_get_user_type_field_name(iterator, &namePointer, &nameLength) == CASS_OK
                ? namePointer.flatMap { String(bytes: UnsafeRawBufferPointer(start: $0, count: nameLength), encoding: .utf8) }
                : nil
            let fieldValue = cass_iterator_get_user_type_field_value(iterator).flatMap(nestedText) ?? "null"
            fields.append("\(name ?? "?"): \(fieldValue)")
        }
        return "{\(fields.joined(separator: ", "))}"
    }

    private static func nestedText(_ value: OpaquePointer) -> String? {
        guard cass_value_is_null(value) == cass_false else { return nil }
        return extractStringValue(value)
    }

    private static func customClassName(of value: OpaquePointer) -> String? {
        guard let dataType = cass_value_data_type(value) else { return nil }
        var name: UnsafePointer<CChar>?
        var length: Int = 0
        guard cass_data_type_class_name(dataType, &name, &length) == CASS_OK, let name else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: name, count: length), encoding: .utf8)
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

    /// The whole loop is one non-suspending actor job holding the cooperative-pool thread, and
    /// cass_future_wait blocks it, so nothing outside can interrupt a page. `abort` is the only
    /// way the consumer's departure reaches this body, and it is read between pages and between
    /// rows rather than mid-request.
    func streamQuery(
        _ cql: String,
        abort: PluginStreamAbort,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        guard let session else {
            throw CassandraPluginError.notConnected
        }

        guard !abort.isAborted else { return }
        forgetResumePointsUnlessRead(cql)

        let pageSize: Int32 = 5_000
        let statement = cass_statement_new(cql, 0)
        guard let statement else {
            throw CassandraPluginError.queryFailed("Failed to create statement")
        }

        cass_statement_set_paging_size(statement, pageSize)

        var headerSent = false

        defer { cass_statement_free(statement) }

        var aborted = false

        while true {
            if abort.isAborted { break }
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
                var rowsThisPage = 0
                while cass_iterator_next(iterator) == cass_true {
                    rowsThisPage += 1
                    if rowsThisPage % 256 == 0, abort.isAborted {
                        aborted = true
                        break
                    }
                    let row = cass_iterator_get_row(iterator)
                    guard let row else { continue }
                    continuation.yield(.rows([Self.decodeRow(row, columnCount: colCount)]))
                }
                cass_iterator_free(iterator)
            }

            let hasMore = cass_result_has_more_pages(result) == cass_true

            if hasMore, !aborted {
                cass_statement_set_paging_state(statement, result)
            }

            cass_result_free(result)

            if !hasMore || aborted { break }
        }

        if !headerSent, !aborted {
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
