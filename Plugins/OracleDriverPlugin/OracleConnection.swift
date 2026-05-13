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
        case authVerifierUnsupported(flag: String)
        case authVersionNotSupported
        case authConnectionDropped
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

    private struct LockedState: Sendable {
        var isConnected = false
        var nioConnection: OracleNIO.OracleConnection?
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())
    private let nioLogger = Logging.Logger(label: "com.TablePro.oracle-nio")

    var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    // MARK: - Initialization

    init(host: String, port: Int, user: String, password: String, database: String, serviceName: String = "") {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.serviceName = serviceName
    }

    // MARK: - Connection

    func connect() async throws {
        let service = serviceName.isEmpty ? database : serviceName
        let config = OracleNIO.OracleConnection.Configuration(
            host: host,
            port: port,
            service: .serviceName(service),
            username: user,
            password: password
        )

        let connectionId = Self.connectionCounter.withLock { state -> Int in
            state += 1
            return state
        }

        do {
            let connection = try await OracleNIO.OracleConnection.connect(
                configuration: config,
                id: connectionId,
                logger: nioLogger
            )

            state.withLock { current in
                current.nioConnection = connection
                current.isConnected = true
            }

            osLogger.debug("Connected to Oracle \(self.host):\(self.port)/\(service)")
        } catch let sqlError as OracleSQLError {
            let detail = sqlError.serverInfo?.message ?? sqlError.description
            osLogger.error("Oracle connection failed: \(detail)")
            throw OracleError(message: detail, category: classifyConnectError(sqlError))
        } catch {
            let detail = String(describing: error)
            osLogger.error("Oracle connection failed: \(detail)")
            throw OracleError(message: detail, category: .connectionFailed)
        }
    }

    private func classifyConnectError(_ error: OracleSQLError) -> OracleError.Category {
        let codeDescription = error.code.description
        if codeDescription.hasPrefix("unsupportedVerifierType") {
            return .authVerifierUnsupported(flag: codeDescription)
        }
        switch codeDescription {
        case "uncleanShutdown":
            return .authConnectionDropped
        case "serverVersionNotSupported":
            return .authVersionNotSupported
        default:
            return .connectionFailed
        }
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

    // MARK: - Query Execution

    func executeQuery(_ query: String) async throws -> OracleQueryResult {
        let connection = try state.withLock { current -> OracleNIO.OracleConnection in
            guard let conn = current.nioConnection, current.isConnected else {
                throw OracleError.notConnected
            }
            return conn
        }

        // OracleNIO does not support concurrent queries on a single connection.
        // Serialize all queries to prevent state-machine corruption.
        await queryGate.acquire()

        do {
            let statement = OracleStatement(stringLiteral: query)
            let stream = try await connection.execute(statement, logger: nioLogger)

            // Read column metadata from stream (available even with 0 rows)
            var columns: [String] = []
            for col in stream.columns {
                columns.append(col.name)
            }
            osLogger.debug("Oracle columns: \(columns.count) — \(columns.joined(separator: ", "))")

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

            await queryGate.release()
            return OracleQueryResult(
                columns: columns,
                columnTypeNames: columnTypeNames,
                rows: allRows,
                affectedRows: allRows.count,
                isTruncated: truncated
            )
        } catch let sqlError as OracleSQLError {
            let detail = sqlError.serverInfo?.message ?? sqlError.description
            await queryGate.release()
            throw OracleError(message: detail)
        } catch let error as OracleError {
            await queryGate.release()
            throw error
        } catch is CancellationError {
            await queryGate.release()
            throw CancellationError()
        } catch {
            await queryGate.release()
            throw OracleError(message: "Query execution failed: \(String(describing: error))")
        }
    }

    // MARK: - Streaming Query

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let connection = try state.withLock { current -> OracleNIO.OracleConnection in
            guard let conn = current.nioConnection, current.isConnected else {
                throw OracleError.notConnected
            }
            return conn
        }

        await queryGate.acquire()

        do {
            let statement = OracleStatement(stringLiteral: query)
            let stream = try await connection.execute(statement, logger: nioLogger)

            var columns: [String] = []
            for col in stream.columns {
                columns.append(col.name)
            }

            var columnTypeNames: [String] = []
            var headerSent = false

            for try await row in stream {
                if Task.isCancelled {
                    await queryGate.release()
                    continuation.finish(throwing: CancellationError())
                    return
                }

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

            await queryGate.release()
            continuation.finish()
        } catch let sqlError as OracleSQLError {
            let detail = sqlError.serverInfo?.message ?? sqlError.description
            await queryGate.release()
            throw OracleError(message: detail)
        } catch is CancellationError {
            await queryGate.release()
            throw CancellationError()
        } catch {
            await queryGate.release()
            throw OracleError(message: "Query execution failed: \(String(describing: error))")
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
