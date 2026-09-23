//
//  SQLiteAgentBackend.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Runs a SQLite driver's statements on an SSH server through the Python agent, over a loopback
/// socket the app's transport hands to a fresh exec channel per connection.
///
/// The backend speaks the framed protocol in `SQLiteAgentProtocol`. It owns one socket, a reader
/// thread that assembles reply frames, and a heartbeat that keeps the agent's watchdog from
/// reaping the session. The database, every value and every statement travel as protocol fields;
/// the exec command line the server runs carries none of them.
actor SQLiteAgentBackend: SQLiteExecutionBackend {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteAgentBackend")

    private let connection: SQLiteAgentConnection
    private let path: String
    private let token: String
    private var busyTimeoutMilliseconds: Int32 = 0

    nonisolated let canceller: SQLiteCanceller
    nonisolated var resolvedServerVersion: String? { connection.cachedServerVersion }

    init(host: String, port: Int, path: String, token: String) {
        let connection = SQLiteAgentConnection(host: host, port: port)
        self.connection = connection
        self.path = path
        self.token = token
        self.canceller = SQLiteRemoteCanceller(connection: connection)
    }

    /// Extensions are files on this Mac and the statements run on the server, so a list here has
    /// nothing it could load into.
    func open(loading extensions: [LoadableExtension]) async throws {
        guard extensions.isEmpty else { throw LoadableExtensionError.remoteSession }
        try connection.connect(token: token)
        let ready = try await connection.hello(
            path: path,
            busyTimeoutMilliseconds: UInt32(max(0, busyTimeoutMilliseconds))
        )
        connection.cachedServerVersion = ready.sqliteVersion
        Self.logger.info(
            "Remote SQLite agent ready: SQLite \(ready.sqliteVersion, privacy: .public), Python \(ready.pythonVersion, privacy: .public)"
        )
    }

    func close() {
        connection.close()
    }

    nonisolated func abortConnect() {
        connection.close()
    }

    func applyBusyTimeout(_ milliseconds: Int32) {
        busyTimeoutMilliseconds = milliseconds
        connection.setBusyTimeout(UInt32(max(0, milliseconds)))
    }

    func executeQuery(_ query: String) async throws -> SQLiteRawResult {
        try await run(query, parameters: [])
    }

    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) async throws -> SQLiteRawResult {
        try await run(query, parameters: parameters.map(Self.encode))
    }

    private func run(_ query: String, parameters: [SQLiteAgentValue]) async throws -> SQLiteRawResult {
        let startTime = Date()
        let accumulator = SQLiteAgentResultAccumulator()

        let outcome = try await withTaskCancellationHandler {
            try await connection.execute(
                sql: query,
                parameters: parameters,
                // The buffered path holds the whole result in memory, so it takes the same emergency
                // ceiling the local backend applies; the streaming path below stays uncapped.
                rowCap: UInt32(clamping: PluginRowLimits.emergencyMax),
                onHeader: { header in accumulator.setHeader(header) },
                onRows: { columnCount, values in
                    guard columnCount > 0 else { return }
                    var rows: [[PluginCellValue]] = []
                    var index = 0
                    while index < values.count {
                        rows.append(values[index..<(index + columnCount)].map(Self.decode))
                        index += columnCount
                    }
                    accumulator.appendRows(rows)
                }
            )
        } onCancel: {
            connection.sendCancel()
        }

        let (columns, columnTypeNames, rows) = accumulator.snapshot()
        return SQLiteRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: columns.isEmpty ? Int(outcome.changes) : 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: outcome.truncated
        )
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        _ = try await withTaskCancellationHandler {
            try await connection.execute(
                sql: query,
                parameters: [],
                rowCap: 0,
                onHeader: { header in
                    continuation.yield(.header(PluginStreamHeader(
                        columns: header.map(\.name),
                        columnTypeNames: header.map { $0.declaredType ?? "" },
                        estimatedRowCount: nil
                    )))
                },
                onRows: { columnCount, values in
                    guard columnCount > 0 else { return }
                    var batch: [PluginRow] = []
                    var index = 0
                    while index < values.count {
                        batch.append(values[index..<(index + columnCount)].map(Self.decode))
                        index += columnCount
                    }
                    continuation.yield(.rows(batch))
                }
            )
        } onCancel: {
            connection.sendCancel()
        }
        continuation.finish()
    }

    private static func encode(_ value: PluginCellValue) -> SQLiteAgentValue {
        switch value {
        case .null: return .null
        case .text(let string): return .text(Data(string.utf8))
        case .bytes(let data): return .blob(data)
        }
    }

    /// The agent renders integers and reals as their SQLite text form, exactly as the local backend
    /// reads them through `sqlite3_column_text`, so a value reads the same whichever backend served
    /// it. Only NULL and BLOB are distinct types on the wire.
    private static func decode(_ value: SQLiteAgentValue) -> PluginCellValue {
        switch value {
        case .null: return .null
        // swiftlint:disable:next optional_data_string_conversion
        case .text(let data): return .text(String(decoding: data, as: UTF8.self))
        case .blob(let data): return .bytes(data)
        }
    }
}

