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
    let message: String

    static let notConnected = OracleError(message: String(localized: "Not connected to database"))
    static let connectionFailed = OracleError(message: String(localized: "Failed to establish connection"))
    static let queryFailed = OracleError(message: String(localized: "Query execution failed"))
}

extension OracleError: PluginDriverError {
    var pluginErrorMessage: String { message }
}

// MARK: - Query Result

struct OracleQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
    let isTruncated: Bool
}

// MARK: - Connection Class

final class OracleConnectionWrapper: @unchecked Sendable {
    // MARK: - Properties

    private static let connectionCounter = OSAllocatedUnfairLock(initialState: 0)

    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let serviceName: String

    private let lock = NSLock()
    private var _isConnected = false
    private var nioConnection: OracleNIO.OracleConnection?
    private let nioLogger = Logging.Logger(label: "com.TablePro.oracle-nio")

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
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

            lock.lock()
            nioConnection = connection
            _isConnected = true
            lock.unlock()

            osLogger.debug("Connected to Oracle \(self.host):\(self.port)/\(service)")
        } catch let sqlError as OracleSQLError {
            let detail = sqlError.serverInfo?.message ?? sqlError.description
            osLogger.error("Oracle connection failed: \(detail)")
            throw OracleError(message: "Failed to connect to \(host):\(port)/\(service): \(detail)")
        } catch {
            let detail = String(describing: error)
            osLogger.error("Oracle connection failed: \(detail)")
            throw OracleError(message: "Failed to connect to \(host):\(port)/\(service): \(detail)")
        }
    }

    func disconnect() {
        lock.lock()
        guard _isConnected else {
            lock.unlock()
            return
        }
        _isConnected = false
        let connection = nioConnection
        nioConnection = nil
        lock.unlock()

        Task {
            try? await connection?.close()
            osLogger.debug("Disconnected from Oracle \(self.host):\(self.port)")
        }
    }

    // MARK: - Query Execution

    func executeQuery(_ query: String) async throws -> OracleQueryResult {
        lock.lock()
        guard let connection = nioConnection, _isConnected else {
            lock.unlock()
            throw OracleError.notConnected
        }
        lock.unlock()

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
            var allRows: [[String?]] = []
            var didReadTypes = false
            var truncated = false

            for try await row in stream {
                var rowValues: [String?] = []
                for cell in row {
                    if !didReadTypes {
                        columnTypeNames.append(oracleTypeName(cell.dataType))
                    }
                    if cell.bytes == nil {
                        rowValues.append(nil)
                    } else {
                        rowValues.append(decodeCell(cell))
                    }
                }
                didReadTypes = true
                allRows.append(rowValues)
                if allRows.count >= PluginRowLimits.defaultMax {
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
        } catch let sqlError as OracleSQLError {
            let detail = sqlError.serverInfo?.message ?? sqlError.description
            throw OracleError(message: detail)
        } catch let error as OracleError {
            throw error
        } catch {
            throw OracleError(message: "Query execution failed: \(String(describing: error))")
        }
    }

    // MARK: - Private Helpers

    /// Decode an OracleCell to String, trying multiple type strategies.
    /// OracleNIO may fail to decode NUMBER as String directly.
    private func decodeCell(_ cell: OracleCell) -> String? {
        if let value = try? cell.decode(String.self) { return value }
        if let value = try? cell.decode(Int.self) { return String(value) }
        if let value = try? cell.decode(Double.self) { return String(value) }
        if let value = try? cell.decode(Bool.self) { return String(value) }
        // Last resort: read raw bytes as UTF-8
        if var buf = cell.bytes {
            return buf.readString(length: buf.readableBytes)
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
