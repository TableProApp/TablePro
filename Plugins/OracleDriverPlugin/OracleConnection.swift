//
//  OracleConnection.swift
//  TablePro
//
//  Pure Swift Oracle connection using OracleNIO.
//  Provides thread-safe, async-friendly Oracle Database connections.
//

import Foundation
import Logging
import NIOCore
import NIOSSL
import OracleNIO
import OSLog
import TableProPluginKit

private let osLogger = Logger(subsystem: "com.TablePro", category: "OracleConnection")

// MARK: - Error Types

struct OracleError: Error {
    enum Category: Sendable, Equatable {
        case generic
        case notConnected
        case connectionFailed
        case queryFailed
        case protocolError
        case authVerifierUnsupported(flag: String)
        case authVersionNotSupported
        case authConnectionDropped(phase: String?)
        case loginTimedOut
        case queryTimedOut
        case nativeEncryptionFailed
    }

    let message: String
    let category: Category

    init(message: String, category: Category = .generic) {
        self.message = message
        self.category = category
    }

    static let notConnected = OracleError(
        message: String(localized: "Not connected to database"),
        category: .notConnected
    )
    static let connectionFailed = OracleError(
        message: String(localized: "Failed to establish connection"),
        category: .connectionFailed
    )
    static let queryFailed = OracleError(
        message: String(localized: "Query execution failed"),
        category: .queryFailed
    )
}

extension OracleError: PluginDriverError {
    var pluginErrorMessage: String { message }
}

// MARK: - Query Result

struct OracleQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let affectedRows: Int
    let isTruncated: Bool
}

// MARK: - Query Serialization

/// OracleNIO does not support concurrent queries on a single connection.
/// Sending a second statement while the first stream is active corrupts the
/// state machine. This actor serializes all executeQuery calls.
private actor QueryGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            busy = false
        }
    }
}

// MARK: - Unsupported Type Warner

private actor UnsupportedTypeWarner {
    private var seen: Set<String> = []

    func warnIfNew(_ typeName: String) -> Bool {
        guard !seen.contains(typeName) else { return false }
        seen.insert(typeName)
        return true
    }
}

// MARK: - Connection Class

final class OracleConnectionWrapper: @unchecked Sendable {
    // MARK: - Properties

    private static let connectionCounter = OSAllocatedUnfairLock(initialState: 0)
    private let queryGate = QueryGate()

    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let serviceName: String
    private let useSID: Bool
    private let sslConfig: SSLConfiguration
    private let nativeNetworkEncryption: Bool

    private struct LockedState: Sendable {
        var isConnected = false
        var hasEverConnected = false
        var nioConnection: OracleNIO.OracleConnection?
        var queryTimeoutSeconds = 0
        var sessionSchema: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())
    private let nioLogger = Logging.Logger(label: "com.TablePro.oracle-nio")

    var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    // MARK: - Initialization

    init(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String,
        serviceName: String = "",
        useSID: Bool = false,
        sslConfig: SSLConfiguration = SSLConfiguration(),
        nativeNetworkEncryption: Bool = false
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.serviceName = serviceName
        self.useSID = useSID
        self.sslConfig = sslConfig
        self.nativeNetworkEncryption = nativeNetworkEncryption
    }

    // MARK: - Connection