/// Collects a buffered result as the reader thread delivers header and row frames. The frames for
/// one statement arrive in order on that one thread, and the awaiting caller reads the snapshot only
/// after the statement's done frame has resumed it; the lock is there so the `@Sendable` callbacks
/// are safe by construction rather than by that argument alone.
final class SQLiteAgentResultAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var columns: [String] = []
    private var columnTypeNames: [String] = []
    private var rows: [[PluginCellValue]] = []

    func setHeader(_ header: [SQLiteAgentColumn]) {
        lock.lock()
        defer { lock.unlock() }
        columns = header.map(\.name)
        columnTypeNames = header.map { $0.declaredType ?? "" }
    }

    func appendRows(_ newRows: [[PluginCellValue]]) {
        lock.lock()
        defer { lock.unlock() }
        rows.append(contentsOf: newRows)
    }

    func snapshot() -> (columns: [String], columnTypeNames: [String], rows: [[PluginCellValue]]) {
        lock.lock()
        defer { lock.unlock() }
        return (columns, columnTypeNames, rows)
    }
}

/// Writes a cancel frame to the agent from the Stop button, without waiting on the backend actor.
final class SQLiteRemoteCanceller: SQLiteCanceller, @unchecked Sendable {
    private let connection: SQLiteAgentConnection

    init(connection: SQLiteAgentConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.sendCancel()
    }
}

struct SQLiteAgentReady: Sendable {
    let sqliteVersion: String
    let pythonVersion: String
}

struct SQLiteAgentExecuteOutcome: Sendable {
    let changes: Int64
    let truncated: Bool
}

