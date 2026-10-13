import CLibPQ
import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery
import TableProSQLGrammar

nonisolated final class PostgreSQLDriver: DatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "PostgreSQLDriver")

    private let actor = PostgreSQLActor()
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let ssl: DriverSSLConfiguration
    let databaseType: DatabaseType

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    // Set once during connect()/switchSchema() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var currentSchema: String? = "public"
    nonisolated(unsafe) private(set) var serverVersion: String?
    nonisolated(unsafe) private(set) var serverVersionNumber: Int32 = 0
    nonisolated(unsafe) private(set) var catalogPresence = PostgreSQLDriver.presence(probedRows: nil)

    nonisolated(unsafe) var columnReadSupport = PostgreSQLColumnReadSupport()

    var effectiveSchema: String { currentSchema ?? "public" }

    init(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String,
        ssl: DriverSSLConfiguration = .disabled,
        databaseType: DatabaseType = .postgresql
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.ssl = ssl
        self.databaseType = databaseType
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(host: host, port: port, user: user, password: password, database: database, ssl: ssl)
        _ = try? await actor.execute("SET standard_conforming_strings = on")
        serverVersion = await actor.serverVersion()
        serverVersionNumber = await actor.serverVersionNumber()
        catalogPresence = await probeCatalogPresence()
        columnReadSupport = PostgreSQLColumnReadSupport()
        await adoptServerSchema()
    }

    private func probeCatalogPresence() async -> PostgreSQLCatalogPresence {
        guard databaseType != .redshift else { return Self.presence(probedRows: nil) }
        do {
            let rows = try await actor.execute(PostgreSQLCatalogPresence.probeQuery).rows
            return Self.presence(probedRows: rows)
        } catch {
            Self.logger.warning(
                "Catalog presence probe failed; listing without the optional catalogs: \(error.localizedDescription, privacy: .private)"
            )
            return Self.presence(probedRows: nil)
        }
    }

    private func adoptServerSchema() async {
        guard let schema = try? await actor.execute("SELECT current_schema()").rows.first?.first ?? nil,
              !schema.isEmpty else { return }
        currentSchema = schema
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        _ = try await actor.execute("SELECT 1")
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.execute(query)
        return QueryResult(
            columns: raw.columns.enumerated().map { i, name in
                ColumnInfo(
                    name: name,
                    typeName: i < raw.columnTypes.count ? raw.columnTypes[i] : "",
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: nil,
                    comment: nil,
                    characterMaxLength: nil,
                    ordinalPosition: i
                )
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated,
            statusMessage: nil
        )
    }

    /// Runs without the actor, which stays blocked in libpq for as long as the statement runs.
    func cancelCurrentQuery() async throws {
        actor.cancelHandle.cancelInFlight()
    }

    /// The query id is taken before the producer starts, so `onTermination` always knows which query
    /// is this stream's, and a consumer going away cancels that query and never another surface's.
    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        let cancelHandle = actor.cancelHandle
        let id = cancelHandle.reserveQuery()
        let readsOnly = !SQLWriteClassifier.isWriteQuery(query, databaseType: databaseType)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch try await actor.beginStream(query: query, id: id, readsOnly: readsOnly) {
                    case .commandOk(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                    case .tuples(let columns):
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(stream: id, options: options, columns: columns) else {
                                break
                            }
                            continuation.yield(.row(Row(cells: cells)))
                            emitted += 1
                        }
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                            try await actor.endStream(id)
                        } else if emitted >= options.maxRows {
                            continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                            try await actor.endStreamAtRowCap(id)
                        } else {
                            try await actor.endStream(id)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    try? await actor.endStream(id)
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    try? await actor.endStream(id)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    cancelHandle.cancel(id)
                }
            }
        }
    }

    // MARK: - Schema

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let raw = try await actor.execute(
            Self.foreignKeysQuery(
                schema: schema ?? effectiveSchema,
                table: table,
                serverVersionNumber: serverVersionNumber
            )
        )

        return PostgreSQLCatalogForeignKeys.foreignKeys(from: raw.rows).map { key in
            ForeignKeyInfo(
                name: key.name,
                column: key.column,
                referencedTable: key.referencedTable,
                referencedColumn: key.referencedColumn,
                referencedSchema: key.referencedSchema,
                onDelete: key.onDelete,
                onUpdate: key.onUpdate
            )
        }
    }

    static func foreignKeysQuery(schema: String, table: String, serverVersionNumber: Int32) -> String {
        PostgreSQLCatalogForeignKeys.query(
            schema: schema,
            table: table,
            excludesPartitionClones: PostgreSQLCatalogForeignKeys.excludesPartitionClones(
                serverVersionNumber: serverVersionNumber
            )
        )
    }

    func fetchDatabases() async throws -> [String] {
        let raw = try await actor.execute(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return raw.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        throw PostgreSQLError.unsupported("PostgreSQL requires a new connection to switch databases")
    }

    func switchSchema(to name: String) async throws {
        let safe = name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await actor.execute("SET search_path TO \"\(safe)\"")
        currentSchema = name
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")
        return result.rows.compactMap { $0.first ?? nil }
    }

    func beginTransaction() async throws {
        try await beginTransaction(mode: .serverDefault)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        _ = try await actor.execute(postgresBeginTransactionStatement(mode: mode))
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }

    func sessionTransactionState() async -> DriverTransactionState {
        await actor.transactionState()
    }

    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? {
        await actor.lexicalFacts()
    }
}

