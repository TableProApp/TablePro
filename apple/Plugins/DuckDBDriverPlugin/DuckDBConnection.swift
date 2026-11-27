//
//  DuckDBConnection.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import os
import TableProDuckDBCore
import TableProPluginKit

/// Everything a reopen needs to put the connection back where it was. Held from the first open,
/// because a released handle has to be re-acquired from inside the actor with nothing handed down
/// to it.
nonisolated struct DuckDBOpenSpec: Sendable, Equatable {
    let path: String
    let accessMode: DuckDBAccessMode
    /// False for Remote mode, whose token and trust come from the connection form alone. Loaded, a secret
    /// the user stored in `~/.duckdb` for the server stood in for an empty Token, and its pin replaced the
    /// CA and name check of the SSL Mode the form chose (measured).
    var allowsPersistentSecrets = true
}

/// Why a release did not happen, for the log line that tells a user whose lock never comes back
/// whether the timer is broken or the session is holding something.
nonisolated enum DuckDBReleaseOutcome: Equatable {
    case released
    case alreadyReleased
    case notOpen
    case notIdleYet
    case holdsSessionObjects
    case holdsAttachedCatalogs
    case holdsChangedSettings
    case holdsOpenTransaction
    case stateUnreadable
}

// The open database and the task threads its connections share, with the transfer connections opened on it. Used only
// on the executor of the session that opened it, which those connections run on too.
nonisolated final class DuckDBOpenDatabase: @unchecked Sendable {
    var database: duckdb_database?
    var taskThreads: DuckDBTaskThreads?
    var transferConnections: [ObjectIdentifier: DuckDBConnectionHandles] = [:]
    // Keyed as `transferConnections`, so a close can end each one's read before its connection.
    var transferActors: [ObjectIdentifier: DuckDBTransferReference] = [:]
}

nonisolated final class DuckDBTransferReference: @unchecked Sendable {
    weak var actor: DuckDBConnectionActor?

    init(_ actor: DuckDBConnectionActor) {
        self.actor = actor
    }
}

// A connection, with the second one that renders the rows of a result the first is still producing.
nonisolated final class DuckDBConnectionHandles: @unchecked Sendable {
    let live: DuckDBLiveConnectionBox
    var connection: duckdb_connection?
    var renderConnection: duckdb_connection?
    var renderSettings: [String: String] = [:]
    var resultReader: DuckDBResultReader?

    init(live: DuckDBLiveConnectionBox) {
        self.live = live
    }

    // The box is cleared before the disconnect, so a cancel never reaches a freed connection.
    func close() {
        live.set(nil)
        resultReader = nil
        if renderConnection != nil {
            duckdb_disconnect(&renderConnection)
            renderConnection = nil
        }
        if connection != nil {
            duckdb_disconnect(&connection)
            connection = nil
        }
        renderSettings = [:]
    }
}

// One value of a fetched chunk, read in place: text and bytes point into the chunk and live only for the call, so a
// reader that cuts a value for display copies only what it keeps.
nonisolated enum DuckDBChunkValue {
    case null
    case text(UnsafeRawBufferPointer)
    case bytes(UnsafeRawBufferPointer)
    case spelled(String)

    var pluginValue: PluginCellValue {
        switch self {
        case .null: .null
        case .text(let utf8): .text(String(decoding: utf8, as: UTF8.self))
        case .bytes(let bytes): .bytes(Data(bytes))
        case .spelled(let text): .text(text)
        }
    }
}

// What a read hands out for a value of the named column.
typealias DuckDBValueReader<Value> = @Sendable (_ column: String, _ value: DuckDBChunkValue) -> Value

nonisolated enum DuckDBPulledElement<Value: Sendable>: Sendable {
    case header(PluginStreamHeader)
    case rows([[Value]])
}