    func connect() async throws {
        let identifier = serviceName.isEmpty ? database : serviceName
        let service: OracleServiceMethod = useSID ? .sid(identifier) : .serviceName(identifier)
        let tls = try OracleSSLMapping.tls(for: sslConfig)
        var config = OracleNIO.OracleConnection.Configuration(
            host: host,
            port: port,
            service: service,
            username: user,
            password: password,
            tls: tls
        )
        config.nativeNetworkEncryption = nativeNetworkEncryption
        let connectConfig = config
        let connectLogger = nioLogger

        let connectionId = Self.connectionCounter.withLock { state -> Int in
            state += 1
            return state
        }

        do {
            let connection = try await withTimeout(seconds: Self.loginTimeoutSeconds) {
                try await OracleNIO.OracleConnection.connect(
                    configuration: connectConfig,
                    id: connectionId,
                    logger: connectLogger
                )
            }

            state.withLock { current in
                current.nioConnection = connection
                current.isConnected = true
                current.hasEverConnected = true
            }

            let target = useSID ? "\(self.host):\(self.port):\(identifier)" : "\(self.host):\(self.port)/\(identifier)"
            osLogger.debug("Connected to Oracle \(target)")
        } catch is TimeoutError {
            osLogger.error("Oracle login handshake timed out after \(Self.loginTimeoutSeconds, privacy: .public)s (nativeEncryption=\(self.nativeNetworkEncryption, privacy: .public))")
            throw makeConnectError(failure: .connectionFailed, detail: "", timedOut: true, phase: nil)
        } catch let sqlError as OracleSQLError {
            let detail = Self.connectFailureDetail(sqlError)
            let phase = sqlError.handshakePhase ?? "unknown"
            osLogger.error("Oracle connection failed at phase \(phase, privacy: .public) (\(sqlError.code.description, privacy: .public)): \(detail)")
            if let sslError = OracleSSLClassifier.classifySSLError(detail) {
                throw sslError
            }
            let failure = OracleConnectErrorClassifier.classify(sqlError.code.description)
            throw makeConnectError(failure: failure, detail: detail, timedOut: false, phase: sqlError.handshakePhase)
        } catch let nioSslError as NIOSSLError {
            let detail = String(describing: nioSslError)
            osLogger.error("Oracle TLS error: \(detail)")
            throw OracleSSLClassifier.classifySSLError(detail) ?? SSLHandshakeError.unknown(serverMessage: detail)
        } catch {
            let detail = String(describing: error)
            osLogger.error("Oracle connection failed: \(detail)")
            if let sslError = OracleSSLClassifier.classifySSLError(detail) {
                throw sslError
            }
            throw OracleError(message: detail, category: .connectionFailed)
        }
    }

    private static let loginTimeoutSeconds: Double = 30

