//
//  FreeTDSConnection.swift
//  TablePro
//
//  Dual-ownership: compiled into BOTH the macOS MSSQLDriver plugin target
//  (Plugins/MSSQLDriverPlugin/ is its FileSystemSynchronizedRootGroup) AND the
//  iOS TableProMobile target (via the cross-project file reference at
//  TableProMobile/TableProMobile.xcodeproj path = ../Plugins/MSSQLDriverPlugin/...).
//  Edits here ship to both platforms, so keep the API neutral (no PluginKit deps).
//

import CFreeTDS
import Darwin
import Foundation
import os
import TableProCoreTypes
import TableProMSSQLCore

nonisolated private let freetdsLogger = Logger(subsystem: "com.TablePro", category: "FreeTDSConnection")

/// What one connection's current request has said, collected by the process-wide handlers db-lib calls.
///
/// Every server message is kept in arrival order, because a batch keeps going past most errors and the only place an
/// error inside a `SELECT` shows up is the message handler. Both kinds are capped so a loop that prints or fails on
/// every pass cannot grow this without bound; the first errors are the ones kept, because the first is what a run
/// reports. It is always mutated in place: the handlers run under a process-wide lock, and copying the log out to
/// append one message made a batch raising 50,000 errors spend 22 seconds in the handler.
nonisolated private struct FreeTDSDiagnostics {
    static let outputMessageLimit = 1_000
    static let errorMessageLimit = 1_000

    var messages: [MSSQLServerMessage] = []
    var outputMessageCount = 0
    var outputTruncated = false
    var outputTaken = false
    var errorMessageCount = 0
    var droppedErrorCount = 0
    var libraryError = ""
    var connectionEnded = false

    mutating func record(_ message: MSSQLServerMessage) {
        if message.isError {
            guard errorMessageCount < Self.errorMessageLimit || message.endsConnection else {
                droppedErrorCount += 1
                return
            }
            errorMessageCount += 1
            messages.append(message)
            return
        }
        guard outputMessageCount < Self.outputMessageLimit else {
            outputTruncated = true
            return
        }
        outputMessageCount += 1
        messages.append(message)
    }

    mutating func recordLibraryError(_ text: String, number: Int) {
        if libraryError.isEmpty { libraryError = text }
        if MSSQLLibraryError.endsConnection(number) { connectionEnded = true }
    }
}

nonisolated private struct FreeTDSErrorState {
    var perConnection: [UInt: FreeTDSDiagnostics] = [:]
    var global = ""
}

nonisolated private let freetdsErrors = OSAllocatedUnfairLock(initialState: FreeTDSErrorState())

nonisolated private func freetdsConnectionKey(_ dbproc: UnsafeMutablePointer<DBPROCESS>) -> UInt {
    UInt(bitPattern: UnsafeRawPointer(dbproc))
}

nonisolated private func freetdsGetError(for dbproc: UnsafeMutablePointer<DBPROCESS>?) -> String {
    let key = dbproc.map(freetdsConnectionKey)
    return freetdsErrors.withLock { state in
        guard let key, let diagnostics = state.perConnection[key] else { return state.global }
        if let error = diagnostics.messages.first(where: \.isError) {
            return error.text
        }
        return diagnostics.libraryError.isEmpty ? state.global : diagnostics.libraryError
    }
}

nonisolated private func freetdsClearError(for dbproc: UnsafeMutablePointer<DBPROCESS>?) {
    let key = dbproc.map(freetdsConnectionKey)
    freetdsErrors.withLock { state in
        guard let key else {
            state.global = ""
            return
        }
        state.perConnection[key] = FreeTDSDiagnostics()
    }
}

nonisolated private func freetdsDiagnostics(for dbproc: UnsafeMutablePointer<DBPROCESS>) -> FreeTDSDiagnostics {
    let key = freetdsConnectionKey(dbproc)
    return freetdsErrors.withLock { $0.perConnection[key] ?? FreeTDSDiagnostics() }
}

/// The output of the connection's latest request, handed over once.
nonisolated private func freetdsTakeOutput(
    for dbproc: UnsafeMutablePointer<DBPROCESS>
) -> (lines: [String], isTruncated: Bool) {
    let key = freetdsConnectionKey(dbproc)
    return freetdsErrors.withLock { state in
        guard state.perConnection[key]?.outputTaken == false else { return ([], false) }
        state.perConnection[key]?.outputTaken = true
        guard let diagnostics = state.perConnection[key] else { return ([], false) }
        return (diagnostics.messages.filter(\.isOutput).map(\.text), diagnostics.outputTruncated)
    }
}

/// The messages the connection's current request received from `index` on, so a reader that asks after every result
/// copies only what is new.
nonisolated private func freetdsMessages(
    for dbproc: UnsafeMutablePointer<DBPROCESS>,
    from index: Int
) -> (messages: [MSSQLServerMessage], droppedErrorCount: Int) {
    let key = freetdsConnectionKey(dbproc)
    return freetdsErrors.withLock { state in
        guard let diagnostics = state.perConnection[key] else { return ([], 0) }
        let arrived = diagnostics.messages.count > index ? Array(diagnostics.messages[index...]) : []
        return (arrived, diagnostics.droppedErrorCount)
    }
}