nonisolated enum PostgreSQLSessionTransaction {
    static func state(from status: PGTransactionStatusType) -> DriverTransactionState {
        switch status {
        case PQTRANS_IDLE:
            return .idle
        case PQTRANS_INTRANS, PQTRANS_INERROR, PQTRANS_ACTIVE:
            return .explicitTransaction
        default:
            return .unknown
        }
    }
}

// MARK: - PostgreSQL Actor (thread-safe C API access)

private actor PostgreSQLActor {
    nonisolated let cancelHandle = PostgreSQLCancelHandle()
    private var conn: OpaquePointer?

    private static let connectTimeout: TimeInterval = 15
    private static let pollSliceMilliseconds: Int32 = 100

    /// `PQconnectdb` blocks with no way to abort, so a cancelled connect can never stop dialing.
    func connect(host: String, port: Int, user: String, password: String, database: String, ssl: DriverSSLConfiguration = .disabled) async throws {
        guard (1...65_535).contains(port) else {
            throw PostgreSQLError.connectionFailed(
                "Port \(port) is out of range. Use a value between 1 and 65535."
            )
        }
        close()

        let connStr = PostgreSQLConnectionString.build(
            host: host,
            port: port,
            database: database,
            user: user,
            password: password,
            ssl: ssl
        )

        guard let connection = PQconnectStart(connStr) else {
            throw PostgreSQLError.connectionFailed(String(localized: "Could not start a connection."))
        }

        var adopted = false
        defer { if !adopted { PQfinish(connection) } }

        guard PQstatus(connection) != CONNECTION_BAD else {
            throw PostgreSQLError.connectionFailed(Self.message(from: connection))
        }

        try await pollUntilConnected(connection)

        self.conn = connection
        adopted = true
        cancelHandle.attach(PostgreSQLCancelKey(connection: connection))
    }

    private func pollUntilConnected(_ connection: OpaquePointer) async throws {
        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        var status = PGRES_POLLING_WRITING

        while true {
            try Task.checkCancellation()

            switch status {
            case PGRES_POLLING_OK:
                return
            case PGRES_POLLING_FAILED:
                throw PostgreSQLError.connectionFailed(Self.message(from: connection))
            case PGRES_POLLING_READING, PGRES_POLLING_WRITING:
                let socket = PQsocket(connection)
                guard socket >= 0 else {
                    throw PostgreSQLError.connectionFailed(Self.message(from: connection))
                }
                guard Date() < deadline else {
                    throw PostgreSQLError.connectionFailed(String(localized: "Connection timed out."))
                }

                let events = status == PGRES_POLLING_READING ? Int16(POLLIN) : Int16(POLLOUT)
                var descriptor = pollfd(fd: socket, events: events, revents: 0)
                let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)
                guard ready >= 0 else {
                    throw PostgreSQLError.connectionFailed(String(localized: "Connection failed while waiting on the socket."))
                }
                guard ready > 0 else { continue }

                status = PQconnectPoll(connection)
            default:
                status = PQconnectPoll(connection)
            }
        }
    }

    private static func message(from connection: OpaquePointer?) -> String {
        guard let connection else { return String(localized: "Unknown error") }
        let text = String(cString: PQerrorMessage(connection))
        return text.isEmpty ? String(localized: "Unknown error") : text
    }

    func close() {
        cancelHandle.detach()
        discardStream()
        if let conn {
            PQfinish(conn)
            self.conn = nil
        }
    }

    func serverVersionNumber() -> Int32 {
        guard let conn else { return 0 }
        return PQserverVersion(conn)
    }

    func transactionState() -> DriverTransactionState {
        guard let conn else { return .unknown }
        return PostgreSQLSessionTransaction.state(from: PQtransactionStatus(conn))
    }

    /// libpq keeps the value the server last reported in a `ParameterStatus`, so a `SET` the user ran is already in it.
    func lexicalFacts() -> SQLSessionLexicalFacts? {
        guard let conn, let reported = PQparameterStatus(conn, "standard_conforming_strings") else { return nil }
        let backslashEscapes = String(cString: reported) != "on"
        return SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: backslashEscapes ? .backslashEscapesInSingleQuotes : []
        )
    }

    func serverVersion() -> String? {
        guard let conn else { return nil }
        let version = PQserverVersion(conn)
        if version == 0 { return nil }
        let major = version / 10000 // swiftlint:disable:this number_separator
        let minor = (version / 100) % 100
        let patch = version % 100
        // PostgreSQL 10+ uses two-component versioning (major.patch)
        // PostgreSQL 9.x and earlier uses three-component versioning (major.minor.patch)
        if major >= 10 {
            return "\(major).\(patch)"
        }
        return "\(major).\(minor).\(patch)"
    }

    func execute(_ query: String) throws -> RawPGResult {
        endLeftoverStream()
        guard let conn else { throw PostgreSQLError.notConnected }

        let start = Date()
        let cancelsOutput = cancelsAbandonedOutput(conn)
        let id = cancelHandle.reserveQuery()
        cancelHandle.waitForPendingCancels()
        cancelHandle.querySent(id)
        defer { cancelHandle.queryFinished(id) }
        let result = PQexec(conn, query)
        defer {
            if result != nil { PQclear(result) }
        }

        let status = PQresultStatus(result)

        if let copy = result.flatMap(LibPQCopyState.copy(of:)) {
            _ = finishPendingResults(conn, cancellingOutput: cancelsOutput)
            throw PostgreSQLError.unsupported(copy.direction.unsupportedMessage)
        }

        if status == PGRES_FATAL_ERROR {
            if cancelHandle.isCancelled(id) { throw CancellationError() }
            let msg = result.flatMap { String(cString: PQresultErrorMessage($0)) } ?? "Unknown error"
            throw PostgreSQLError.queryFailed(msg)
        }

        if status == PGRES_COMMAND_OK {
            let affectedStr = result.flatMap { String(cString: PQcmdTuples($0)) } ?? "0"
            let affected = Int(affectedStr) ?? 0
            return RawPGResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }

        guard status == PGRES_TUPLES_OK else {
            let msg = result.flatMap { String(cString: PQresultErrorMessage($0)) } ?? "Unexpected result status"
            throw PostgreSQLError.queryFailed(msg)
        }

        let rowCount = Int(PQntuples(result))
        let colCount = Int(PQnfields(result))

        var columns: [String] = []
        var columnTypes: [String] = []

        for i in 0..<Int32(colCount) {
            let name = PQfname(result, i).map { String(cString: $0) } ?? "col_\(i)"
            columns.append(name)
            let oid = PQftype(result, i)
            columnTypes.append(pgOidToTypeName(oid))
        }

        var rows: [[String?]] = []
        let maxRows = min(rowCount, 100_000)
        let isTruncated = rowCount > 100_000

        for r in 0..<Int32(maxRows) {
            var rowData: [String?] = []
            for c in 0..<Int32(colCount) {
                if PQgetisnull(result, r, c) == 1 {
                    rowData.append(nil)
                } else if let value = PQgetvalue(result, r, c) {
                    rowData.append(String(cString: value))
                } else {
                    rowData.append(nil)
                }
            }
            rows.append(rowData)
        }

        return RawPGResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }

    // MARK: - Streaming

    /// One query streams at a time on a connection. Each stream carries its query's id, so the producer
    /// of a stream that a later query replaced can neither read nor end the later one.
    private var stream: PostgreSQLStreamState?

    func beginStream(query: String, id: UInt64, readsOnly: Bool) throws -> PGBeginStreamResult {
        endLeftoverStream()
        guard let conn else { throw PostgreSQLError.notConnected }

        let cancelsOutput = cancelsAbandonedOutput(conn)
        let state = PostgreSQLStreamState(
            id: id,
            cancelsAbandonedOutput: cancelsOutput,
            cancelsUnreadRows: cancelsOutput && readsOnly
        )
        try send(query, id: id, on: conn)
        guard PQsetSingleRowMode(conn) == 1 else {
            _ = drain(state)
            throw PostgreSQLError.queryFailed("Failed to enter single-row streaming mode")
        }
        guard let firstResult = PQgetResult(conn) else {
            markDrained(state)
            return .commandOk(affectedRows: 0)
        }

        switch PQresultStatus(firstResult) {
        case PGRES_SINGLE_TUPLE:
            state.pendingResult = firstResult
            stream = state
            return .tuples(parseColumns(firstResult))
        case PGRES_TUPLES_OK:
            let columns = parseColumns(firstResult)
            PQclear(firstResult)
            if let error = drain(state).error { throw error }
            stream = state
            return .tuples(columns)
        case PGRES_COMMAND_OK:
            let affected = Int(String(cString: PQcmdTuples(firstResult))) ?? 0
            PQclear(firstResult)
            if let error = drain(state).error { throw error }
            return .commandOk(affectedRows: affected)
        default:
            state.pendingResult = firstResult
            if let error = drain(state).error { throw error }
            return .commandOk(affectedRows: 0)
        }
    }

    /// A cancel still on its way could reach the server after this query and stop it instead, so the
    /// query waits for it. A consumer that leaves as the query goes out finds nothing in flight to
    /// cancel, so its cancel is sent here once the query is registered.
    private func send(_ query: String, id: UInt64, on conn: OpaquePointer) throws {
        cancelHandle.waitForPendingCancels()
        try Task.checkCancellation()
        guard PQsendQuery(conn, query) == 1 else {
            throw PostgreSQLError.queryFailed(String(cString: PQerrorMessage(conn)))
        }
        cancelHandle.querySent(id)
        if Task.isCancelled {
            cancelHandle.cancel(id)
        }
    }

    /// Returns nil at the end of the rows. Single-row mode reports a statement that fails after its
    /// first rows as an error result in place of the next row, and that error ends the stream.
    /// A stream that a later query replaced ends as cancelled.
    func fetchNextRow(stream id: UInt64, options: StreamOptions, columns: [ColumnInfo]) throws -> [Cell]? {
        guard let state = stream, state.id == id else { throw CancellationError() }
        guard !state.isDrained else { return nil }
        guard let conn else { throw PostgreSQLError.notConnected }

        let readAhead = state.pendingResult
        state.pendingResult = nil
        guard let result = readAhead ?? PQgetResult(conn) else {
            markDrained(state)
            return nil
        }
        guard PQresultStatus(result) == PGRES_SINGLE_TUPLE else {
            state.pendingResult = result
            if let error = drain(state).error { throw error }
            return nil
        }
        defer { PQclear(result) }
        return cells(of: result, options: options, columns: columns)
    }

    /// An error after a cancel is the cancel's own, so it ends the stream without a failure.
    func endStream(_ id: UInt64) throws {
        guard let state = stream, state.id == id else { return }
        stream = nil
        let end = drain(state)
        guard end != .cancelled, let error = end.error else { return }
        throw error
    }

    func endStreamAtRowCap(_ id: UInt64) throws {
        if let state = stream, state.id == id {
            cancelUnreadRows(of: state)
        }
        try endStream(id)
    }

    /// Draining rows nobody will read would pull every one of them over the network, so the statement is
    /// cancelled first, as the Mac does; not when the rows have all arrived, or when the cancel would abort the
    /// open transaction.
    private func cancelUnreadRows(of state: PostgreSQLStreamState) {
        guard state.cancelsUnreadRows, let conn, rowsRemain(in: state, conn: conn) else { return }
        cancelHandle.cancel(state.id)
    }

    /// Reads only what has already arrived, so the cap never waits on the server for a row it would
    /// discard. A result taken here that is not a row is left for the drain to report.
    private func rowsRemain(in state: PostgreSQLStreamState, conn: OpaquePointer) -> Bool {
        guard !state.isDrained else { return false }
        if let readAhead = state.pendingResult {
            return PQresultStatus(readAhead) == PGRES_SINGLE_TUPLE
        }
        guard PQconsumeInput(conn) == 1 else { return false }
        guard PQisBusy(conn) == 0 else { return true }
        guard let next = PQgetResult(conn) else {
            markDrained(state)
            return false
        }
        guard PQresultStatus(next) == PGRES_SINGLE_TUPLE else {
            state.pendingResult = next
            return false
        }
        PQclear(next)
        return true
    }

    /// A new query ends the stream still in flight; that stream's producer then finds its id gone.
    private func endLeftoverStream() {
        guard let leftover = stream else { return }
        stream = nil
        cancelUnreadRows(of: leftover)
        _ = drain(leftover)
    }

    private func discardStream() {
        guard let state = stream else { return }
        stream = nil
        if let readAhead = state.pendingResult { PQclear(readAhead) }
        state.pendingResult = nil
        markDrained(state)
    }

    private func markDrained(_ state: PostgreSQLStreamState) {
        state.isDrained = true
        cancelHandle.queryFinished(state.id)
    }

    /// Reads every result the stream's query still has in flight, ending any COPY among them.
    private func drain(_ state: PostgreSQLStreamState) -> PostgreSQLStreamEnd {
        guard !state.isDrained else { return .completed }
        state.isDrained = true
        defer { cancelHandle.queryFinished(state.id) }
        var readAhead = state.pendingResult
        state.pendingResult = nil
        guard let conn else {
            if let readAhead { PQclear(readAhead) }
            return .completed
        }
        let cancellingOutput = state.cancelsAbandonedOutput
        let drained = PostgreSQLStreamDrain.drain(
            nextResult: {
                guard let result = readAhead ?? PQgetResult(conn) else { return nil }
                readAhead = nil
                defer { PQclear(result) }
                return Self.pendingResult(of: result)
            },
            endCopy: { LibPQCopyState.end($0, conn: conn, cancellingOutput: cancellingOutput) },
            afterCancel: cancelHandle.isCancelled(state.id)
        )
        dropConnectionIfStuck(drained.outcome)
        return drained.end
    }

    private static func pendingResult(of result: OpaquePointer) -> PostgreSQLPendingResult {
        if let copy = LibPQCopyState.copy(of: result) { return .copy(copy) }
        guard PostgreSQLStreamDrain.isFailure(PQresultStatus(result)) else { return .completed }
        return .failed(String(cString: PQresultErrorMessage(result)))
    }

    private func cells(of result: OpaquePointer, options: StreamOptions, columns: [ColumnInfo]) -> [Cell] {
        var cells: [Cell] = []
        cells.reserveCapacity(columns.count)
        for c in 0..<columns.count {
            let col = Int32(c)
            if PQgetisnull(result, 0, col) == 1 {
                cells.append(.null)
            } else if let value = PQgetvalue(result, 0, col) {
                let str = String(cString: value)
                let ref = makeCellRef(column: columns[c].name, columns: columns, result: result, options: options)
                cells.append(Cell.from(
                    legacyValue: str,
                    columnTypeName: columns[c].typeName,
                    options: options,
                    ref: ref
                ))
            } else {
                cells.append(.null)
            }
        }
        return cells
    }

    private func finishPendingResults(_ conn: OpaquePointer, cancellingOutput: Bool) -> LibPQDrainOutcome {
        let outcome = LibPQCopyState.finishPendingResults(conn, cancellingOutput: cancellingOutput)
        dropConnectionIfStuck(outcome)
        return outcome
    }

    private func dropConnectionIfStuck(_ outcome: LibPQDrainOutcome) {
        guard let stuck = outcome.stuckInCopy else { return }
        Self.logger.fault(
            "libpq stayed in \(String(describing: stuck.direction), privacy: .public); dropping the connection"
        )
        close()
    }

    /// Cancelling inside a transaction block aborts it, so the cancel that keeps a `COPY TO STDOUT`
    /// from transferring the whole table is sent only outside one.
    private func cancelsAbandonedOutput(_ conn: OpaquePointer) -> Bool {
        PQtransactionStatus(conn) != PQTRANS_INTRANS
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PostgreSQLActor")

    private func parseColumns(_ result: OpaquePointer) -> [ColumnInfo] {
        let colCount = Int(PQnfields(result))
        var cols: [ColumnInfo] = []
        for i in 0..<colCount {
            let name = PQfname(result, Int32(i)).map { String(cString: $0) } ?? "col_\(i)"
            let oid = PQftype(result, Int32(i))
            cols.append(ColumnInfo(
                name: name,
                typeName: pgOidToTypeName(oid),
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: i
            ))
        }
        return cols
    }

    private func makeCellRef(column: String, columns: [ColumnInfo], result: OpaquePointer, options: StreamOptions) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }
        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            let col = Int32(columnIndex)
            guard PQgetisnull(result, 0, col) == 0 else { return nil }
            guard let cValue = PQgetvalue(result, 0, col) else { return nil }
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: String(cString: cValue)))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }
}