    private func makeConnectError(
        failure: OracleConnectFailure,
        detail: String,
        timedOut: Bool,
        phase: String?
    ) -> OracleError {
        if OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: failure,
            nativeNetworkEncryptionEnabled: nativeNetworkEncryption,
            timedOut: timedOut
        ) {
            return OracleError(message: Self.nativeEncryptionFailureMessage, category: .nativeEncryptionFailed)
        }
        if timedOut {
            return OracleError(message: Self.loginTimeoutMessage, category: .loginTimedOut)
        }
        let category = Self.category(for: failure, phase: phase)
        return OracleError(
            message: Self.connectErrorMessage(for: category, serverDetail: detail),
            category: category
        )
    }

    private static func category(for failure: OracleConnectFailure, phase: String?) -> OracleError.Category {
        switch failure {
        case .verifierUnsupported(let flag):
            return .authVerifierUnsupported(flag: flag)
        case .versionNotSupported:
            return .authVersionNotSupported
        case .connectionDropped:
            return .authConnectionDropped(phase: phase)
        case .connectionFailed:
            return .connectionFailed
        @unknown default:
            return .connectionFailed
        }
    }

    private static let loginTimeoutMessage = String(
        localized: "Timed out during the Oracle login handshake. The server accepted the network connection but did not finish logging in."
    )

    private static let nativeEncryptionFailureMessage = String(
        localized: """
        Could not finish logging in with native network encryption enabled. \
        This Oracle server may not support it, which is common with Oracle 11g. \
        Turn off the Native network encryption option in this connection's settings and try again.
        """
    )

    private static func connectFailureDetail(_ error: OracleSQLError) -> String {
        if let refused = error.underlying as? OracleListenerRefusedError {
            return OracleListenerRefusal.detail(code: refused.code)
        }
        return error.serverInfo?.message ?? error.description
    }

    private static func connectErrorMessage(
        for category: OracleError.Category,
        serverDetail: String
    ) -> String {
        switch category {
        case .authVersionNotSupported:
            return String(localized: "This Oracle server is older than release 11.1, which the database driver does not support.")
        case .authConnectionDropped:
            return String(localized: "The Oracle server closed the connection during the login handshake.")
        case .authVerifierUnsupported:
            return String(localized: "This account uses a password verifier the database driver does not support.")
        case .loginTimedOut:
            return loginTimeoutMessage
        case .queryTimedOut:
            return queryTimeoutMessage
        case .nativeEncryptionFailed:
            return nativeEncryptionFailureMessage
        case .generic, .notConnected, .connectionFailed, .queryFailed, .protocolError:
            return serverDetail
        }
    }

    private static let queryTimeoutMessage = String(
        localized: "The query did not finish within the configured timeout, so the connection was reset. Run the query again."
    )

    private func mapQueryError(_ sqlError: OracleSQLError) -> OracleError {
        guard Self.isChannelFatal(sqlError) else {
            return OracleError(message: sqlError.serverInfo?.message ?? sqlError.description)
        }
        state.withLock { current in
            current.isConnected = false
            current.nioConnection = nil
        }
        osLogger.error("Oracle connection reset after fatal protocol error: \(sqlError.code.description)")
        return OracleError(
            message: String(localized: "The server sent an unexpected message and the connection was reset. Run the query again."),
            category: .protocolError
        )
    }

    private static func isChannelFatal(_ error: OracleSQLError) -> Bool {
        OracleChannelFatalCode.isChannelFatal(error.code.description)
    }

    func disconnect() {
        let connection = state.withLock { current -> OracleNIO.OracleConnection? in
            guard current.isConnected else { return nil }
            current.isConnected = false
            let conn = current.nioConnection
            current.nioConnection = nil
            return conn
        }

        guard let connection else { return }

        Task {
            try? await connection.close()
            osLogger.debug("Disconnected from Oracle \(self.host):\(self.port)")
        }
    }

    func applyQueryTimeout(_ seconds: Int) {
        state.withLock { $0.queryTimeoutSeconds = max(0, seconds) }
    }

    func noteSessionSchema(_ schema: String) {
        state.withLock { $0.sessionSchema = schema }
    }

    // MARK: - Query Execution

    private func requireConnection() throws -> OracleNIO.OracleConnection {
        try state.withLock { current in
            guard let conn = current.nioConnection, current.isConnected else {
                throw OracleError.notConnected
            }
            return conn
        }
    }

    /// Serialized behind the query gate, so at most one reconnect runs at a time.
    /// Reconnecting restores the session schema, which ALTER SESSION state does
    /// not survive across connections.
    private func reconnectedConnection() async throws -> OracleNIO.OracleConnection {
        if let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) {
            return connection
        }
        guard state.withLock({ $0.hasEverConnected }) else {
            throw OracleError.notConnected
        }

        osLogger.notice("Reconnecting to Oracle after the previous connection was closed")
        try await connect()
        let connection = try requireConnection()
        if let schema = state.withLock({ $0.sessionSchema }) {
            _ = try await withQueryDeadline { [self] in
                try await collectRows(Self.currentSchemaStatement(schema), on: connection)
            }
        }
        return connection
    }

    private static func currentSchemaStatement(_ schema: String) -> String {
        let escaped = schema.replacingOccurrences(of: "\"", with: "\"\"")
        return "ALTER SESSION SET CURRENT_SCHEMA = \"\(escaped)\""
    }

    /// Races the operation against the configured query timeout. On timeout the
    /// connection is closed first, which fails the in-flight OracleNIO call even
    /// if it ignores task cancellation, so the race can always unwind.
    private func withQueryDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = state.withLock { $0.queryTimeoutSeconds }
        guard timeoutSeconds > 0 else { return try await operation() }

        return try await withTimeout(
            seconds: Double(timeoutSeconds),
            onTimeout: { [self] in disconnect() },
            operation: operation
        )
    }

    private func queryTimeoutError(_ timeout: TimeoutError) -> OracleError {
        osLogger.error("Oracle query timed out after \(Int(timeout.seconds), privacy: .public)s; the connection was closed to recover")
        return OracleError(message: Self.queryTimeoutMessage, category: .queryTimedOut)
    }

    private func mapExecutionError(_ error: Error) -> Error {
        switch error {
        case let timeout as TimeoutError:
            return queryTimeoutError(timeout)
        case let sqlError as OracleSQLError:
            return mapQueryError(sqlError)
        case let oracleError as OracleError:
            return oracleError
        case is CancellationError:
            return error
        default:
            return OracleError(message: "Query execution failed: \(String(describing: error))")
        }
    }

    func executeQuery(_ query: String) async throws -> OracleQueryResult {
        // OracleNIO does not support concurrent queries on a single connection.
        // Serialize all queries to prevent state-machine corruption.
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            let result = try await withQueryDeadline { [self] in
                try await collectRows(query, on: connection)
            }
            await queryGate.release()
            return result
        } catch {
            await queryGate.release()
            throw mapExecutionError(error)
        }
    }

    private func collectRows(
        _ query: String,
        on connection: OracleNIO.OracleConnection
    ) async throws -> OracleQueryResult {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, logger: nioLogger)

        // Read column metadata from stream (available even with 0 rows)
        var columns: [String] = []
        for col in stream.columns {
            columns.append(col.name)
        }
        osLogger.debug("Oracle columns (\(columns.count)): \(columns.joined(separator: ", "))")

        var columnTypeNames: [String] = []
        var allRows: [[PluginCellValue]] = []
        var didReadTypes = false
        var truncated = false

        for try await row in stream {
            var rowValues: [PluginCellValue] = []
            for cell in row {
                if !didReadTypes {
                    columnTypeNames.append(oracleTypeName(cell.dataType))
                }
                if cell.bytes == nil {
                    rowValues.append(.null)
                } else if cell.dataType == .raw || cell.dataType == .longRAW || cell.dataType == .blob,
                          let bytes = cell.bytes {
                    rowValues.append(.bytes(Data(bytes.readableBytesView)))
                } else {
                    rowValues.append(PluginCellValue.fromOptional(decodeCell(cell)))
                }
            }
            didReadTypes = true
            allRows.append(rowValues)
            if allRows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
        }

        if !didReadTypes {
            columnTypeNames = Array(repeating: "unknown", count: columns.count)
        }

        return OracleQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: allRows,
            affectedRows: allRows.count,
            isTruncated: truncated
        )
    }

    // MARK: - Streaming Query

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            try await withQueryDeadline { [self] in
                try await streamRows(query, on: connection, continuation: continuation)
            }
            await queryGate.release()
            continuation.finish()
        } catch {
            await queryGate.release()
            throw mapExecutionError(error)
        }
    }

    private func streamRows(
        _ query: String,
        on connection: OracleNIO.OracleConnection,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, logger: nioLogger)

        var columns: [String] = []
        for col in stream.columns {
            columns.append(col.name)
        }

        var columnTypeNames: [String] = []
        var headerSent = false

        for try await row in stream {
            try Task.checkCancellation()

            var rowValues: [PluginCellValue] = []
            for cell in row {
                if !headerSent {
                    columnTypeNames.append(oracleTypeName(cell.dataType))
                }
                if cell.bytes == nil {
                    rowValues.append(.null)
                } else if cell.dataType == .raw || cell.dataType == .longRAW || cell.dataType == .blob,
                          let bytes = cell.bytes {
                    rowValues.append(.bytes(Data(bytes.readableBytesView)))
                } else {
                    rowValues.append(PluginCellValue.fromOptional(decodeCell(cell)))
                }
            }

            if !headerSent {
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: columnTypeNames
                )))
                headerSent = true
            }

            continuation.yield(.rows([rowValues]))
        }

        if !headerSent {
            columnTypeNames = Array(repeating: "unknown", count: columns.count)
            continuation.yield(.header(PluginStreamHeader(
                columns: columns,
                columnTypeNames: columnTypeNames
            )))
        }
    }

    // MARK: - Cell Decoding

    private let unsupportedWarner = UnsupportedTypeWarner()

    private func decodeCell(_ cell: OracleCell) -> String? {
        guard cell.bytes != nil else { return nil }

        do {
            switch cell.dataType {
            case .varchar, .nVarchar, .char, .nChar, .long, .longNVarchar,
                 .clob, .nCLOB, .json, .rowID:
                return try cell.decode(String.self)

            case .number, .binaryInteger:
                return Self.decodeNumber(cell)

            case .binaryFloat:
                return String(try cell.decode(Float.self))

            case .binaryDouble:
                return String(try cell.decode(Double.self))

            case .boolean:
                return try cell.decode(Bool.self) ? "true" : "false"

            case .date:
                return OracleCellFormatting.formatDate(try cell.decode(Date.self))

            case .timestamp:
                return OracleCellFormatting.formatTimestamp(try cell.decode(Date.self), style: .utc)

            case .timestampLTZ, .timestampTZ:
                return OracleCellFormatting.formatTimestamp(try cell.decode(Date.self), style: .local)

            case .intervalDS:
                let interval = try cell.decode(IntervalDS.self)
                return OracleCellFormatting.formatIntervalDS(
                    days: interval.days,
                    hours: interval.hours,
                    minutes: interval.minutes,
                    seconds: interval.seconds,
                    nanoseconds: interval.fractionalSeconds
                )

            case .intervalYM:
                let interval = try cell.decode(IntervalYM.self)
                return OracleCellFormatting.formatIntervalYM(
                    years: interval.years,
                    months: interval.months
                )

            case .raw, .longRAW, .blob:
                return Self.hexEncode(cell.bytes)

            case .bFile:
                return "<bfile>"

            case .cursor:
                return "<cursor>"

            case .vector:
                return "<vector>"

            default:
                return unsupportedPlaceholder(for: cell.dataType)
            }
        } catch {
            osLogger.error("Oracle decode failed for column '\(cell.columnName)' type \(self.oracleTypeName(cell.dataType)): \(String(describing: error))")
            return "<decode error>"
        }
    }

    private func unsupportedPlaceholder(for type: OracleDataType) -> String {
        let name = oracleTypeName(type)
        let warner = unsupportedWarner
        Task.detached {
            if await warner.warnIfNew(name) {
                osLogger.warning("Oracle column type '\(name)' is not supported; rendering as placeholder")
            }
        }
        return OracleCellFormatting.unsupportedPlaceholder(typeName: name)
    }

    private static func hexEncode(_ buffer: ByteBuffer?) -> String? {
        guard var copy = buffer else { return nil }
        let total = copy.readableBytes
        guard let bytes = copy.readBytes(length: total) else { return nil }
        return OracleCellFormatting.hexEncode(bytes)
    }

    private static func decodeNumber(_ cell: OracleCell) -> String? {
        if let value = try? cell.decode(Int.self) {
            return String(value)
        }
        if let value = try? cell.decode(OracleNumber.self) {
            return value.description
        }
        if let value = try? cell.decode(Double.self) {
            return String(value)
        }
        return nil
    }

    private func oracleTypeName(_ dataType: OracleDataType) -> String {
        if dataType == .varchar { return "varchar2" }
        if dataType == .number { return "number" }
        if dataType == .binaryFloat { return "binary_float" }
        if dataType == .binaryDouble { return "binary_double" }
        if dataType == .date { return "date" }
        if dataType == .raw { return "raw" }
        if dataType == .longRAW { return "long raw" }
        if dataType == .char { return "char" }
        if dataType == .nChar { return "nchar" }
        if dataType == .nVarchar { return "nvarchar2" }
        if dataType == .nCLOB { return "nclob" }
        if dataType == .clob { return "clob" }
        if dataType == .blob { return "blob" }
        if dataType == .bFile { return "bfile" }
        if dataType == .timestamp { return "timestamp" }
        if dataType == .timestampTZ { return "timestamp with time zone" }
        if dataType == .timestampLTZ { return "timestamp with local time zone" }
        if dataType == .intervalDS { return "interval day to second" }
        if dataType == .intervalYM { return "interval year to month" }
        if dataType == .rowID { return "rowid" }
        if dataType == .boolean { return "boolean" }
        if dataType == .long { return "long" }
        if dataType == .json { return "json" }
        if dataType == .vector { return "vector" }
        if dataType == .binaryInteger { return "binary_integer" }
        return "unknown"
    }
}