/// The socket, the reader thread, and the framed protocol conversation with one agent.
///
/// Reads block on a dedicated thread that assembles frames and routes them to the one operation in
/// flight; the backend actor runs at most one at a time. Writes are serialized under a lock, so
/// the reader thread's cancel and heartbeat frames never interleave with a partial request.
final class SQLiteAgentConnection: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteAgentConnection")
    private static let readyTimeout: TimeInterval = 30
    private static let heartbeatInterval: TimeInterval = 15

    private let host: String
    private let port: Int

    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var pending: SQLiteAgentOperation?
    private var terminalFailure: Error?
    private var closed = false

    private let writeLock = NSLock()
    private var reader = SQLiteAgentFrameReader()
    private var readerThread: Thread?
    private var heartbeatTimer: DispatchSourceTimer?

    private let versionLock = NSLock()
    private var _cachedServerVersion: String?
    var cachedServerVersion: String? {
        get { versionLock.lock(); defer { versionLock.unlock() }; return _cachedServerVersion }
        set { versionLock.lock(); _cachedServerVersion = newValue; versionLock.unlock() }
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func connect(token: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SQLitePluginError.connectionFailed("could not create a local socket") }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            throw SQLitePluginError.connectionFailed("could not reach the remote SQLite session")
        }

        stateLock.lock()
        socketFD = fd
        closed = false
        stateLock.unlock()

        try writeAll(SQLiteAgentProtocol.admissionPreamble(token: token))

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "com.TablePro.sqlite.agent-reader"
        thread.stackSize = 512 * 1_024
        readerThread = thread
        thread.start()
    }

    func hello(path: String, busyTimeoutMilliseconds: UInt32) async throws -> SQLiteAgentReady {
        let request = SQLiteAgentRequest.hello(
            protocolVersion: SQLiteAgentProtocol.version,
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        let ready: SQLiteAgentReady = try await withOperation(deadline: Self.readyTimeout) { _ in
            try self.writeAll(SQLiteAgentFrameEncoder.encode(request))
        }
        startHeartbeat()
        return ready
    }

    func execute(
        sql: String,
        parameters: [SQLiteAgentValue],
        rowCap: UInt32,
        onHeader: @escaping (@Sendable ([SQLiteAgentColumn]) -> Void),
        onRows: @escaping (@Sendable (Int, [SQLiteAgentValue]) -> Void)
    ) async throws -> SQLiteAgentExecuteOutcome {
        let request = SQLiteAgentRequest.execute(sql: sql, parameters: parameters, rowCap: rowCap)
        return try await withOperation(deadline: nil) { operation in
            operation.onHeader = onHeader
            operation.onRows = onRows
            try self.writeAll(SQLiteAgentFrameEncoder.encode(request))
        }
    }

    func setBusyTimeout(_ milliseconds: UInt32) {
        try? writeAll(SQLiteAgentFrameEncoder.encode(.setBusyTimeout(milliseconds: milliseconds)))
    }

    func sendCancel() {
        try? writeAll(SQLiteAgentFrameEncoder.encode(.cancel))
    }

    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let fd = socketFD
        socketFD = -1
        let inflight = pending
        pending = nil
        stateLock.unlock()

        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        inflight?.fail(SQLitePluginError.notConnected)
    }

    // MARK: - Operation lifecycle

    private func withOperation<T: Sendable>(
        deadline: TimeInterval?,
        _ send: @escaping (SQLiteAgentOperation) throws -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let operation = SQLiteAgentOperation { result in
                switch result {
                case .success(let value):
                    if let typed = value as? T {
                        continuation.resume(returning: typed)
                    } else {
                        continuation.resume(throwing: SQLitePluginError.queryFailed("unexpected reply from the remote SQLite session"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            stateLock.lock()
            if closed {
                stateLock.unlock()
                continuation.resume(throwing: SQLitePluginError.notConnected)
                return
            }
            /// A terminal reply that arrived before this operation registered, such as the launcher's
            /// "no python3" notice landing before the hello op was set, is delivered to this
            /// operation rather than lost. The reader thread stores it under the same lock, so the
            /// two orderings, store-then-register and register-then-route, both reach here correctly.
            if let stored = terminalFailure {
                terminalFailure = nil
                stateLock.unlock()
                operation.fail(stored)
                return
            }
            pending = operation
            stateLock.unlock()

            if let deadline {
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in
                    self?.failIfPending(operation, error: SQLitePluginError.connectionFailed("the remote SQLite session did not answer"))
                }
            }

            do {
                try send(operation)
            } catch {
                failIfPending(operation, error: error)
            }
        }
    }

    private func failIfPending(_ operation: SQLiteAgentOperation, error: Error) {
        stateLock.lock()
        guard pending === operation else { stateLock.unlock(); return }
        pending = nil
        stateLock.unlock()
        operation.fail(error)
    }

    private func completePending(_ complete: (SQLiteAgentOperation) -> Void) {
        stateLock.lock()
        let operation = pending
        pending = nil
        stateLock.unlock()
        guard let operation else { return }
        complete(operation)
    }

    /// Delivers a terminal failure to the pending operation, or stores the first one for the next
    /// operation to register when none is in flight yet. This is what keeps the launcher's
    /// "no python3" notice from being lost when it arrives before the hello op is set.
    private func completeOrStoreFailure(_ error: Error) {
        stateLock.lock()
        if let operation = pending {
            pending = nil
            stateLock.unlock()
            operation.fail(error)
            return
        }
        if terminalFailure == nil { terminalFailure = error }
        stateLock.unlock()
    }

    // MARK: - Reader

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            stateLock.lock()
            let fd = socketFD
            let isClosed = closed
            stateLock.unlock()
            guard !isClosed, fd >= 0 else { break }

            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reader.append(Data(buffer[0..<count]))

            do {
                while let reply = try reader.nextReply() {
                    route(reply)
                }
            } catch {
                completeOrStoreFailure(SQLitePluginError.queryFailed("the remote SQLite session sent malformed data"))
                break
            }
        }
        completeOrStoreFailure(SQLitePluginError.notConnected)
    }

    private func route(_ reply: SQLiteAgentReply) {
        switch reply {
        case .ready(_, let sqliteVersion, let pythonVersion):
            completePending { $0.succeed(SQLiteAgentReady(sqliteVersion: sqliteVersion, pythonVersion: pythonVersion)) }
        case .failure(let failure):
            completeOrStoreFailure(SQLitePluginError.connectionFailed(failure.message))
        case .launcherNotice(let notice):
            let message = notice == SQLiteAgentProtocol.noPythonNotice
                ? "the server has no python3 to run the remote SQLite session"
                : notice
            completeOrStoreFailure(SQLitePluginError.connectionFailed(message))
        case .header(let columns):
            currentOperation?.onHeader?(columns)
        case .rows(let columnCount, let values):
            currentOperation?.onRows?(columnCount, values)
        case .done(let changes, let truncated):
            completePending { $0.succeed(SQLiteAgentExecuteOutcome(changes: changes, truncated: truncated)) }
        case .error(_, let message):
            completePending { $0.fail(SQLitePluginError.queryFailed(message)) }
        }
    }

    private var currentOperation: SQLiteAgentOperation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { @Sendable [weak self] in
            self?.sendHeartbeat()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func sendHeartbeat() {
        try? writeAll(SQLiteAgentFrameEncoder.encode(.heartbeat))
    }

    // MARK: - Writing

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        stateLock.lock()
        let fd = socketFD
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed, fd >= 0 else { throw SQLitePluginError.notConnected }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { throw SQLitePluginError.notConnected }
                offset += written
            }
        }
    }
}

/// One request/response exchange with the agent. The reader thread drives its callbacks and
/// completes it exactly once, whichever of a done frame, an error frame, a timeout or a socket
/// close arrives first.
final class SQLiteAgentOperation: @unchecked Sendable {
    private let completion: (Result<Any, Error>) -> Void
    private let lock = NSLock()
    private var finished = false

    var onHeader: (@Sendable ([SQLiteAgentColumn]) -> Void)?
    var onRows: (@Sendable (Int, [SQLiteAgentValue]) -> Void)?

    init(completion: @escaping (Result<Any, Error>) -> Void) {
        self.completion = completion
    }

    func succeed(_ value: Any) {
        guard claim() else { return }
        completion(.success(value))
    }

    func fail(_ error: Error) {
        guard claim() else { return }
        completion(.failure(error))
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