nonisolated private func freetdsRecordMessage(_ message: MSSQLServerMessage, for dbproc: UnsafeMutablePointer<DBPROCESS>?) {
    guard let dbproc else {
        guard message.isError else { return }
        freetdsErrors.withLock { $0.global = message.text }
        return
    }
    let key = freetdsConnectionKey(dbproc)
    freetdsErrors.withLock { state in
        state.perConnection[key, default: FreeTDSDiagnostics()].record(message)
    }
}

nonisolated private func freetdsRecordLibraryError(
    _ text: String,
    number: Int,
    for dbproc: UnsafeMutablePointer<DBPROCESS>?
) {
    guard number != MSSQLLibraryError.serverMessageNotice else { return }
    guard let dbproc else {
        freetdsErrors.withLock { state in
            if state.global.isEmpty { state.global = text }
        }
        return
    }
    let key = freetdsConnectionKey(dbproc)
    freetdsErrors.withLock { state in
        state.perConnection[key, default: FreeTDSDiagnostics()].recordLibraryError(text, number: number)
    }
}

nonisolated private func freetdsUnregister(_ dbproc: UnsafeMutablePointer<DBPROCESS>) {
    let key = freetdsConnectionKey(dbproc)
    freetdsErrors.withLock { $0.perConnection[key] = nil }
    freetdsGates.withLock { $0[key] = nil }
}

nonisolated private let freetdsConfigFile = MSSQLFreeTDSConfigFile(
    path: (NSTemporaryDirectory() as NSString).appendingPathComponent("tablepro-freetds-\(UUID().uuidString).conf")
)

/// Each open connection's gate, found by its DBPROCESS, because db-lib's interrupt and error handlers are C functions
/// that receive nothing else. A gate stays registered until the queue closes its handle: a read that a Stop or a
/// disconnect is ending finds the interrupt through it, and without it the read ran on until the server finished.
nonisolated private let freetdsGates = OSAllocatedUnfairLock(initialState: [UInt: MSSQLRequestGate]())

nonisolated private func freetdsRegister(_ gate: MSSQLRequestGate, for dbproc: UnsafeMutablePointer<DBPROCESS>) {
    let key = freetdsConnectionKey(dbproc)
    freetdsGates.withLock { $0[key] = gate }
}

nonisolated private func freetdsGate(forKey key: UInt) -> MSSQLRequestGate? {
    freetdsGates.withLock { $0[key] }
}

/// db-lib's interrupt pair. The check runs once a second on the thread waiting on the socket; answering `INT_CANCEL`
/// ends that wait as a timeout, which the error handler turns into an attention sent from the same thread.
nonisolated private let freetdsInterruptCheck: DB_DBCHKINTR_FUNC = { dbproc in
    guard let gate = freetdsGate(forKey: UInt(bitPattern: dbproc)), gate.isInterruptRaised else { return 0 }
    return 1
}

nonisolated private let freetdsInterruptHandler: DB_DBHNDLINTR_FUNC = { _ in INT_CANCEL }

nonisolated private let freetdsInitOnce: Void = {
    _ = dbinit()
    freetdsConfigFile.path.withCString { dbsetifile(UnsafeMutablePointer(mutating: $0)) }
    _ = dberrhandle { dbproc, _, dberr, _, dberrstr, oserrstr in
        if dberr == SYBETIME, let dbproc, freetdsGate(forKey: freetdsConnectionKey(dbproc))?.takeInterrupt() == true {
            freetdsLogger.debug("FreeTDS: a Stop interrupted the wait, sending the attention")
            return INT_TIMEOUT
        }
        var msg = "db-lib error \(dberr)"
        if let s = dberrstr { msg += ": \(String(cString: s))" }
        if let s = oserrstr, String(cString: s) != "Success" { msg += " (os: \(String(cString: s)))" }
        freetdsLogger.error("FreeTDS: \(msg)")
        freetdsRecordLibraryError(msg, number: Int(dberr), for: dbproc)
        return INT_CANCEL
    }
    _ = dbmsghandle { dbproc, msgno, msgstate, severity, msgtext, _, procname, line in
        guard let text = msgtext else { return 0 }
        let message = MSSQLServerMessage(
            number: Int(msgno),
            severity: Int(severity),
            state: Int(msgstate),
            line: Int(line),
            procedure: procname.map { String(cString: $0) } ?? "",
            text: String(cString: text)
        )
        if message.isError {
            freetdsLogger.error("FreeTDS msg \(msgno) sev \(severity): \(message.text)")
        } else {
            freetdsLogger.debug("FreeTDS msg \(msgno): \(message.text)")
        }
        freetdsRecordMessage(message, for: dbproc)
        return 0
    }
}()