nonisolated enum PGBeginStreamResult: Sendable {
    case tuples([ColumnInfo])
    case commandOk(affectedRows: Int)
}

/// Confined to `PostgreSQLActor`, which owns the connection the stream reads.
nonisolated private final class PostgreSQLStreamState {
    let id: UInt64
    /// Read before the query goes out: once it is in flight the status is PQTRANS_ACTIVE.
    let cancelsAbandonedOutput: Bool
    /// A cancel rolls back the whole statement, so rows nobody will read are cut short only for a read: an
    /// `UPDATE ... RETURNING` past the row cap has to finish, or its write is undone.
    let cancelsUnreadRows: Bool
    /// A result read before its turn: the first row, or what the row-cap check took off the wire.
    var pendingResult: OpaquePointer?
    var isDrained = false

    init(id: UInt64, cancelsAbandonedOutput: Bool, cancelsUnreadRows: Bool) {
        self.id = id
        self.cancelsAbandonedOutput = cancelsAbandonedOutput
        self.cancelsUnreadRows = cancelsUnreadRows
    }
}

// MARK: - Cancellation

/// Which query a cancel is for. A connection runs one query at a time, so a cancel is taken only for
/// the query in flight; one that arrives before its query is sent, or after it ends, is dropped and
/// can never mark the next query.
nonisolated struct PostgreSQLQueryCancels: Equatable, Sendable {
    private var lastQuery: UInt64 = 0
    private(set) var inFlight: UInt64?
    private var cancelled: UInt64?

    mutating func reserve() -> UInt64 {
        lastQuery &+= 1
        return lastQuery
    }

    mutating func sent(_ query: UInt64) {
        inFlight = query
    }

    mutating func finished(_ query: UInt64) {
        guard inFlight == query else { return }
        inFlight = nil
    }

    mutating func detach() {
        inFlight = nil
    }

    /// Returns whether a cancel has to go out: once per query, and only while that query is in flight.
    mutating func cancel(_ query: UInt64) -> Bool {
        guard inFlight == query, cancelled != query else { return false }
        cancelled = query
        return true
    }

    mutating func cancelInFlight() -> Bool {
        guard let inFlight else { return false }
        return cancel(inFlight)
    }

    func isCancelled(_ query: UInt64) -> Bool {
        cancelled == query
    }
}

