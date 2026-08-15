import CDameng
import Foundation
import TableProPluginKit

struct DamengRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

final class DamengConnection: @unchecked Sendable {
    private enum TransactionCommand: Sendable {
        case begin
        case commit
        case rollback
    }

    private let queue = DispatchQueue(label: "com.TablePro.dameng.connection")
    private var rawConnection: OpaquePointer?

    deinit {
        if let rawConnection {
            tp_dm_disconnect(rawConnection)
        }
    }

    func connect(host: String, port: Int, username: String, password: String) async throws {
        guard let port = UInt16(exactly: port), port > 0 else {
            throw DamengError(message: String(localized: "The Dameng port must be between 1 and 65535."))
        }
        try await run {
            guard self.rawConnection == nil else { return }
            var rawError: OpaquePointer?
            let connection = host.withUTF8Bytes { hostBytes in
                username.withUTF8Bytes { usernameBytes in
                    password.withUTF8Bytes { passwordBytes in
                        tp_dm_connect(
                            hostBytes.baseAddress,
                            hostBytes.count,
                            port,
                            usernameBytes.baseAddress,
                            usernameBytes.count,
                            passwordBytes.baseAddress,
                            passwordBytes.count,
                            &rawError
                        )
                    }
                }
            }
            guard let connection else {
                throw Self.error(from: rawError)
            }
            self.rawConnection = connection
        }
    }

    func disconnect() {
        queue.sync {
            guard let rawConnection else { return }
            tp_dm_disconnect(rawConnection)
            self.rawConnection = nil
        }
    }

    func ping() async throws {
        try await run {
            let connection = try self.connectedPointer()
            var rawError: OpaquePointer?
            guard tp_dm_ping(connection, &rawError) else {
                throw Self.error(from: rawError)
            }
        }
    }

    func execute(_ query: String, expectsRows: Bool, rowCap: Int?) async throws -> DamengRawResult {
        try await run {
            let connection = try self.connectedPointer()
            var rawError: OpaquePointer?
            let rawResult = query.withUTF8Bytes { bytes in
                tp_dm_execute(
                    connection,
                    bytes.baseAddress,
                    bytes.count,
                    expectsRows,
                    max(rowCap ?? 0, 0),
                    &rawError
                )
            }
            guard let rawResult else {
                throw Self.error(from: rawError)
            }
            defer { tp_dm_result_free(rawResult) }
            return try Self.decode(rawResult)
        }
    }

    func beginTransaction() async throws {
        try await transactionOperation(.begin)
    }

    func commitTransaction() async throws {
        try await transactionOperation(.commit)
    }

    func rollbackTransaction() async throws {
        try await transactionOperation(.rollback)
    }

    private func transactionOperation(_ command: TransactionCommand) async throws {
        try await run {
            let connection = try self.connectedPointer()
            var rawError: OpaquePointer?
            let succeeded = switch command {
            case .begin:
                tp_dm_begin(connection, &rawError)
            case .commit:
                tp_dm_commit(connection, &rawError)
            case .rollback:
                tp_dm_rollback(connection, &rawError)
            }
            guard succeeded else {
                throw Self.error(from: rawError)
            }
        }
    }

    private func connectedPointer() throws -> OpaquePointer {
        guard let rawConnection else {
            throw DamengError(message: String(localized: "The Dameng connection is closed."))
        }
        return rawConnection
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decode(_ result: OpaquePointer) throws -> DamengRawResult {
        let columnCount = tp_dm_result_column_count(result)
        let rowCount = tp_dm_result_row_count(result)
        let columns = try (0..<columnCount).map { index in
            try string(result: result, column: index, reader: tp_dm_result_column_name)
        }
        let columnTypeNames = try (0..<columnCount).map { index in
            try string(result: result, column: index, reader: tp_dm_result_column_type)
        }
        let rows = try (0..<rowCount).map { rowIndex in
            try (0..<columnCount).map { columnIndex in
                try cell(result: result, row: rowIndex, column: columnIndex)
            }
        }
        let affected = tp_dm_result_rows_affected(result)
        return DamengRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: affected > UInt64(Int.max) ? Int.max : Int(affected),
            executionTime: tp_dm_result_execution_time(result),
            isTruncated: tp_dm_result_is_truncated(result)
        )
    }

    private static func string(
        result: OpaquePointer,
        column: Int,
        reader: (OpaquePointer?, Int, UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>?
    ) throws -> String {
        var length = 0
        guard let bytes = reader(result, column, &length),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw DamengError(message: String(localized: "Dameng returned invalid UTF-8 metadata."))
        }
        return value
    }

    private static func cell(result: OpaquePointer, row: Int, column: Int) throws -> PluginCellValue {
        switch tp_dm_result_cell_kind(result, row, column) {
        case 0:
            return .null
        case 1:
            let data = try cellData(result: result, row: row, column: column)
            guard let value = String(data: data, encoding: .utf8) else {
                throw DamengError(message: String(localized: "Dameng returned invalid UTF-8 text."))
            }
            return .text(value)
        case 2:
            return .bytes(try cellData(result: result, row: row, column: column))
        default:
            throw DamengError(message: String(localized: "Dameng returned an invalid result cell."))
        }
    }

    private static func cellData(result: OpaquePointer, row: Int, column: Int) throws -> Data {
        var length = 0
        guard let bytes = tp_dm_result_cell_bytes(result, row, column, &length) else {
            throw DamengError(message: String(localized: "Dameng returned an invalid result value."))
        }
        return Data(bytes: bytes, count: length)
    }

    private static func error(from pointer: OpaquePointer?) -> DamengError {
        guard let pointer else {
            return DamengError(message: String(localized: "The Dameng operation failed."))
        }
        defer { tp_dm_error_free(pointer) }
        var length = 0
        guard let bytes = tp_dm_error_message(pointer, &length),
              let message = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            return DamengError(message: String(localized: "The Dameng operation failed."))
        }
        return DamengError(message: message)
    }
}

private extension String {
    func withUTF8Bytes<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try Array(utf8).withUnsafeBufferPointer(body)
    }
}