nonisolated private func freetdsDispatchAsync<T: Sendable>(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let result = try work()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

nonisolated private func freetdsDispatchAsync(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.async {
            do {
                try work()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// nonisolated so this file compiles cleanly under TableProMobile's
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor build setting. The class manages its own
// thread safety via a private serial DispatchQueue and NSLock; no main-actor hop needed.
nonisolated final class FreeTDSConnection: @unchecked Sendable {
    private var dbproc: UnsafeMutablePointer<DBPROCESS>?
    private let queue: DispatchQueue
    private let options: MSSQLConnectionOptions
    private let lock = NSLock()
    private var _isConnected = false

    /// Which calls a Stop reaches. A Stop and a disconnect are the only things here that run off the queue, so they
    /// stop a call through this gate and never through db-lib.
    private let requestGate = MSSQLRequestGate()

    private static let kerberosEnvLock = NSLock()
    private static let deadlineQueue = DispatchQueue(label: "com.TablePro.freetds.connect-deadline", qos: .userInitiated)
    private static let connectDeadlineMarginSeconds = 5

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(options: MSSQLConnectionOptions) {
        self.options = options
        self.queue = DispatchQueue(label: "com.TablePro.freetds.\(options.host).\(options.port)", qos: .userInitiated)
        _ = freetdsInitOnce
    }

    func connect() async throws {
        let attempt = SingleResumeGate<Void>()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                attempt.install(continuation, alreadyCancelled: Task.isCancelled)
                queue.async { [self] in
                    do {
                        let proc = try openConnection(for: attempt)
                        if attempt.win(()) {
                            adopt(proc)
                        } else {
                            teardown(proc)
                        }
                    } catch {
                        attempt.fail(error)
                    }
                }
            }
        } onCancel: {
            attempt.fail(CancellationError())
            freetdsConfigFile.interruptWaits()
        }
    }

    /// db-lib reads the encryption level, the certificate checks and the service principal from freetds.conf and from
    /// nowhere else, so the server is described there rather than on the login. Waiting for the entry and logging in
    /// are bounded apart, each by the login timeout: the wait is for another connection's dbopen to the same server
    /// name, and a single deadline over both would fail this one as a timeout without ever trying it.
    ///
    /// The Kerberos ticket cache handed over for this connect is deleted here, however the connect ends, because this
    /// is the one place that runs to the end of the attempt: the caller can give up while dbopen still reads the cache.
    private func openConnection(for attempt: SingleResumeGate<Void>) throws -> UnsafeMutablePointer<DBPROCESS> {
        defer { discardKerberosCache() }
        let entry: MSSQLFreeTDSServerEntry
        do {
            entry = try MSSQLFreeTDSServerEntry(options: options)
        } catch {
            throw MSSQLCoreError.connectionFailed(error.localizedDescription)
        }
        guard let login = dblogin() else {
            throw MSSQLCoreError.connectionFailed("Failed to create login")
        }
        defer { dbloginfree(login) }
        try configure(login)

        let opened: UnsafeMutablePointer<DBPROCESS>?
        do {
            opened = try freetdsConfigFile.withEntry(
                entry,
                waitingAtMost: TimeInterval(connectDeadlineSeconds),
                givingUpWhen: { attempt.isSettled }
            ) {
                guard !attempt.isSettled else { throw CancellationError() }
                armDeadline(for: attempt)
                freetdsClearError(for: nil)
                return withKerberosEnvironmentIfNeeded { dbopen(login, entry.name) }
            }
        } catch let error as MSSQLFreeTDSConfigError {
            throw MSSQLCoreError.connectionFailed(error.localizedDescription)
        }
        guard let proc = opened else {
            throw openFailure()
        }
        return proc
    }

    private var connectDeadlineSeconds: Int {
        options.loginTimeoutSeconds + Self.connectDeadlineMarginSeconds
    }

    private func armDeadline(for attempt: SingleResumeGate<Void>) {
        let isKerberos = options.authMethod == .windows
        Self.deadlineQueue.asyncAfter(deadline: .now() + .seconds(connectDeadlineSeconds)) {
            attempt.fail(MSSQLCoreError.connectionTimedOut(isKerberos: isKerberos))
        }
    }

    private func discardKerberosCache() {
        guard let cachePath = options.kerberosCachePath else { return }
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    private func configure(_ login: UnsafeMutablePointer<LOGINREC>) throws {
        for parameter in MSSQLLoginParameters.build(
            user: options.user,
            password: options.password,
            applicationName: options.applicationName,
            database: options.database
        ) {
            guard dbsetlname(login, parameter.value, parameter.field.dbsetName) == SUCCEED else {
                throw MSSQLCoreError.connectionFailed(parameter.field.refusal)
            }
        }
        guard dbsetlversion(login, UInt8(DBVERSION_74)) == SUCCEED else {
            throw MSSQLCoreError.connectionFailed(String(localized: "FreeTDS could not set up the login."))
        }
        _ = dbsetlogintime(Int32(options.loginTimeoutSeconds))

        // Entra ID replaces the user name and password with an access token in the LOGIN7
        // FEDAUTH feature extension. Not macOS-only: iOS links the same patched FreeTDS.
        if options.authMethod == .entra {
            guard let token = options.fedAuthToken, !token.isEmpty else {
                throw MSSQLCoreError.connectionFailed(
                    String(localized: "No Microsoft Entra ID access token was supplied.")
                )
            }
            guard dbsetlfedauthtoken(login, token) == SUCCEED else {
                throw MSSQLCoreError.connectionFailed(
                    String(localized: "The Microsoft Entra ID access token was rejected by the driver.")
                )
            }
        }
    }

    private func openFailure() -> MSSQLCoreError {
        let detail = freetdsGetError(for: nil)
        let msg = detail.isEmpty ? "Check host, port, credentials, and TLS settings" : detail
        if let kind = MSSQLTLSClassifier.classifySSLError(detail) {
            return .tlsHandshakeFailed(kind: kind, serverMessage: detail)
        }
        if options.authMethod == .windows, let kind = MSSQLKerberosClassifier.classify(detail) {
            return .kerberosAuthFailed(kind: kind, serverMessage: detail)
        }
        return .connectionFailed("Failed to connect to \(options.host):\(options.port): \(msg)")
    }

    private func withKerberosEnvironmentIfNeeded(
        _ body: () -> UnsafeMutablePointer<DBPROCESS>?
    ) -> UnsafeMutablePointer<DBPROCESS>? {
        guard let cachePath = options.kerberosCachePath else { return body() }
        Self.kerberosEnvLock.lock()
        let previous = getenv("KRB5CCNAME").map { String(cString: $0) }
        setenv("KRB5CCNAME", "FILE:\(cachePath)", 1)
        defer {
            if let previous {
                setenv("KRB5CCNAME", previous, 1)
            } else {
                unsetenv("KRB5CCNAME")
            }
            Self.kerberosEnvLock.unlock()
        }
        return body()
    }

    private func adopt(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        lock.lock()
        dbproc = proc
        _isConnected = true
        lock.unlock()
        freetdsRegister(requestGate, for: proc)
        dbsetinterrupt(proc, freetdsInterruptCheck, freetdsInterruptHandler)
        establishSession(proc)
    }

    private func teardown(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        freetdsUnregister(proc)
        _ = dbclose(proc)
    }

    /// A server that refuses one of these still gets a working connection: db-lib's own defaults
    /// are wrong rather than fatal, and failing the connect over them would take the database away
    /// from a user who could otherwise work in it.
    private func establishSession(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        for statement in MSSQLSessionOptions.establishment {
            guard dbcmd(proc, statement) != FAIL, dbsqlexec(proc) != FAIL else {
                freetdsLogger.error("Session option statement refused: \(statement, privacy: .public)")
                continue
            }
            drainResults(proc)
        }
    }

    private func drainResults(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        while true {
            let resCode = dbresults(proc)
            if resCode == FAIL || resCode == Int32(NO_MORE_RESULTS) {
                break
            }
        }
    }

    func switchDatabase(_ database: String) async throws {
        let call = requestGate.enqueue()
        try await freetdsDispatchAsync(on: queue) { [self] in
            guard let proc = self.dbproc else {
                throw MSSQLCoreError.notConnected
            }
            try self.requestGate.beginRequest(call)
            defer { self.requestGate.endRequest() }
            guard dbuse(proc, database) != FAIL else {
                if self.requestGate.isCancelled(call) { throw CancellationError() }
                throw MSSQLCoreError.queryFailed("Cannot switch to database '\(database)'")
            }
        }
    }

    /// Closing a connection ends what it is running, as it does for any SQL Server client: measured, a statement whose
    /// client closed the socket wrote nothing. Only the queue may close the handle and the queue may be inside a read,
    /// so the read is stopped the way a Stop stops it and the handle is closed behind it.
    func disconnect() {
        let handle = dbproc
        dbproc = nil

        lock.lock()
        _isConnected = false
        lock.unlock()

        requestGate.stop()
        guard let handle else { return }
        queue.async { [self] in
            teardown(handle)
        }
    }

    /// A Stop. Safe from any thread, because it only marks the calls: see ``MSSQLRequestGate``.
    func cancelCurrentQuery() {
        requestGate.stop()
    }

    func executeQuery(_ query: String) async throws -> MSSQLRawResult {
        try await read(query, plan: .singleResult).singleResult()
    }

    /// A read the host has classified as a query, capped at `rowCap`. Reaching the cap ends the request on the server
    /// the way ``MSSQLRequestEnding`` allows, so the statement does not stay behind holding its locks.
    func executeQuery(_ query: String, rowCap: Int) async throws -> MSSQLRawResult {
        try await read(query, plan: .boundedQuery(rowCap: rowCap)).singleResult()
    }

    /// Sends `batch` in one request and reads it to the end. A server error inside it is part of the answer, because
    /// the server carries on past most of them.
    ///
    /// `countsToSkip` is how many statements the caller put in front of the batch, whose row counts are not the batch's.
    func executeBatch(_ batch: String, rowCap: Int?, countsToSkip: Int = 0) async throws -> MSSQLBatchReadout {
        try await read(batch, plan: .batch(rowCap: rowCap, countsToSkip: countsToSkip))
    }

    /// What the latest request printed, handed over once.
    func takeServerOutput() async throws -> (lines: [String], isTruncated: Bool) {
        try await freetdsDispatchAsync(on: queue) { [self] in
            guard let proc = self.dbproc else { return (lines: [], isTruncated: false) }
            return freetdsTakeOutput(for: proc)
        }
    }

    private func read(_ query: String, plan: FreeTDSReadPlan) async throws -> MSSQLBatchReadout {
        let queryToRun = String(query)
        let call = requestGate.enqueue()
        return try await withTaskCancellationHandler {
            try await freetdsDispatchAsync(on: queue) { [self] in
                try self.readSync(queryToRun, call: call, plan: plan, sink: .buffer, isAborted: nil)
            }
        } onCancel: { [weak self] in
            self?.cancelCurrentQuery()
        }
    }

    /// Runs one call's request to its end. A read that may stop early asks the session first, in the same call so
    /// nothing runs between the answer and the read, and a read that cannot costs no extra round trip.
    private func readSync(
        _ query: String,
        call: UInt64,
        plan: FreeTDSReadPlan,
        sink: FreeTDSRowSink,
        isAborted: (@Sendable () -> Bool)?
    ) throws -> MSSQLBatchReadout {
        guard let proc = dbproc else {
            throw MSSQLCoreError.notConnected
        }

        try requestGate.beginRequest(call)
        defer { requestGate.endRequest() }

        let mayStopEarly = plan.endsRequestAtRowCap || isAborted != nil
        let ending = try mayStopEarly ? sessionRequestEnding(proc, call: call) : MSSQLRequestEnding.readRest

        freetdsClearError(for: proc)
        if dbcmd(proc, query) == FAIL {
            throw MSSQLCoreError.queryFailed("Failed to prepare query")
        }
        var reader = FreeTDSBatchReader(
            proc: proc,
            plan: plan,
            sink: sink,
            ending: ending,
            userCancelled: { [requestGate] in requestGate.isCancelled(call) },
            consumerStopped: isAborted ?? { false }
        )
        return try reader.read()
    }

    /// One round trip, about a millisecond against a local server, the same as `SELECT 1`. A server error in the answer
    /// reads the rest rather than trusting it.
    private func sessionRequestEnding(
        _ proc: UnsafeMutablePointer<DBPROCESS>,
        call: UInt64
    ) throws -> MSSQLRequestEnding {
        freetdsClearError(for: proc)
        guard dbcmd(proc, MSSQLRequestEnding.sessionQuery) != FAIL else { return .readRest }
        var reader = FreeTDSBatchReader(
            proc: proc,
            plan: .singleResult,
            sink: .buffer,
            ending: .readRest,
            userCancelled: { [requestGate] in requestGate.isCancelled(call) },
            consumerStopped: { false }
        )
        let answer = try reader.read()
        return MSSQLRequestEnding(sessionAnswer: answer.errors.isEmpty ? answer.resultSets.first : nil)
    }

    /// `isAborted` is how a consumer that stopped reaches this loop. It is a closure rather than a
    /// PluginKit type because this file is compiled into the iOS app too and may not import
    /// PluginKit. It is polled instead of `Task.isCancelled`, which is always false here: the body
    /// runs inside a bare `queue.async` with no task context. A consumer that stops ends the request
    /// the way a capped read does.
    ///
    /// Only the request's first result set is streamed. A later one is read past, so the statements behind it still
    /// run, and a server error anywhere in the request finishes the stream with that error.
    func streamQuery(
        _ query: String,
        isAborted: (@Sendable () -> Bool)? = nil,
        continuation: AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation
    ) async throws {
        let queryToRun = String(query)
        let call = requestGate.enqueue()
        try await withTaskCancellationHandler {
            try await freetdsDispatchAsync(on: queue) { [self] in
                do {
                    let readout = try self.readSync(
                        queryToRun,
                        call: call,
                        plan: .stream,
                        sink: .stream(continuation),
                        isAborted: isAborted
                    )
                    if let error = readout.errors.first {
                        continuation.finish(throwing: MSSQLCoreError.queryFailed(error.message.text))
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelCurrentQuery()
        }
    }

    static func columnType(fromFreeTDSToken token: Int32) -> MSSQLColumnType {
        switch token {
        case Int32(SYBCHAR): return .char
        case Int32(SYBVARCHAR): return .varchar
        case Int32(SYBTEXT): return .text
        case Int32(SYBNCHAR): return .nchar
        case Int32(SYBNVARCHAR): return .nvarchar
        case Int32(SYBNTEXT): return .ntext
        case Int32(SYBINT1): return .tinyInt
        case Int32(SYBINT2): return .smallInt
        case Int32(SYBINT4): return .int
        case Int32(SYBINT8): return .bigInt
        case Int32(SYBFLT8): return .float
        case Int32(SYBREAL): return .real
        case Int32(SYBDECIMAL), Int32(SYBNUMERIC): return .decimal
        case Int32(SYBMONEY): return .money
        case Int32(SYBMONEY4): return .smallMoney
        case Int32(SYBBIT): return .bit
        case Int32(SYBBINARY): return .binary
        case Int32(SYBVARBINARY): return .varbinary
        case Int32(SYBIMAGE): return .image
        case Int32(SYBDATETIME): return .dateTime
        case Int32(SYBDATETIME4): return .smallDateTime
        case Int32(SYBDATETIMN): return .dateTimeN
        case 40: return .date
        case 41: return .time
        case 42: return .dateTime2
        case 43: return .dateTimeOffset
        case Int32(SYBUNIQUE): return .uniqueIdentifier
        default: return .unknown(token)
        }
    }

    fileprivate static func columnValueAsString(
        proc: UnsafeMutablePointer<DBPROCESS>,
        ptr: UnsafePointer<BYTE>,
        srcToken: Int32,
        srcLen: DBINT,
        type: MSSQLColumnType
    ) -> String? {
        if type.isNarrowString {
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .isoLatin1)
        }
        if type.isUnicodeString {
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(data: Data(bytes: ptr, count: Int(srcLen)), encoding: .utf16LittleEndian)
        }
        let bufSize: DBINT = 256
        var buf = [BYTE](repeating: 0, count: Int(bufSize))
        let converted = buf.withUnsafeMutableBufferPointer { bufPtr in
            dbconvert(proc, srcToken, ptr, srcLen, Int32(SYBCHAR), bufPtr.baseAddress, bufSize)
        }
        guard converted > 0,
              let raw = String(bytes: buf.prefix(Int(converted)), encoding: .utf8)
        else { return nil }
        if type.isDateOrTime {
            return MSSQLDatetimeFormatter.reformat(raw, type: type) ?? raw
        }
        return raw
    }
}

nonisolated private extension MSSQLLoginField {
    var dbsetName: Int32 {
        switch self {
        case .user: return Int32(DBSETUSER)
        case .password: return Int32(DBSETPWD)
        case .application: return Int32(DBSETAPP)
        case .nationalLanguage: return Int32(DBSETNATLANG)
        case .charset: return Int32(DBSETCHARSET)
        case .database: return Int32(DBSETDBNAME)
        }
    }

    var refusal: String {
        switch self {
        case .user:
            return String(localized: "The user name is longer than the 128 bytes FreeTDS takes.")
        case .password:
            return String(localized: "The password is longer than the 128 bytes FreeTDS takes.")
        case .database:
            return String(localized: "The database name is longer than the 128 bytes FreeTDS takes.")
        case .application, .nationalLanguage, .charset:
            return String(localized: "FreeTDS could not set up the login.")
        }
    }
}

/// How much of a request one call keeps.
///
/// A bounded read's row cap ends the whole request (`endsRequestAtRowCap`), the way ``MSSQLRequestEnding`` allows.
/// Every other limit is one the request goes on past: the rest of that result set is read and dropped, and the read
/// carries on with the next, because a batch's later statements still have to run.
nonisolated private struct FreeTDSReadPlan: Sendable {
    let keptResultSetLimit: Int
    let rowCap: Int?
    let endsRequestAtRowCap: Bool
    let rowBudget: Int

    /// Results without columns at the head of the request whose counts are not the request's own: a statement the
    /// caller put in front of the batch, such as the declaration that binds its parameters.
    var leadingCountsToSkip = 0

    static let singleResult = FreeTDSReadPlan(
        keptResultSetLimit: 1,
        rowCap: nil,
        endsRequestAtRowCap: false,
        rowBudget: MSSQLRowLimits.emergencyMax
    )

    static let stream = FreeTDSReadPlan(
        keptResultSetLimit: 1,
        rowCap: nil,
        endsRequestAtRowCap: false,
        rowBudget: .max
    )

    static func boundedQuery(rowCap: Int) -> FreeTDSReadPlan {
        FreeTDSReadPlan(
            keptResultSetLimit: 1,
            rowCap: max(rowCap, 1),
            endsRequestAtRowCap: true,
            rowBudget: MSSQLRowLimits.emergencyMax
        )
    }

    static func batch(rowCap: Int?, countsToSkip: Int) -> FreeTDSReadPlan {
        FreeTDSReadPlan(
            keptResultSetLimit: MSSQLRowLimits.batchResultSetLimit,
            rowCap: rowCap.map { max($0, 1) },
            endsRequestAtRowCap: false,
            rowBudget: MSSQLRowLimits.emergencyMax,
            leadingCountsToSkip: countsToSkip
        )
    }
}

nonisolated private enum FreeTDSRowSink {
    case buffer
    case stream(AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation)
}

/// Reads one request to its end, or ends it early, so the connection is never left with results nobody will read.
///
/// db-lib reports a failed statement as a `FAIL` from `dbresults` and then carries on to the next one, and it refuses
/// `dbresults` while a result set still has rows unread, failing with 20019 for as long as nothing reads them. So every
/// exit here reads on to `NO_MORE_RESULTS` or ends the request with an attention. None leaves the rest for the next
/// call: a statement left unread stays suspended on the server holding its locks, and the next call has to read all of
/// it before the server answers.
///
/// This is the only thread that reads the connection, so it is the one that answers a Stop. It looks for one after
/// every db-lib call and ends the request with `dbcancel`; a Stop that lands while db-lib waits on the socket reaches
/// that wait through the interrupt handler, which sends the attention from here and ends the wait. Rows are skipped one
/// at a time rather than with `dbcanquery`, which reads a whole result set without once waiting a second on the socket,
/// so a Stop during it was never seen: measured over 30 million rows.
///
/// A result set counts only when no server error arrived while it was read: `SELECT 1/0` sends its columns and then
/// its error, and a conversion error cuts a scan short with `dbnextrow` answering `NO_MORE_ROWS`, so both would
/// otherwise read as a successful result with too few rows.
nonisolated private struct FreeTDSBatchReader {
    private enum ResultSetEnd {
        case readToEnd
        case stoppedEarly
    }

    private let proc: UnsafeMutablePointer<DBPROCESS>
    private let plan: FreeTDSReadPlan
    private let sink: FreeTDSRowSink
    private let ending: MSSQLRequestEnding
    private let userCancelled: () -> Bool
    private let consumerStopped: () -> Bool

    private var kept: [MSSQLRawResult] = []
    private var keptCount = 0
    private var readPastCount = 0
    private var rowsAffected = 0
    private var rowsKept = 0
    private var errors: [MSSQLPlacedError] = []
    private var droppedErrorCount = 0
    private var absorbedMessageCount = 0
    private var headerStreamed = false
    private var countsSkipped = 0

    /// Set when the read stopped keeping results early in a session that may not be sent an attention, so it reads
    /// past the rest of the request instead.
    private var isReadingPastRest = false

    /// Every error the request raised, the ones past the stored cap included. Whether a `FAIL` has a server error behind
    /// it is read off this, not off the kept errors: once the cap was reached a failing statement added nothing to
    /// those, and read as db-lib failing the whole request.
    private var errorTotal: Int {
        errors.count + droppedErrorCount
    }

    init(
        proc: UnsafeMutablePointer<DBPROCESS>,
        plan: FreeTDSReadPlan,
        sink: FreeTDSRowSink,
        ending: MSSQLRequestEnding,
        userCancelled: @escaping () -> Bool,
        consumerStopped: @escaping () -> Bool
    ) {
        self.proc = proc
        self.plan = plan
        self.sink = sink
        self.ending = ending
        self.userCancelled = userCancelled
        self.consumerStopped = consumerStopped
    }

    mutating func read() throws -> MSSQLBatchReadout {
        let executed = dbsqlexec(proc)
        try cancelIfUserAsked()
        absorbMessages()
        if executed == FAIL, errorTotal == 0 {
            try failWithoutServerError()
        }

        while true {
            if !isReadingPastRest, consumerStopped() {
                guard try stopEarly() else { break }
            }
            let errorsBefore = errorTotal
            let code = dbresults(proc)
            try cancelIfUserAsked()
            absorbMessages()
            if code == Int32(NO_MORE_RESULTS) {
                break
            }
            if code == FAIL {
                if errorTotal == errorsBefore {
                    try failWithoutServerError()
                }
                continue
            }
            let columnCount = Int(dbnumcols(proc))
            guard columnCount > 0 else {
                recordCount()
                continue
            }
            guard keptCount < plan.keptResultSetLimit, !headerStreamed, !isReadingPastRest else {
                try readPast(errorsBefore: errorsBefore)
                continue
            }
            if try readResultSet(columnCount: columnCount, errorsBefore: errorsBefore) == .stoppedEarly {
                guard try stopEarly() else { break }
            }
        }

        try failIfConnectionEnded()
        finishCountOnlyStream()
        return MSSQLBatchReadout(
            resultSets: kept,
            rowsAffected: rowsAffected,
            errors: errors,
            errorsNotKept: droppedErrorCount,
            resultSetsReadPast: readPastCount
        )
    }

    private mutating func readResultSet(columnCount: Int, errorsBefore: Int) throws -> ResultSetEnd {
        let descriptors = (1...columnCount).map(describeColumn)
        if case .stream(let continuation) = sink {
            continuation.yield(.header(columns: descriptors))
            headerStreamed = true
        }

        var rows: [[MSSQLRawCell]] = []
        var rowCount = 0
        var isTruncated = false
        var end = ResultSetEnd.readToEnd

        while true {
            let rowCode = dbnextrow(proc)
            try cancelIfUserAsked()
            if rowCode == Int32(NO_MORE_ROWS) || rowCode == FAIL {
                break
            }
            if consumerStopped() {
                end = .stoppedEarly
                break
            }
            if let cap = plan.rowCap, rowCount >= cap {
                isTruncated = true
                guard plan.endsRequestAtRowCap else {
                    try skipRows()
                    break
                }
                end = .stoppedEarly
                break
            }
            if rowsKept >= plan.rowBudget {
                isTruncated = true
                try skipRows()
                break
            }
            rows.append(readRow(descriptors))
            rowCount += 1
            rowsKept += 1
            streamIfFull(&rows)
        }
        streamRemaining(&rows)

        absorbMessages()
        guard errorTotal == errorsBefore else { return end }
        keptCount += 1
        if case .buffer = sink {
            kept.append(MSSQLRawResult(columns: descriptors, rows: rows, affectedRows: rows.count, isTruncated: isTruncated))
        }
        return end
    }

    /// Stops keeping anything more of the request, and answers whether the read goes on. An attention ends the request
    /// on the server now. Otherwise the rest of the current result set is skipped here and the loop reads past what
    /// follows, so the request still ends inside this call.
    private mutating func stopEarly() throws -> Bool {
        switch ending {
        case .attention:
            _ = dbcancel(proc)
            return false
        case .readRest:
            try skipRows()
            isReadingPastRest = true
            return true
        }
    }

    private mutating func readPast(errorsBefore: Int) throws {
        try skipRows()
        absorbMessages()
        guard errorTotal == errorsBefore else { return }
        readPastCount += 1
    }

    private func skipRows() throws {
        while true {
            let code = dbnextrow(proc)
            try cancelIfUserAsked()
            if code == Int32(NO_MORE_ROWS) || code == FAIL { return }
        }
    }

    private mutating func recordCount() {
        guard countsSkipped >= plan.leadingCountsToSkip else {
            countsSkipped += 1
            return
        }
        let count = Int(dbcount(proc))
        guard count >= 0 else { return }
        rowsAffected += count
    }

    private func describeColumn(_ index: Int) -> MSSQLColumnDescriptor {
        let column = Int32(index)
        let name = dbcolname(proc, column).map { String(cString: $0) } ?? "col\(index)"
        return MSSQLColumnDescriptor(name: name, type: FreeTDSConnection.columnType(fromFreeTDSToken: dbcoltype(proc, column)))
    }

    private func readRow(_ descriptors: [MSSQLColumnDescriptor]) -> [MSSQLRawCell] {
        descriptors.indices.map { offset in
            let column = Int32(offset + 1)
            let length = dbdatlen(proc, column)
            let token = dbcoltype(proc, column)
            let type = descriptors[offset].type
            guard length > 0 || token == Int32(SYBBIT), let pointer = dbdata(proc, column) else { return .null }
            if type.isBinary {
                return .bytes(Data(bytes: pointer, count: Int(length)))
            }
            guard let text = FreeTDSConnection.columnValueAsString(
                proc: proc,
                ptr: pointer,
                srcToken: token,
                srcLen: length,
                type: type
            ) else { return .null }
            return .string(text)
        }
    }

    private func streamIfFull(_ rows: inout [[MSSQLRawCell]]) {
        guard case .stream(let continuation) = sink, rows.count >= MSSQLRowLimits.streamBatchSize else { return }
        continuation.yield(.rows(rows))
        rows.removeAll(keepingCapacity: true)
    }

    private func streamRemaining(_ rows: inout [[MSSQLRawCell]]) {
        guard case .stream(let continuation) = sink, !rows.isEmpty else { return }
        continuation.yield(.rows(rows))
        rows.removeAll()
    }

    private func finishCountOnlyStream() {
        guard case .stream(let continuation) = sink, !headerStreamed, errorTotal == 0 else { return }
        continuation.yield(.affectedRows(rowsAffected))
    }

    private mutating func absorbMessages() {
        let arrival = freetdsMessages(for: proc, from: absorbedMessageCount)
        droppedErrorCount = arrival.droppedErrorCount
        for message in arrival.messages where message.isError {
            errors.append(MSSQLPlacedError(message: message, precedingResultSetCount: keptCount))
        }
        absorbedMessageCount += arrival.messages.count
    }

    /// A Stop the user asked for ends the request on the server, which is what they asked for, whatever the session
    /// holds. When the interrupt handler already sent the attention, `dbcancel` finds the request over and returns at
    /// once: measured, 0 ms.
    private func cancelIfUserAsked() throws {
        guard userCancelled() else { return }
        _ = dbcancel(proc)
        throw CancellationError()
    }

    /// db-lib failed the request with no server error to explain it: the connection is gone, or db-lib refused the
    /// call. Reading further would never end, so on a live connection an attention ends whatever the request left, and
    /// the next call does not find it pending.
    private func failWithoutServerError() throws -> Never {
        let diagnostics = freetdsDiagnostics(for: proc)
        if diagnostics.connectionEnded {
            throw MSSQLCoreError.connectionFailed(diagnostics.libraryError)
        }
        _ = dbcancel(proc)
        let detail = diagnostics.libraryError.isEmpty ? "Query execution failed" : diagnostics.libraryError
        throw MSSQLCoreError.queryFailed(detail)
    }

    private func failIfConnectionEnded() throws {
        if let fatal = errors.first(where: { $0.message.endsConnection }) {
            throw MSSQLCoreError.connectionFailed(fatal.message.text)
        }
        let diagnostics = freetdsDiagnostics(for: proc)
        guard diagnostics.connectionEnded else { return }
        throw MSSQLCoreError.connectionFailed(diagnostics.libraryError)
    }
}