/// A copy of the backend's identity that holds none of the connection, so `PQcancel` may run on any
/// thread, even while the connection closes. It is freed when its last holder lets go, so a cancel
/// still under way never meets a freed object.
nonisolated private final class PostgreSQLCancelKey: @unchecked Sendable {
    private let object: OpaquePointer

    init?(connection: OpaquePointer) {
        guard let object = PQgetCancel(connection) else { return nil }
        self.object = object
    }

    deinit {
        PQfreeCancel(object)
    }

    func send() {
        var errbuf = [CChar](repeating: 0, count: 256)
        PQcancel(object, &errbuf, Int32(errbuf.count))
    }
}

/// Stop has to reach a statement while the actor sits blocked in libpq on it, so the cancel key and
/// the query in flight live here, outside the actor. The lock is never held across a libpq call:
/// `PQcancel` is a network round trip, and holding it there would stall every query start and close.
nonisolated private final class PostgreSQLCancelHandle: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "com.TablePro.mobile.libpq.cancel",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private let sending = DispatchGroup()
    private var key: PostgreSQLCancelKey?
    private var queries = PostgreSQLQueryCancels()

    func attach(_ key: PostgreSQLCancelKey?) {
        lock.withLock { self.key = key }
    }

    /// Runs before `PQfinish`. A cancel already under way holds its own reference to the key.
    func detach() {
        lock.withLock {
            key = nil
            queries.detach()
        }
    }

    func reserveQuery() -> UInt64 {
        lock.withLock { queries.reserve() }
    }

    func querySent(_ query: UInt64) {
        lock.withLock { queries.sent(query) }
    }

    func queryFinished(_ query: UInt64) {
        lock.withLock { queries.finished(query) }
    }

    func isCancelled(_ query: UInt64) -> Bool {
        lock.withLock { queries.isCancelled(query) }
    }

    /// The send is registered in the same critical section that marks the query, so a query that ends
    /// right after the mark still finds the cancel pending and waits for it before the next one goes out.
    func cancel(_ query: UInt64) {
        send(lock.withLock { pendingSend(if: queries.cancel(query)) })
    }

    func cancelInFlight() {
        send(lock.withLock { pendingSend(if: queries.cancelInFlight()) })
    }

    private func pendingSend(if accepted: Bool) -> PostgreSQLCancelKey? {
        guard accepted, let key else { return nil }
        sending.enter()
        return key
    }

    /// A cancel still on its way could reach the server after the next query and stop that one instead.
    func waitForPendingCancels() {
        sending.wait()
    }

    /// `PQcancel` connects to the server and waits on it, so it never runs on the caller's thread,
    /// which can be the main thread.
    private func send(_ key: PostgreSQLCancelKey?) {
        guard let key else { return }
        Self.queue.async {
            key.send()
            self.sending.leave()
        }
    }
}