actor DuckDBConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBConnectionActor")

    private let executor: DuckDBStackExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private let openDatabase: DuckDBOpenDatabase
    private let handles: DuckDBConnectionHandles
    // False for a transfer connection, which reads the database its session opened and closes.
    private let ownsDatabase: Bool

    private var database: duckdb_database? {
        get { openDatabase.database }
        set { openDatabase.database = newValue }
    }

    private var taskThreads: DuckDBTaskThreads? {
        get { openDatabase.taskThreads }
        set { openDatabase.taskThreads = newValue }
    }

    private var connection: duckdb_connection? {
        get { handles.connection }
        set { handles.connection = newValue }
    }

    private var renderSettings: [String: String] {
        get { handles.renderSettings }
        set { handles.renderSettings = newValue }
    }

    private var resultReader: DuckDBResultReader? { handles.resultReader }

    private var liveConnection: DuckDBLiveConnectionBox { handles.live }

    private var openSpec: DuckDBOpenSpec?

    /// Statements the driver itself issued after opening, replayed in order on a reopen. Only the
    /// driver's own setup goes in here: what the user did to the session is deliberately not
    /// replayed, it is what stops a release happening at all.
    private var sessionSetup: [String] = []

    /// The databases the connection attaches itself, which a reopen attaches again, so holding them
    /// is no reason to keep the file.
    private var configuredAttachments: [AttachedDatabase] = []
    private var attachmentsReadOnly = false

    /// `duckdb_settings()` reports no default, so a setting the user changed is visible only
    /// against what the connection opened with.
    private var baselineSettings: [String: String] = [:]

    private var hasOpenTransaction = false
    private var lastActivity = ContinuousClock.now
    private var isReleased = false

    private var pulledRead: PulledRead?
    private var lastPulledRead: UInt64 = 0

    init(liveConnection: DuckDBLiveConnectionBox) {
        executor = DuckDBStackExecutor(name: "com.TablePro.duckdb")
        openDatabase = DuckDBOpenDatabase()
        handles = DuckDBConnectionHandles(live: liveConnection)
        ownsDatabase = true
    }

    private init(transferOn executor: DuckDBStackExecutor, of openDatabase: DuckDBOpenDatabase, handles: DuckDBConnectionHandles) {
        self.executor = executor
        self.openDatabase = openDatabase
        self.handles = handles
        ownsDatabase = false
    }

    /// True while the handle is closed but the connection is still live and will reopen on demand.
    var hasReleasedFile: Bool { isReleased }

    func open(spec: DuckDBOpenSpec) throws {
        guard ownsDatabase else { throw DuckDBPluginError.unsupportedOperation }
        try openHandle(spec: spec)
        openSpec = spec
        isReleased = false
        sessionSetup = []
        hasOpenTransaction = false
        lastActivity = ContinuousClock.now
    }

    /// The statements to reissue after a reopen, replaced wholesale rather than appended to. The
    /// driver recomputes the list whenever the session moves, so switching database ten times
    /// leaves one `USE` to replay instead of ten.
    func setSessionSetup(_ statements: [String]) {
        sessionSetup = statements
    }

    func setConfiguredAttachments(_ attachments: [AttachedDatabase], readOnly: Bool) {
        configuredAttachments = attachments
        attachmentsReadOnly = readOnly
    }

    func captureSettingsBaseline() {
        baselineSettings = (try? readSettings()) ?? [:]
    }

    // A connection on this database for a transfer. DuckDB gives it a transaction of its own, so it reads one snapshot
    // while the session writes. It runs on this executor, and every close of the database closes it first.
    func openTransferConnection(liveConnection: DuckDBLiveConnectionBox) throws -> DuckDBConnectionActor {
        guard ownsDatabase else { throw DuckDBPluginError.unsupportedOperation }
        try ensureOpen()
        guard let database else { throw DuckDBPluginError.notConnected }
        let transfer = DuckDBConnectionHandles(live: liveConnection)
        try Self.connect(transfer, to: database)
        let actor = DuckDBConnectionActor(transferOn: executor, of: openDatabase, handles: transfer)
        openDatabase.transferConnections[ObjectIdentifier(transfer)] = transfer
        openDatabase.transferActors[ObjectIdentifier(transfer)] = DuckDBTransferReference(actor)
        lastActivity = ContinuousClock.now
        return actor
    }

    func close() async {
        closePulledRead()
        guard ownsDatabase else {
            openDatabase.transferConnections[ObjectIdentifier(handles)] = nil
            openDatabase.transferActors[ObjectIdentifier(handles)] = nil
            handles.close()
            hasOpenTransaction = false
            return
        }
        // Each transfer connection ends the read it holds, which keeps the database open, before it closes.
        for transfer in openDatabase.transferActors.values.compactMap(\.actor) {
            await transfer.close()
        }
        closeHandle()
        openSpec = nil
        sessionSetup = []
        configuredAttachments = []
        attachmentsReadOnly = false
        baselineSettings = [:]
        hasOpenTransaction = false
        isReleased = false
    }

    /// Gives the file's lock back if the session holds nothing a reopen would destroy.
    ///
    /// The whole decision happens in this one call. It has to: measured, a `duckdb_close` drops
    /// temporary objects, attached catalogs, every changed setting and the `USE` position, and
    /// rolls an open transaction back raising nothing. Checking from one actor call and closing
    /// from another would let a statement land in between and be silently destroyed, which is the
    /// failure this guard exists to prevent. Nothing here suspends, so nothing interleaves.
    @discardableResult
    func releaseFile(idleFor minimumIdle: Duration?) -> DuckDBReleaseOutcome {
        guard !isReleased else { return .alreadyReleased }
        guard connection != nil, let spec = openSpec else { return .notOpen }
        if let minimumIdle, ContinuousClock.now - lastActivity < minimumIdle { return .notIdleYet }
        // A transfer connection reading the file is use of it.
        guard openDatabase.transferConnections.isEmpty else { return .notIdleYet }

        if let blocked = heldSessionState() { return blocked }

        closeHandle()
        isReleased = true
        Self.logger.info("Released the DuckDB file lock on \(spec.path, privacy: .private)")
        return .released
    }

    /// Reopens a released handle and puts the session back. A connection that was never released
    /// costs one boolean.
    ///
    /// A path that has gone away is reported rather than recreated. `duckdb_open_ext` creates a
    /// database at any path it does not find, and `connect` deliberately allows that so a new
    /// `.duckdb` file can be made from the connection form. Allowing it here too would answer a
    /// file the user moved or deleted during the idle window with an empty database wearing its
    /// name, which reads as a working connection to nothing.
    func ensureOpen() throws {
        guard isReleased, let spec = openSpec else { return }

        guard FileManager.default.fileExists(atPath: spec.path) else {
            throw DuckDBPluginError.fileMissing(spec.path)
        }
        // A replayed ATTACH would create an empty database where the attached file was.
        if let gone = configuredAttachments.first(where: { !FileManager.default.fileExists(atPath: $0.expandedPath) }) {
            throw DuckDBPluginError.fileMissing(gone.expandedPath)
        }

        try openHandle(spec: spec)
        isReleased = false
        do {
            for statement in sessionSetup {
                _ = try runSetup(statement)
            }
        } catch {
            /// The session could not be put back where it was, so the handle is closed again
            /// rather than handed over half restored. A `USE` that fails because the schema was
            /// dropped while the file was released would otherwise leave the connection running in
            /// DuckDB's default catalog while still reporting the old position, and every query
            /// after it would silently address the wrong objects.
            closeHandle()
            isReleased = true
            throw error
        }
        lastActivity = ContinuousClock.now
    }

    /// Checks the handle without counting as use. `executeQuery` would refresh `lastActivity`, and
    /// a health check every thirty seconds would then hold the idle clock at zero forever.
    func pingQuery() throws {
        try ensureOpen()
        guard let conn = connection else { throw DuckDBPluginError.notConnected }
        // A statement would end the read being handed out, which is itself a live session.
        guard pulledRead == nil else { return }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(conn, "SELECT 1", &result) == DuckDBError else { return }
        // An aborted transaction refuses every statement until its ROLLBACK, on a session that is still alive.
        guard duckdb_result_error_type(&result) != DUCKDB_ERROR_TRANSACTION else { return }
        throw DuckDBPluginError.queryFailed(Self.errorMessage(from: &result))
    }

    func executeQuery(_ query: String) throws -> DuckDBRawResult {
        try executePrepared(query, parameters: [])
    }

    func executePrepared(_ query: String, parameters: [PluginCellValue]) throws -> DuckDBRawResult {
        try run(query, parameters: parameters, limit: PluginRowLimits.emergencyMax, unread: .drain)
    }

    func executeBounded(_ query: String, parameters: [PluginCellValue], rowCap: Int) throws -> DuckDBRawResult {
        try run(query, parameters: parameters, limit: rowCap, unread: .abandonWhenIdle)
    }

    private func run(
        _ query: String, parameters: [PluginCellValue], limit: Int, unread: DuckDBUnreadRows
    ) throws -> DuckDBRawResult {
        try ensureOpen()
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }
        closePulledRead()

        let startTime = Date()
        noteActivity(query)
        var opened = try openResult(query: query, parameters: parameters, connection: conn, unread: unread)
        defer { close(&opened, on: conn) }
        let result = try extractResult(from: opened, limit: limit, startTime: startTime)
        try finish(&opened, on: conn)
        return result
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        try ensureOpen()
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }
        closePulledRead()

        noteActivity(query)
        var opened = try openResult(query: query, parameters: [], connection: conn, unread: .abandonWhenIdle)
        defer { close(&opened, on: conn) }
        let cancelled = try streamResultRows(opened, continuation: continuation)
        try finish(&opened, on: conn)
        Self.end(continuation, cancelled: cancelled)
    }

    // The state check, the BEGIN, the statement and the ROLLBACK share one actor turn, so nothing lands in between.
    // The statement text is not tracked: the ROLLBACK leaves the session as idle as it was found.
    // A stop at `byteLimit` ends only the read's own read-only transaction.
    func executeReadOnly(
        _ query: String,
        parameters: [PluginCellValue],
        rowCap: Int? = nil,
        byteLimit: Int? = nil,
        reason: DuckDBReadOnlyStatement.Reason
    ) throws -> DuckDBRawResult {
        let conn = try readOnlyConnection()
        let startTime = Date()
        return try DuckDBReadOnlyStatement.run(on: conn, session: sessionTransactionState(), reason: reason) {
            var opened = try openResult(
                query: query, parameters: parameters, connection: conn, unread: .abandon, session: .inTransaction
            )
            defer { close(&opened, on: conn) }
            let result = try extractResult(
                from: opened, limit: rowCap ?? PluginRowLimits.emergencyMax, byteLimit: byteLimit, startTime: startTime
            )
            try finish(&opened, on: conn)
            return result
        }
    }

    func streamReadOnly(
        _ query: String,
        reason: DuckDBReadOnlyStatement.Reason,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        let conn = try readOnlyConnection()
        try DuckDBReadOnlyStatement.run(on: conn, session: sessionTransactionState(), reason: reason) {
            var opened = try openResult(
                query: query, parameters: [], connection: conn, unread: .abandon, session: .inTransaction
            )
            defer { close(&opened, on: conn) }
            let cancelled = try streamResultRows(opened, continuation: continuation)
            try finish(&opened, on: conn)
            Self.end(continuation, cancelled: cancelled)
        }
    }

    private func readOnlyConnection() throws -> duckdb_connection {
        try ensureOpen()
        guard let conn = connection else { throw DuckDBPluginError.notConnected }
        closePulledRead()
        lastActivity = ContinuousClock.now
        return conn
    }

    // MARK: - Read handed out a batch at a time

    // A read handed out one batch per call, so other work on this executor runs between batches. Any other statement on
    // the connection ends it first, and the next call then throws CancellationError.
    private nonisolated struct PulledRead {
        var opened: OpenedResult
        var projection: duckdb_prepared_statement?
        let generation: UInt64
        // The read-only transaction DuckDBReadOnlyStatement opened for it, rolled back when it ends.
        let endsReadOnlyTransaction: Bool
    }

    func beginPulledRead(
        _ query: String,
        reason: DuckDBReadOnlyStatement.Reason?
    ) throws -> (header: PluginStreamHeader, generation: UInt64) {
        // A Stop that came while this waited for the executor interrupted nothing, and DuckDB clears it at the start.
        try Task.checkCancellation()
        let conn: duckdb_connection
        if let reason {
            conn = try readOnlyConnection()
            try DuckDBReadOnlyStatement.begin(on: conn, session: sessionTransactionState(), reason: reason)
        } else {
            try ensureOpen()
            guard let open = connection else { throw DuckDBPluginError.notConnected }
            closePulledRead()
            noteActivity(query)
            conn = open
        }
        let opened: OpenedResult
        do {
            opened = try openResult(
                query: query, parameters: [], connection: conn,
                unread: reason == nil ? .abandonWhenIdle : .abandon, session: reason == nil ? nil : .inTransaction
            )
        } catch {
            if reason != nil { DuckDBReadOnlyStatement.end(on: conn) }
            throw error
        }
        lastPulledRead &+= 1
        pulledRead = PulledRead(
            opened: opened, projection: nil, generation: lastPulledRead, endsReadOnlyTransaction: reason != nil
        )
        let header = PluginStreamHeader(
            columns: opened.schema.names,
            columnTypeNames: opened.schema.typeNames,
            estimatedRowCount: opened.rowCount.map { Int($0) }
        )
        return (header, lastPulledRead)
    }

    // Nil once the read has ended, which ends what it opened.
    func nextPulledBatch<Value: Sendable>(
        _ generation: UInt64,
        reading read: DuckDBValueReader<Value>
    ) throws -> [[Value]]? {
        guard var pulled = pulledRead, pulled.generation == generation, let conn = connection else {
            throw CancellationError()
        }
        let batch: [[Value]]?
        do {
            batch = try nextBatch(of: pulled.opened, projection: &pulled.projection, reading: read)
        } catch {
            pulledRead = pulled
            closePulledRead()
            throw error
        }
        if let batch {
            pulledRead = pulled
            return batch
        }
        pulledRead = nil
        duckdb_destroy_prepare(&pulled.projection)
        defer {
            if pulled.endsReadOnlyTransaction { DuckDBReadOnlyStatement.end(on: conn) }
        }
        try finish(&pulled.opened, on: conn)
        return nil
    }

    func endPulledRead(_ generation: UInt64? = nil) {
        guard generation == nil || pulledRead?.generation == generation else { return }
        closePulledRead()
    }

    // What a read given up leaves: its rows unread, and any transaction it opened rolled back.
    private func closePulledRead() {
        guard var read = pulledRead else { return }
        pulledRead = nil
        duckdb_destroy_prepare(&read.projection)
        guard let conn = connection else {
            duckdb_destroy_result(&read.opened.result)
            return
        }
        try? finishUnreadRows(of: read.opened)
        close(&read.opened, on: conn)
        if read.endsReadOnlyTransaction { DuckDBReadOnlyStatement.end(on: conn) }
    }

    // MARK: - Handle lifecycle

    private func openHandle(spec: DuckDBOpenSpec) throws {
        DuckDBExtensionPolicy.registerLinkedExtensions()
        var config: duckdb_config?
        guard duckdb_create_config(&config) != DuckDBError else {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "DuckDB could not allocate a configuration to open the file")
            )
        }
        defer { duckdb_destroy_config(&config) }
        guard duckdb_set_config(
            config,
            DuckDBStorageCompatibility.configurationOption,
            DuckDBStorageCompatibility.version
        ) != DuckDBError else {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "This build of DuckDB does not accept the storage version that keeps files readable by DuckDB 1.x")
            )
        }
        guard duckdb_set_config(
            config,
            DuckDBExpressionDepth.configurationOption,
            DuckDBExpressionDepth.limit
        ) != DuckDBError else {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "This build of DuckDB does not accept a limit on how deep an expression nests")
            )
        }
        for option in DuckDBTaskThreads.sessionOptions
            where duckdb_set_config(config, option.name, option.value) == DuckDBError {
            throw DuckDBPluginError.connectionFailed(
                String(localized: "This build of DuckDB does not accept running its tasks on threads TablePro starts")
            )
        }
        for option in DuckDBExtensionPolicy.openOptions
            where duckdb_set_config(config, option.name, option.value) == DuckDBError {
            throw DuckDBPluginError.connectionFailed("DuckDB rejected \(option.name) = \(option.value)")
        }
        if !spec.allowsPersistentSecrets {
            guard duckdb_set_config(config, "allow_persistent_secrets", "false") != DuckDBError else {
                throw DuckDBPluginError.connectionFailed(
                    String(localized: "This build of DuckDB does not accept turning off persistent secrets")
                )
            }
        }
        if spec.accessMode == .readOnly {
            /// Measured: a value `duckdb_set_config` rejects leaves the option unset and the open
            /// then succeeds read-write with writes allowed, so an unchecked return here is a
            /// read-only setting that silently does nothing.
            guard duckdb_set_config(
                config,
                DuckDBAccessMode.configurationOption,
                spec.accessMode.rawValue
            ) != DuckDBError else {
                throw DuckDBPluginError.connectionFailed(
                    String(localized: "This build of DuckDB does not accept a read-only access mode")
                )
            }
        }

        var db: duckdb_database?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let state = duckdb_open_ext(spec.path, &db, config, &errorPtr)

        if state == DuckDBError {
            let detail: String
            if let errPtr = errorPtr {
                detail = String(cString: errPtr)
                duckdb_free(errPtr)
            } else {
                detail = "unknown error"
            }
            if let conflict = DuckDBLockConflict.parse(detail) {
                throw DuckDBPluginError.fileLocked(conflict)
            }
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(spec.path)': \(detail)"
            )
        }

        guard let openedDB = db else {
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(spec.path)'"
            )
        }

        do {
            try Self.connect(handles, to: openedDB)
        } catch {
            duckdb_close(&db)
            throw error
        }
        database = db
        taskThreads = DuckDBTaskThreads(database: openedDB)
    }

    // Both connections of `handles`, or neither.
    private static func connect(_ handles: DuckDBConnectionHandles, to database: duckdb_database) throws {
        var conn: duckdb_connection?
        guard duckdb_connect(database, &conn) != DuckDBError, let conn else {
            throw DuckDBPluginError.connectionFailed("Failed to create DuckDB connection")
        }
        var renderConn: duckdb_connection?
        do {
            guard duckdb_connect(database, &renderConn) != DuckDBError, let renderConn else {
                throw DuckDBPluginError.connectionFailed("Failed to create DuckDB connection")
            }
            handles.resultReader = try DuckDBResultReader(renderConnection: renderConn)
        } catch {
            if renderConn != nil { duckdb_disconnect(&renderConn) }
            var failedConnection: duckdb_connection? = conn
            duckdb_disconnect(&failedConnection)
            throw error
        }
        handles.connection = conn
        handles.renderConnection = renderConn
        handles.renderSettings = [:]
        handles.live.set(conn)
    }

    // A transfer connection left open would keep the file after the close.
    private func closeHandle() {
        for transfer in openDatabase.transferConnections.values {
            transfer.close()
        }
        openDatabase.transferConnections = [:]
        openDatabase.transferActors = [:]
        handles.close()
        taskThreads?.close()
        taskThreads = nil
        if database != nil {
            duckdb_close(&database)
            database = nil
        }
    }

    // MARK: - Release preconditions

    /// Recorded before the statement runs, not after. `duckdb_query` executes a batch until one
    /// statement fails, so `BEGIN; INSERT ...` can leave a transaction open and still throw. Noting
    /// it only on success would leave `hasOpenTransaction` false over a transaction that is
    /// genuinely open, and the next release would close the handle and roll it back.
    private func noteActivity(_ query: String) {
        lastActivity = ContinuousClock.now
        switch SQLTransactionTracking.effect(of: query, lexicalFeatures: DuckDBLexicalFeatures.features) {
        case .opens: hasOpenTransaction = true
        case .closes: hasOpenTransaction = false
        case .unchanged: break
        /// A case this build does not know about is treated as a transaction being open, which
        /// keeps the file rather than closing it over something unrecognised.
        @unknown default: hasOpenTransaction = true
        }
    }

    /// What the session has open, for a caller deciding whether it may open a transaction of its
    /// own on it.
    ///
    /// A released handle answers `.idle`: a release only happens over a session holding nothing, and
    /// reopening to ask would undo it. The probe itself never reopens for the same reason, and it
    /// runs outside `noteActivity`, so asking the question does not reset the idle clock the
    /// question is about.
    func sessionTransactionState() -> PluginSessionTransactionState {
        guard !isReleased else { return .idle }
        guard connection != nil else { return .unknown }
        // A probe statement would end the read being handed out.
        guard pulledRead == nil else { return .unknown }
        if let decided = DuckDBTransactionProbe.state(
            catalogType: probeReading(DuckDBTransactionProbe.catalogTypeQuery),
            tracksOpenTransaction: hasOpenTransaction
        ) {
            return decided
        }
        return DuckDBTransactionProbe.state(
            first: probeReading(DuckDBTransactionProbe.transactionIdQuery),
            second: probeReading(DuckDBTransactionProbe.transactionIdQuery)
        )
    }

    /// Runs one probe statement through `duckdb_query`, which is the only path that hands back the
    /// error *type*: a refusal because the transaction is aborted is the answer rather than a
    /// failure, and the message text is not a contract.
    private func probeReading(_ sql: String) -> DuckDBTransactionProbe.Reading {
        guard let conn = connection else { return .unreadable }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(conn, sql, &result) != DuckDBError else {
            return duckdb_result_error_type(&result) == DUCKDB_ERROR_TRANSACTION ? .abortedTransaction : .unreadable
        }
        guard duckdb_row_count(&result) > 0, let cell = duckdb_value_varchar(&result, 0, 0) else {
            return .unreadable
        }
        defer { duckdb_free(cell) }
        return .value(String(cString: cell))
    }

    /// Nil when nothing stands in the way of a release.
    private func heldSessionState() -> DuckDBReleaseOutcome? {
        if hasOpenTransaction { return .holdsOpenTransaction }
        guard let counts = try? readHeldStateCounts() else { return .stateUnreadable }
        if counts.sessionObjects > 0 { return .holdsSessionObjects }
        if counts.catalogs > 1 { return .holdsAttachedCatalogs }
        guard let settings = try? readSettings() else { return .stateUnreadable }
        return settings == baselineSettings ? nil : .holdsChangedSettings
    }

    private func readHeldStateCounts() throws -> (catalogs: Int, sessionObjects: Int) {
        // Unprepared: a prepare would count its own temporary prepared statement.
        let result = try runInternalQuery(DuckDBSchemaQueries.sessionHeldState(
            excluding: configuredAttachments,
            readOnly: attachmentsReadOnly
        ))
        guard let row = result.rows.first, row.count >= 2 else {
            throw DuckDBPluginError.queryFailed("DuckDB reported no session state")
        }
        let values = row.compactMap { $0.asText.flatMap(Int.init) }
        guard values.count >= 2 else {
            throw DuckDBPluginError.queryFailed("DuckDB reported unreadable session state")
        }
        return (catalogs: values[0], sessionObjects: values[1])
    }

    /// The settings the driver moves itself, which a reopen replays from `sessionSetup` and which
    /// therefore must not read as the user having changed something. `search_path` and `schema`
    /// are not set directly: `USE` writes where it landed into both, so every database or schema
    /// switch would otherwise look like a changed setting and no connection would ever release.
    private static let driverOwnedSettings: Set<String> = [
        "search_path",
        "schema",
        "autoinstall_known_extensions",
        "autoload_known_extensions",
        "access_mode",
    ]

    private func readSettings() throws -> [String: String] {
        let result = try runInternalQuery(DuckDBSchemaQueries.allSettings)
        var settings: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, !Self.driverOwnedSettings.contains(name) else { continue }
            settings[name] = row[safe: 1]?.asText ?? ""
        }
        return settings
    }

    // Leaves `lastActivity` and the transaction flag alone: counting the release check as use would keep resetting the
    // idle clock it asks about.
    private func runInternalQuery(_ query: String) throws -> DuckDBRawResult {
        guard let conn = connection else { throw DuckDBPluginError.notConnected }
        let startTime = Date()
        var opened = try openQueryResult(query, connection: conn)
        defer { close(&opened, on: conn) }
        return try extractResult(from: opened, limit: PluginRowLimits.emergencyMax, startTime: startTime)
    }

    @discardableResult
    private func runSetup(_ statement: String) throws -> DuckDBRawResult {
        try runInternalQuery(statement)
    }

    // MARK: - Execution

    private nonisolated struct OpenedResult {
        var result: duckdb_result
        let schema: ColumnSchema
        let rowsChanged: idx_t
        // Nil for a streaming result, whose length is unknown until it ends.
        let rowCount: idx_t?
        let abandonsUnreadRows: Bool
        // The transaction the driver opened for the prepare, committed once the streamed result ends.
        var endsTransaction = false

        var isStreaming: Bool { rowCount == nil }
    }

    // A prepare commits nothing on its own (DuckDBPreparedRun): a statement that does not stream runs unprepared,
    // and one that does is prepared inside the session's transaction or one the driver opens. Only a session DuckDB
    // says holds none gets one, since a BEGIN inside one aborts it.
    private func openResult(
        query: String,
        parameters: [PluginCellValue],
        connection: duckdb_connection,
        unread: DuckDBUnreadRows,
        session known: PluginSessionTransactionState? = nil
    ) throws -> OpenedResult {
        guard !parameters.isEmpty || DuckDBPreparedRun.streams(query) else {
            return try openQueryResult(query, connection: connection)
        }
        let session = known ?? sessionTransactionState()
        var ownsTransaction = false
        var refusedBegin: String?
        if session == .idle {
            refusedBegin = DuckDBPreparedRun.begin(on: connection)
            ownsTransaction = refusedBegin == nil
        }
        let joinsTransaction = session == .inTransaction || (session == .abortedTransaction && !parameters.isEmpty)
        guard ownsTransaction || joinsTransaction else {
            guard parameters.isEmpty else {
                throw DuckDBPluginError.queryFailed(refusedBegin ?? String(
                    localized: "DuckDB could not say whether this session holds a transaction, so the statement did not run."
                ))
            }
            return try openQueryResult(query, connection: connection)
        }
        var opened: OpenedResult
        do {
            opened = try openPreparedResult(
                query: query, parameters: parameters, connection: connection,
                abandonsUnreadRows: unread.abandons { session == .idle }
            )
        } catch {
            if ownsTransaction { DuckDBPreparedRun.rollback(on: connection) }
            throw error
        }
        guard ownsTransaction else { return opened }
        guard !opened.isStreaming else {
            opened.endsTransaction = true
            return opened
        }
        if let failure = DuckDBPreparedRun.commit(on: connection) {
            duckdb_destroy_result(&opened.result)
            throw DuckDBPluginError.queryFailed(failure)
        }
        return opened
    }

    // A SELECT that may write and was left unread aborts the transaction, which the COMMIT then ends.
    private func finish(_ opened: inout OpenedResult, on connection: duckdb_connection) throws {
        duckdb_destroy_result(&opened.result)
        guard opened.endsTransaction else { return }
        opened.endsTransaction = false
        if let failure = DuckDBPreparedRun.commit(on: connection) {
            throw DuckDBPluginError.queryFailed(failure)
        }
    }

    // What a failed or cancelled read leaves.
    private func close(_ opened: inout OpenedResult, on connection: duckdb_connection) {
        duckdb_destroy_result(&opened.result)
        if opened.endsTransaction { DuckDBPreparedRun.rollback(on: connection) }
    }

    // duckdb_query runs each statement of a text, and one statement at a time lets the task threads follow each.
    private func openQueryResult(_ query: String, connection: duckdb_connection) throws -> OpenedResult {
        var extracted: duckdb_extracted_statements?
        defer { duckdb_destroy_extracted(&extracted) }
        let count = duckdb_extract_statements(connection, query, &extracted)
        if let failure = duckdb_extract_statements_error(extracted) {
            throw DuckDBPluginError.queryFailed(String(cString: failure))
        }
        guard count <= 1 else {
            throw DuckDBPluginError.queryFailed(String(
                format: String(localized: "DuckDB reads %lld statements in this text. Run them one at a time."),
                Int64(count)
            ))
        }

        var result = duckdb_result()
        let state = duckdb_query(connection, query, &result)
        let statementType = duckdb_result_statement_type(result)
        if !DuckDBTaskThreads.keepsCount(statementType) {
            taskThreads?.followCount()
        }
        guard state != DuckDBError else {
            let message = Self.errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        alignRenderSession(for: (0..<duckdb_column_count(&result)).map { duckdb_column_type(&result, $0) }, on: connection)
        return Self.materialized(result, statementType: statementType)
    }

    private func openPreparedResult(
        query: String, parameters: [PluginCellValue], connection: duckdb_connection, abandonsUnreadRows: Bool
    ) throws -> OpenedResult {
        var stmtOpt: duckdb_prepared_statement?
        let prepareState = duckdb_prepare(connection, query, &stmtOpt)
        defer { duckdb_destroy_prepare(&stmtOpt) }

        guard prepareState != DuckDBError, let stmt = stmtOpt else {
            var message = "Failed to prepare statement"
            if let failed = stmtOpt, let pointer = duckdb_prepare_error(failed) {
                message = String(cString: pointer)
            }
            throw DuckDBPluginError.queryFailed(message)
        }

        try Self.bind(parameters, to: stmt)
        // Result metadata reports EXECUTE, so affected counts need the prepared statement's original kind.
        let statementType = duckdb_prepared_statement_type(stmt)
        // Only a SELECT streams. A statement that changes rows takes effect when its result ends, so it runs whole.
        let streams = statementType == DUCKDB_STATEMENT_TYPE_SELECT

        // It reads the session, which a streaming result keeps busy from here until it ends.
        alignRenderSession(
            for: (0..<duckdb_prepared_statement_column_count(stmt)).map { duckdb_prepared_statement_column_type(stmt, $0) },
            on: connection
        )

        var result = duckdb_result()
        let state = streams ? duckdb_execute_prepared_streaming(stmt, &result) : duckdb_execute_prepared(stmt, &result)
        if !DuckDBTaskThreads.keepsCount(statementType) {
            taskThreads?.followCount()
        }
        guard state != DuckDBError else {
            let message = Self.errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }

        guard !duckdb_result_is_streaming(result) else {
            return OpenedResult(
                result: result, schema: Self.schema(of: &result), rowsChanged: 0, rowCount: nil,
                abandonsUnreadRows: streams && abandonsUnreadRows
            )
        }
        return Self.materialized(result, statementType: statementType)
    }

    private static func materialized(_ result: duckdb_result, statementType: duckdb_statement_type) -> OpenedResult {
        var result = result
        let rowCount = duckdb_row_count(&result)
        var rowsChanged = duckdb_rows_changed(&result)
        if rowsChanged == 0, duckdb_result_return_type(result) == DUCKDB_RESULT_TYPE_QUERY_RESULT {
            switch statementType {
            case DUCKDB_STATEMENT_TYPE_INSERT, DUCKDB_STATEMENT_TYPE_UPDATE, DUCKDB_STATEMENT_TYPE_DELETE:
                // RETURNING carries the changed rows themselves instead of a separate count.
                rowsChanged = rowCount
            default:
                break
            }
        }
        return OpenedResult(
            result: result, schema: schema(of: &result), rowsChanged: rowsChanged, rowCount: rowCount,
            abandonsUnreadRows: true
        )
    }

    private static let typesSpelledBySession: Set<DuckDBLogicalType> = [.timestampTz, .list, .array, .structure, .map, .union]

    // TIMESTAMPTZ text follows the session's time zone and calendar, which each connection holds for itself.
    private func alignRenderSession(for columnTypes: [duckdb_type], on connection: duckdb_connection) {
        guard let resultReader else { return }
        let followsSession = columnTypes.contains { columnType in
            guard let type = Self.logicalType(for: columnType) else { return true }
            return Self.typesSpelledBySession.contains(type)
        }
        guard followsSession else { return }

        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, DuckDBRenderSettings.readQuery, &result) == DuckDBSuccess else { return }
        var wanted: [String: String] = [:]
        for row in 0..<duckdb_row_count(&result) {
            guard let name = duckdb_value_varchar(&result, 0, row) else { continue }
            defer { duckdb_free(name) }
            guard let value = duckdb_value_varchar(&result, 1, row) else { continue }
            defer { duckdb_free(value) }
            wanted[String(cString: name)] = String(cString: value)
        }
        for assignment in DuckDBRenderSettings.assignments(from: renderSettings, to: wanted) {
            guard resultReader.send(assignment) else { return }
        }
        renderSettings.merge(wanted) { _, new in new }
    }

    private static func bind(_ parameters: [PluginCellValue], to stmt: duckdb_prepared_statement) throws {
        for (index, parameter) in parameters.enumerated() {
            let position = idx_t(index + 1)
            let state: duckdb_state
            switch parameter {
            case .null:
                state = duckdb_bind_null(stmt, position)
            case .text(let value):
                state = duckdb_bind_varchar_length(stmt, position, value, idx_t(value.utf8.count))
            case .bytes(let data):
                // An empty Data has no base address, and a null pointer binds NULL rather than an empty blob.
                let bytes = data.isEmpty ? Data([0]) : data
                state = bytes.withUnsafeBytes { buffer in
                    duckdb_bind_blob(stmt, position, buffer.baseAddress, idx_t(data.count))
                }
            }
            if state == DuckDBError {
                throw DuckDBPluginError.queryFailed("Failed to bind parameter at index \(index)")
            }
        }
    }

    private static func errorMessage(from result: inout duckdb_result) -> String {
        guard let pointer = duckdb_result_error(&result) else { return "Unknown DuckDB error" }
        return String(cString: pointer)
    }

    // MARK: - Extraction

    private nonisolated struct ColumnSchema {
        let names: [String]
        let logicalTypes: [DuckDBLogicalType?]

        var typeNames: [String] {
            logicalTypes.map { $0?.displayName ?? DuckDBLogicalType.varchar.displayName }
        }

        var projectionColumns: [(name: String, type: DuckDBLogicalType?)] {
            Array(zip(names, logicalTypes)).map { (name: $0.0, type: $0.1) }
        }
    }

    private static func schema(of result: inout duckdb_result) -> ColumnSchema {
        let columnCount = duckdb_column_count(&result)
        var names: [String] = []
        var logicalTypes: [DuckDBLogicalType?] = []

        for index in 0..<columnCount {
            if let pointer = duckdb_column_name(&result, index) {
                names.append(String(cString: pointer))
            } else {
                names.append("column_\(index)")
            }
            logicalTypes.append(logicalType(for: duckdb_column_type(&result, index)))
        }

        return ColumnSchema(names: names, logicalTypes: logicalTypes)
    }

    // With `byteLimit` the read stops at the row that takes the decoded rows past it and keeps that row. A chunk is
    // decoded whole before it is measured.
    private func extractResult(
        from opened: OpenedResult,
        limit: Int,
        byteLimit: Int? = nil,
        startTime: Date
    ) throws -> DuckDBRawResult {
        var rows: [[PluginCellValue]] = []
        if let rowCount = opened.rowCount {
            rows.reserveCapacity(Int(min(rowCount, UInt64(max(0, limit)))))
        }

        var budget = DuckDBFetchBudget(limit: limit)
        var bytes = 0
        var stoppedAtByteLimit = false
        let reachedEnd = try readRows(of: opened) { batch in
            let kept = budget.take(batch.count)
            var slice = kept == batch.count ? batch[...] : batch.prefix(kept)
            if let byteLimit {
                for (offset, row) in slice.enumerated() {
                    bytes += Self.decodedByteCount(of: row)
                    guard bytes > byteLimit else { continue }
                    slice = slice.prefix(offset + 1)
                    stoppedAtByteLimit = true
                    break
                }
            }
            rows.append(contentsOf: slice)
            return !budget.isExceeded && !stoppedAtByteLimit
        }
        if !reachedEnd {
            try finishUnreadRows(of: opened)
        }

        return DuckDBRawResult(
            columns: opened.schema.names,
            columnTypeNames: opened.schema.typeNames,
            rows: rows,
            rowsAffected: Int(opened.rowsChanged),
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: budget.isExceeded || stoppedAtByteLimit
        )
    }

    // Text as UTF-8, bytes as they are, null as nothing: never more than the host counts for the same row, so a read
    // never stops before the host's own budget is full.
    static func decodedByteCount(of row: [PluginCellValue]) -> Int {
        row.reduce(0) { total, cell in
            switch cell {
            case .null: total
            case .text(let text): total + text.utf8.count
            case .bytes(let data): total + data.count
            }
        }
    }

    // True when the consumer went away. The caller finishes the stream once the read's transaction ended.
    private func streamResultRows(
        _ opened: OpenedResult,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws -> Bool {
        continuation.yield(.header(PluginStreamHeader(
            columns: opened.schema.names,
            columnTypeNames: opened.schema.typeNames,
            estimatedRowCount: opened.rowCount.map { Int($0) }
        )))

        var cancelled = false
        let reachedEnd: Bool
        do {
            reachedEnd = try readRows(of: opened) { batch in
                cancelled = Task.isCancelled
                    || !DuckDBBoundedStream.deliver(PluginStreamElement.rows(batch), to: continuation)
                return !cancelled
            }
        } catch is CancellationError {
            try finishUnreadRows(of: opened)
            throw CancellationError()
        }
        if !reachedEnd {
            try finishUnreadRows(of: opened)
        }
        return cancelled
    }

    private static func end(
        _ continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation, cancelled: Bool
    ) {
        if cancelled {
            continuation.finish(throwing: CancellationError())
        } else {
            continuation.finish()
        }
    }

    // Returns false when `body` stopped the read before the result ended.
    @discardableResult
    private func readRows(of opened: OpenedResult, body: ([[PluginCellValue]]) -> Bool) throws -> Bool {
        var projection: duckdb_prepared_statement?
        defer { duckdb_destroy_prepare(&projection) }
        while let batch = try nextBatch(of: opened, projection: &projection, reading: { _, value in value.pluginValue }) {
            guard body(batch) else { return false }
        }
        return true
    }

    // The next chunk that holds rows, nil at the end of the result. `projection` renders it, prepared on first use.
    private func nextBatch<Value>(
        of opened: OpenedResult,
        projection: inout duckdb_prepared_statement?,
        reading read: DuckDBValueReader<Value>
    ) throws -> [[Value]]? {
        var source = opened.result
        while true {
            // A statement that ran whole has already taken effect, so its rows are still handed back.
            if opened.isStreaming { try Task.checkCancellation() }
            var chunk = duckdb_fetch_chunk(source)
            guard let fetched = chunk else {
                if let message = duckdb_result_error(&source) {
                    throw DuckDBPluginError.queryFailed(String(cString: message))
                }
                return nil
            }
            defer { duckdb_destroy_data_chunk(&chunk) }
            guard duckdb_data_chunk_get_size(fetched) > 0 else { continue }

            guard DuckDBLogicalType.requiresTextProjection(anyOf: opened.schema.logicalTypes) else {
                return Self.rows(of: fetched, types: Self.storageTypes(of: &source), names: opened.schema.names, reading: read)
            }
            guard let resultReader else { throw DuckDBPluginError.notConnected }
            if projection == nil {
                projection = try resultReader.prepareProjection(of: source, columns: opened.schema.projectionColumns)
            }
            guard let projection else { throw DuckDBPluginError.notConnected }
            var rendered = try resultReader.render(fetched, of: source, with: projection)
            defer { duckdb_destroy_result(&rendered) }
            return try Self.renderedRows(of: &rendered, names: opened.schema.names, reading: read)
        }
    }

    // A consumer that stops reading inside a transaction must not abort it: a SELECT calling nextval left unfinished
    // fails the transaction (scripts/probes/check-duckdb-streaming-results.sh).
    private func finishUnreadRows(of opened: OpenedResult) throws {
        guard opened.isStreaming, !opened.abandonsUnreadRows else { return }
        try Self.drain(opened.result)
    }

    // Completes a statement whose rows are no longer wanted, so that what it changed is kept.
    private static func drain(_ result: duckdb_result) throws {
        var source = result
        while true {
            var chunk = duckdb_fetch_chunk(source)
            guard chunk != nil else {
                if let message = duckdb_result_error(&source) {
                    throw DuckDBPluginError.queryFailed(String(cString: message))
                }
                return
            }
            duckdb_destroy_data_chunk(&chunk)
        }
    }

    private static func renderedRows<Value>(
        of rendered: inout duckdb_result,
        names: [String],
        reading read: DuckDBValueReader<Value>
    ) throws -> [[Value]] {
        let types = storageTypes(of: &rendered)
        var batch: [[Value]] = []
        while true {
            var chunk = duckdb_fetch_chunk(rendered)
            guard let fetched = chunk else {
                if let message = duckdb_result_error(&rendered) {
                    throw DuckDBPluginError.queryFailed(String(cString: message))
                }
                return batch
            }
            defer { duckdb_destroy_data_chunk(&chunk) }
            batch.append(contentsOf: rows(of: fetched, types: types, names: names, reading: read))
        }
    }

    private static func storageTypes(of result: inout duckdb_result) -> [duckdb_type] {
        (0..<duckdb_column_count(&result)).map { duckdb_column_type(&result, $0) }
    }

    private static func rows<Value>(
        of chunk: duckdb_data_chunk,
        types: [duckdb_type],
        names: [String],
        reading read: DuckDBValueReader<Value>
    ) -> [[Value]] {
        let size = duckdb_data_chunk_get_size(chunk)
        let vectors = types.indices.map { duckdb_data_chunk_get_vector(chunk, idx_t($0)) }
        var batch: [[Value]] = []
        batch.reserveCapacity(Int(size))
        for row in 0..<size {
            batch.append(types.indices.map { column in
                read(column < names.count ? names[column] : "", chunkValue(vectors[column], type: types[column], row: row))
            })
        }
        return batch
    }

    private static func chunkValue(_ vector: duckdb_vector?, type: duckdb_type, row: idx_t) -> DuckDBChunkValue {
        guard let vector, let data = duckdb_vector_get_data(vector) else { return .null }
        if let validity = duckdb_vector_get_validity(vector), !duckdb_validity_row_is_valid(validity, row) {
            return .null
        }
        let index = Int(row)
        switch type {
        case DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BLOB:
            let element = data.assumingMemoryBound(to: duckdb_string_t.self) + index
            let bytes = UnsafeRawBufferPointer(
                start: duckdb_string_t_data(element), count: Int(duckdb_string_t_length(element.pointee))
            )
            return type == DUCKDB_TYPE_BLOB ? .bytes(bytes) : .text(bytes)
        case DUCKDB_TYPE_BOOLEAN:
            return .spelled(data.assumingMemoryBound(to: UInt8.self)[index] != 0 ? "true" : "false")
        case DUCKDB_TYPE_TINYINT:
            return .spelled(String(data.assumingMemoryBound(to: Int8.self)[index]))
        case DUCKDB_TYPE_SMALLINT:
            return .spelled(String(data.assumingMemoryBound(to: Int16.self)[index]))
        case DUCKDB_TYPE_INTEGER:
            return .spelled(String(data.assumingMemoryBound(to: Int32.self)[index]))
        case DUCKDB_TYPE_BIGINT:
            return .spelled(String(data.assumingMemoryBound(to: Int64.self)[index]))
        case DUCKDB_TYPE_UTINYINT:
            return .spelled(String(data.assumingMemoryBound(to: UInt8.self)[index]))
        case DUCKDB_TYPE_USMALLINT:
            return .spelled(String(data.assumingMemoryBound(to: UInt16.self)[index]))
        case DUCKDB_TYPE_UINTEGER:
            return .spelled(String(data.assumingMemoryBound(to: UInt32.self)[index]))
        case DUCKDB_TYPE_UBIGINT:
            return .spelled(String(data.assumingMemoryBound(to: UInt64.self)[index]))
        default:
            return .null
        }
    }

    static func logicalType(for type: duckdb_type) -> DuckDBLogicalType? {
        switch type {
        case DUCKDB_TYPE_BOOLEAN: return .boolean
        case DUCKDB_TYPE_TINYINT: return .tinyint
        case DUCKDB_TYPE_SMALLINT: return .smallint
        case DUCKDB_TYPE_INTEGER: return .integer
        case DUCKDB_TYPE_BIGINT: return .bigint
        case DUCKDB_TYPE_UTINYINT: return .utinyint
        case DUCKDB_TYPE_USMALLINT: return .usmallint
        case DUCKDB_TYPE_UINTEGER: return .uinteger
        case DUCKDB_TYPE_UBIGINT: return .ubigint
        case DUCKDB_TYPE_FLOAT: return .float
        case DUCKDB_TYPE_DOUBLE: return .double
        case DUCKDB_TYPE_DECIMAL: return .decimal
        case DUCKDB_TYPE_HUGEINT: return .hugeint
        case DUCKDB_TYPE_UHUGEINT: return .uhugeint
        case DUCKDB_TYPE_VARCHAR: return .varchar
        case DUCKDB_TYPE_BLOB: return .blob
        case DUCKDB_TYPE_DATE: return .date
        case DUCKDB_TYPE_TIME: return .time
        case DUCKDB_TYPE_TIME_NS: return .timeNs
        case DUCKDB_TYPE_INTERVAL: return .interval
        case DUCKDB_TYPE_TIMESTAMP: return .timestamp
        case DUCKDB_TYPE_TIMESTAMP_S: return .timestampSeconds
        case DUCKDB_TYPE_TIMESTAMP_MS: return .timestampMilliseconds
        case DUCKDB_TYPE_TIMESTAMP_NS: return .timestampNanoseconds
        case DUCKDB_TYPE_TIMESTAMP_TZ: return .timestampTz
        case DUCKDB_TYPE_TIME_TZ: return .timeTz
        case DUCKDB_TYPE_BIT: return .bit
        case DUCKDB_TYPE_UUID: return .uuid
        case DUCKDB_TYPE_ENUM: return .enumeration
        case DUCKDB_TYPE_LIST: return .list
        case DUCKDB_TYPE_ARRAY: return .array
        case DUCKDB_TYPE_STRUCT: return .structure
        case DUCKDB_TYPE_MAP: return .map
        case DUCKDB_TYPE_UNION: return .union
        case DUCKDB_TYPE_BIGNUM: return .bignum
        case DUCKDB_TYPE_GEOMETRY: return .geometry
        default: return nil
        }
    }
}

nonisolated struct DuckDBRawResult: @unchecked Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    var rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}
