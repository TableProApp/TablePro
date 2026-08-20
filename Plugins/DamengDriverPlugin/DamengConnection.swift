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

    private let queue = DispatchQueue(label: "com.TablePro.dameng.connection", qos: .userInitiated)
    private let stateLock = NSLock()
    private var rawConnection: OpaquePointer?
    private var queryTimeoutSeconds = 0
    private var tickets = DamengStatementTickets()

    /// Fences a connect against every state change that happened while it was in flight.
    /// DM8 connect is several round trips, so a disconnect can land first, and adopting
    /// afterwards would revive a connection the caller already closed.
    private var epoch: UInt64 = 0

    deinit {
        let handle = rawConnection
        let cleanupQueue = queue
        rawConnection = nil
        if let handle {
            cleanupQueue.async { tp_dm_disconnect(handle) }
        }
    }

    func connect(host: String, port: Int, username: String, password: String) async throws {
        guard let port = UInt16(exactly: port), port > 0 else {
            throw DamengError(message: String(localized: "The Dameng port must be between 1 and 65535."))
        }
        let attempt = invalidateAttempts()
        try await run {
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
                throw Self.failure(from: rawError)
            }
            guard self.adopt(connection, attempt: attempt) else {
                tp_dm_disconnect(connection)
                throw DamengError(
                    message: String(localized: "The Dameng connection is closed."),
                    closedConnection: true
                )
            }
        }
    }

    func disconnect() {
        invalidateAttempts()
    }

    /// Stops an in-flight statement. The bridge abandons the server's reply mid-message and
    /// closes the connection, so every later call on it reports a closed connection until the
    /// driver reconnects.
    func cancelInFlightStatement() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let handle = rawConnection else { return }
        tp_dm_cancel(handle)
    }

    func applyQueryTimeout(seconds: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        queryTimeoutSeconds = max(0, seconds)
    }

    private func timeoutMilliseconds() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return UInt64(queryTimeoutSeconds) * 1_000
    }

    static func fetchLimit(_ rowCap: Int?) -> Int {
        guard let rowCap, rowCap > 0 else { return PluginRowLimits.emergencyMax }
        return min(rowCap, PluginRowLimits.emergencyMax)
    }

    /// Retires a handle a failure already closed.
    ///
    /// The epoch is deliberately untouched: nothing asked the driver to stop, so a reconnect
    /// already in flight keeps its claim. Bumping here let a second statement failing on the
    /// same dead connection cancel the rebuild that was recovering it, which is the case with
    /// two tabs loading at once.
    private func retireHandle() {
        stateLock.lock()
        let handle = rawConnection
        rawConnection = nil
        stateLock.unlock()
        dispose(handle)
    }

    /// Ends the current handle and every attempt still in flight, which is what a disconnect
    /// and the start of a fresh connect both mean. Returns the epoch a connect must still own
    /// to adopt, so it survives the several round trips DM8 needs.
    @discardableResult
    private func invalidateAttempts() -> UInt64 {
        stateLock.lock()
        let handle = rawConnection
        rawConnection = nil
        epoch &+= 1
        tickets.reset()
        let attempt = epoch
        stateLock.unlock()
        dispose(handle)
        return attempt
    }

    /// Closes a handle no caller can still be holding.
    ///
    /// `tp_dm_disconnect` frees the box `tp_dm_cancel` reads its interrupt from, so the two must
    /// not overlap. The pointer is cleared under `stateLock` before this runs and the cancel path
    /// reads it under the same lock, so a cancellation either completed before the clear or finds
    /// nothing. The close itself stays outside the lock: it writes to the socket and waits for the
    /// reply, and holding a lock across that would let a silent server block Stop and Disconnect.
    private func dispose(_ handle: OpaquePointer?) {
        guard let handle else { return }
        queue.async { tp_dm_disconnect(handle) }
    }

    private func adopt(_ connection: OpaquePointer, attempt: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard epoch == attempt, rawConnection == nil else { return false }
        rawConnection = connection
        return true
    }

    /// The bridge already closed its client, so the handle is retired here to keep the Swift
    /// state honest. Without this every later call reported a closed connection forever, and
    /// nothing above could tell that from a server rejecting the statement.
    ///
    /// A stop counts too: DM8 has no out-of-band cancel, so interrupting the read abandons the
    /// reply mid-message and the bridge closes the client for the same reason.
    private func releaseIfConnectionLost(_ error: any Error) {
        let lost = error is CancellationError || (error as? DamengError)?.closedConnection == true
        guard lost else { return }
        retireHandle()
    }

    func ping() async throws {
        try await run {
            let connection = try self.connectedPointer()
            var rawError: OpaquePointer?
            guard tp_dm_ping(connection, &rawError) else {
                throw Self.failure(from: rawError)
            }
        }
    }

    func execute(_ query: String, expectsRows: Bool, rowCap: Int?) async throws -> DamengRawResult {
        let timeout = timeoutMilliseconds()
        return try await run {
            let connection = try self.connectedPointer()
            var rawError: OpaquePointer?
            let rawResult = query.withUTF8Bytes { bytes in
                tp_dm_execute(
                    connection,
                    bytes.baseAddress,
                    bytes.count,
                    expectsRows,
                    Self.fetchLimit(rowCap),
                    timeout,
                    &rawError
                )
            }
            guard let rawResult else {
                throw Self.failure(from: rawError)
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
                throw Self.failure(from: rawError)
            }
        }
    }

    private func connectedPointer() throws -> OpaquePointer {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let rawConnection else {
            throw DamengError(
                message: String(localized: "The Dameng connection is closed."),
                closedConnection: true
            )
        }
        return rawConnection
    }

    /// Each call takes a ticket so a cancellation reaches its own statement and no other.
    /// The connection-wide interrupt is only fired for the statement actually on the wire;
    /// one still queued behind it is dropped without touching the connection.
    private func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let ticket = issueTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.beginExecuting(ticket) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let outcome = Result(catching: operation)
                    if case .failure(let error) = outcome {
                        self.releaseIfConnectionLost(error)
                    }
                    // Retired before the caller resumes, so a cancellation arriving late
                    // cannot fire the connection-wide interrupt for a finished statement.
                    self.finishExecuting(ticket)
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            self.cancel(ticket)
        }
    }

    private func issueTicket() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tickets.issue()
    }

    private func beginExecuting(_ ticket: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tickets.beginExecuting(ticket)
    }

    private func finishExecuting(_ ticket: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        tickets.finishExecuting(ticket)
    }

    /// Held across the interrupt rather than around the pointer read, because the handle can
    /// be freed in between. `tp_dm_cancel` only stores a flag, so the lock is held briefly.
    private func cancel(_ ticket: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard tickets.cancel(ticket) == .interruptConnection, let handle = rawConnection else {
            return
        }
        tp_dm_cancel(handle)
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

    /// A statement the caller stopped surfaces as `CancellationError`, so the app reports a
    /// cancelled query instead of an error the user did not cause. Everything else carries
    /// whether the connection survived, which decides whether the driver may reconnect and
    /// retry or has to report the failure.
    private static func failure(from pointer: OpaquePointer?) -> any Error {
        guard let pointer else {
            return DamengError(message: String(localized: "The Dameng operation failed."))
        }
        defer { tp_dm_error_free(pointer) }
        if tp_dm_error_is_cancellation(pointer) {
            return CancellationError()
        }
        let closedConnection = tp_dm_error_is_connection_lost(pointer)
        var length = 0
        guard let bytes = tp_dm_error_message(pointer, &length),
              let message = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            return DamengError(
                message: String(localized: "The Dameng operation failed."),
                closedConnection: closedConnection
            )
        }
        return DamengError(message: message, closedConnection: closedConnection)
    }
}

private extension String {
    func withUTF8Bytes<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try Array(utf8).withUnsafeBufferPointer(body)
    }
}