/// A result read while a stream ends, reduced to what decides how the stream ends.
nonisolated enum PostgreSQLPendingResult: Equatable, Sendable {
    case copy(LibPQCopy)
    case failed(String)
    case completed
}

nonisolated enum PostgreSQLStreamEnd: Equatable, Sendable {
    case completed
    case cancelled
    case abandonedCopy(LibPQCopyDirection)
    case failed(String)

    var error: (any Error)? {
        switch self {
        case .completed:
            return nil
        case .cancelled:
            return CancellationError()
        case .abandonedCopy(let direction):
            return PostgreSQLError.unsupported(direction.unsupportedMessage)
        case .failed(let message):
            return PostgreSQLError.queryFailed(message)
        }
    }
}

nonisolated enum PostgreSQLStreamDrain {
    /// libpq reports a failed statement as FATAL_ERROR and a reply it could not parse as BAD_RESPONSE.
    static func isFailure(_ status: ExecStatusType) -> Bool {
        status == PGRES_FATAL_ERROR || status == PGRES_BAD_RESPONSE
    }

    /// `LibPQPendingResultDrain` keeps COPY states alone, so a statement that failed behind the first
    /// result ended as a success. The first failure is kept here; after a cancel it is that cancel's
    /// error, which is asked only once the results are in, since Stop can land while they drain.
    /// A COPY wins, because ending it is what provokes an error after it.
    static func drain(
        nextResult: () -> PostgreSQLPendingResult?,
        endCopy: (LibPQCopy) -> Void,
        afterCancel: @autoclosure () -> Bool
    ) -> (end: PostgreSQLStreamEnd, outcome: LibPQDrainOutcome) {
        var firstFailure: String?
        let outcome = LibPQPendingResultDrain.drain(
            nextResult: {
                switch nextResult() {
                case .copy(let copy):
                    return .copy(copy)
                case .failed(let message):
                    if firstFailure == nil { firstFailure = message }
                    return .completed
                case .completed:
                    return .completed
                case nil:
                    return nil
                }
            },
            endCopy: endCopy
        )
        let end: PostgreSQLStreamEnd
        if let copy = outcome.abandonedCopy {
            end = .abandonedCopy(copy.direction)
        } else if let firstFailure {
            end = afterCancel() ? .cancelled : .failed(firstFailure)
        } else {
            end = .completed
        }
        return (end: end, outcome: outcome)
    }
}

// MARK: - PostgreSQL OID Type Names

nonisolated private func pgOidToTypeName(_ oid: UInt32) -> String {
    switch oid {
    case 16: return "boolean"
    case 17: return "bytea"
    case 18: return "char"
    case 19: return "name"
    case 20: return "bigint"
    case 21: return "smallint"
    case 23: return "integer"
    case 25: return "text"
    case 26: return "oid"
    case 114: return "json"
    case 142: return "xml"
    case 700: return "real"
    case 701: return "double precision"
    case 869: return "inet"
    // PostgreSQL OID constants — separators would obscure the wire-protocol values
    // swiftlint:disable number_separator
    case 1042: return "char"
    case 1043: return "varchar"
    case 1082: return "date"
    case 1083: return "time"
    case 1114: return "timestamp"
    case 1184: return "timestamptz"
    case 1700: return "numeric"
    case 2950: return "uuid"
    case 3802: return "jsonb"
    // swiftlint:enable number_separator
    default: return "unknown"
    }
}

nonisolated private struct RawPGResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum PostgreSQLError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "PostgreSQL connection failed: \(msg)"
        case .notConnected: return "Not connected to PostgreSQL database"
        case .queryFailed(let msg): return "PostgreSQL query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
