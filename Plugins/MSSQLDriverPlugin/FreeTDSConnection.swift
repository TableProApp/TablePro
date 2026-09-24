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
}

nonisolated private let freetdsInitOnce: Void = {
    _ = dbinit()
    _ = dberrhandle { dbproc, _, dberr, _, dberrstr, oserrstr in
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
    /// Every call is numbered as it is handed to the queue, and a Stop cancels every call numbered so far. A call
    /// therefore sees a Stop pressed while it waited behind another call or behind a drain, and never one pressed
    /// before it was made. A single flag cleared when the call began work lost the first kind: a Stop pressed during a
    /// minute-long drain was wiped, and the DELETE behind it was sent and committed.
    private var enqueuedCalls: UInt64 = 0
    private var cancelledThroughCall: UInt64 = 0

    /// Whether a call's own request is on the wire, which is the only time a Stop sends the server an attention. While
    /// the queue is only reading past an abandoned request the Stop marks the call and the drain stops at its next
    /// check: a `dbcancel` from another thread then reads the same socket the drain is reading, and measured, the drain
    /// thread waited forever for a packet the cancelling thread had already consumed.
    private var requestInFlight = false

    /// Set on the connection's queue when a read stopped before the end of its request, and cleared by the next call
    /// once it has read past the rest.
    private var hasAbandonedRequest = false

    private static let kerberosEnvLock = NSLock()
    private static let freetdsConfEnvLock = NSLock()
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
        let gate = SingleResumeGate<Void>()
        let isKerberos = options.authMethod == .windows
        let deadline = DispatchTimeInterval.seconds(options.loginTimeoutSeconds + Self.connectDeadlineMarginSeconds)

        Self.deadlineQueue.asyncAfter(deadline: .now() + deadline) {
            gate.fail(MSSQLCoreError.connectionTimedOut(isKerberos: isKerberos))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation, alreadyCancelled: Task.isCancelled)
                queue.async { [self] in
                    do {
                        let proc = try openConnection()
                        if gate.win(()) {
                            adopt(proc)
                        } else {
                            teardown(proc)
                        }
                    } catch {
                        gate.fail(error)
                    }
                }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    private func openConnection() throws -> UnsafeMutablePointer<DBPROCESS> {
        guard let login = dblogin() else {
            throw MSSQLCoreError.connectionFailed("Failed to create login")
        }
        defer { dbloginfree(login) }

        for parameter in MSSQLLoginParameters.build(
            user: options.user,
            password: options.password,
            applicationName: options.applicationName,
            encryptionFlag: options.encryptionFlag,
            database: options.database
        ) {
            _ = dbsetlname(login, parameter.value, parameter.field.dbsetName)
        }
        _ = dbsetlversion(login, UInt8(DBVERSION_74))
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

        #if os(macOS)
        // Windows Auth cross-realm: FreeTDS otherwise builds its own SPN and only canonicalizes a
        // short hostname (via getaddrinfo), never applying [domain_realm] to pick the realm. We
        // resolve the canonical host + realm up front and hand FreeTDS the full SPN, so cross-realm
        // and short-name/CNAME hosts authenticate like the JDBC driver does.
        if options.authMethod == .windows, let spn = options.kerberosServicePrincipal, !spn.isEmpty {
            _ = dbsetlname(login, spn, Int32(DBSETSERVERPRINCIPAL))
        }
        #endif

        freetdsClearError(for: nil)
        let verifies = options.certificateVerification != .none
        let serverName = verifies ? MSSQLFreeTDSConfig.serverEntryName : "\(options.host):\(options.port)"
        guard let proc = withFreeTDSConfigIfNeeded({
            self.withKerberosEnvironmentIfNeeded { dbopen(login, serverName) }
        }) else {
            let detail = freetdsGetError(for: nil)
            let msg = detail.isEmpty ? "Check host, port, credentials, and TLS settings" : detail
            if let kind = MSSQLTLSClassifier.classifySSLError(detail) {
                throw MSSQLCoreError.tlsHandshakeFailed(kind: kind, serverMessage: detail)
            }
            if options.authMethod == .windows, let kind = MSSQLKerberosClassifier.classify(detail) {
                throw MSSQLCoreError.kerberosAuthFailed(kind: kind, serverMessage: detail)
            }
            throw MSSQLCoreError.connectionFailed("Failed to connect to \(options.host):\(options.port): \(msg)")
        }
        return proc
    }

    /// A verifying mode needs `ca file` and `check certificate hostname`, which dblib cannot set.
    /// The generated config is written 0600 and FREETDSCONF points at it only for this dbopen, so
    /// a machine's own freetds.conf is untouched on every other connection.
    private func withFreeTDSConfigIfNeeded(
        _ body: () -> UnsafeMutablePointer<DBPROCESS>?
    ) -> UnsafeMutablePointer<DBPROCESS>? {
        guard options.certificateVerification != .none else { return body() }

        let contents = MSSQLFreeTDSConfig.configuration(
            host: options.host,
            port: options.port,
            encryptionFlag: options.encryptionFlag,
            verification: options.certificateVerification,
            caCertificatePath: options.caCertificatePath
        )

        let path = NSTemporaryDirectory() + "tablepro-freetds-\(UUID().uuidString).conf"
        guard let data = contents.data(using: .utf8),
              FileManager.default.createFile(
                  atPath: path,
                  contents: data,
                  attributes: [.posixPermissions: 0o600]
              ) else {
            return body()
        }

        Self.freetdsConfEnvLock.lock()
        let previous = getenv("FREETDSCONF").map { String(cString: $0) }
        setenv("FREETDSCONF", path, 1)
        defer {
            if let previous {
                setenv("FREETDSCONF", previous, 1)
            } else {
                unsetenv("FREETDSCONF")
            }
            Self.freetdsConfEnvLock.unlock()
            try? FileManager.default.removeItem(atPath: path)
        }
        return body()
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
            try? FileManager.default.removeItem(atPath: cachePath)
        }
        return body()
    }

    private func adopt(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        lock.lock()
        dbproc = proc
        _isConnected = true
        lock.unlock()
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
        let call = enqueueCall()
        try await freetdsDispatchAsync(on: queue) { [self] in
            guard let proc = self.dbproc else {
                throw MSSQLCoreError.notConnected
            }
            try self.drainAbandonedRequest(proc, call: call)
            try self.beginRequest(call)
            defer { self.endRequest() }
            if dbuse(proc, database) == FAIL {
                throw MSSQLCoreError.queryFailed("Cannot switch to database '\(database)'")
            }
        }
    }

    func disconnect() {
        let handle = dbproc
        dbproc = nil

        lock.lock()
        _isConnected = false
        lock.unlock()

        if let handle {
            freetdsUnregister(handle)
            queue.async {
                _ = dbclose(handle)
            }
        }
    }

    func cancelCurrentQuery() {
        lock.lock()
        cancelledThroughCall = enqueuedCalls
        let proc = requestInFlight ? dbproc : nil
        lock.unlock()

        guard let proc else { return }
        dbcancel(proc)
    }

    func executeQuery(_ query: String) async throws -> MSSQLRawResult {
        try await read(query, plan: .singleResult).singleResult()
    }

    /// A read the host has classified as a query, capped at `rowCap`. Reaching the cap stops reading and leaves the rest
    /// of the request on the connection for the next call to skip, so the capped result comes back at once.
    ///
    /// It never cancels the request. The cap is the app's, not the user's, and an attention is an abort to the server:
    /// measured, under `SET XACT_ABORT ON` a `dbcancel` sent after 10,000 of 200,000 rows rolled the session's open
    /// transaction back with no message to either handler.
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
        let call = enqueueCall()
        return try await withTaskCancellationHandler {
            try await freetdsDispatchAsync(on: queue) { [self] in
                try self.readSync(queryToRun, call: call, plan: plan, sink: .buffer, isAborted: { false })
            }
        } onCancel: { [weak self] in
            self?.cancelCurrentQuery()
        }
    }

    private func readSync(
        _ query: String,
        call: UInt64,
        plan: FreeTDSReadPlan,
        sink: FreeTDSRowSink,
        isAborted: @escaping @Sendable () -> Bool
    ) throws -> MSSQLBatchReadout {
        guard let proc = dbproc else {
            throw MSSQLCoreError.notConnected
        }

        try drainAbandonedRequest(proc, call: call)
        try beginRequest(call)
        defer { endRequest() }

        freetdsClearError(for: proc)
        if dbcmd(proc, query) == FAIL {
            throw MSSQLCoreError.queryFailed("Failed to prepare query")
        }
        var reader = FreeTDSBatchReader(
            proc: proc,
            plan: plan,
            sink: sink,
            userCancelled: { [self] in self.isCancelled(call) },
            consumerStopped: isAborted
        )
        defer { hasAbandonedRequest = reader.abandonedRequest }
        return try reader.read()
    }

    /// Reads past whatever a call that stopped early left on the connection, so db-lib never refuses the next request
    /// with 20019. A capped read and a stream whose consumer stopped leave the rest of their request here rather than
    /// cancelling it; skipping it costs the time the server takes to send it, which is what the next call pays.
    ///
    /// A `FAIL` with no db-lib error behind it is one of the abandoned statements failing, and the rest still follow. A
    /// db-lib error means the connection cannot go on (it died, or refused the call), and reading further would never
    /// end, so the next request finds out from db-lib itself.
    ///
    /// Rows are skipped one at a time rather than with `dbcanquery`, so a Stop for `call` is seen within a thousand rows
    /// rather than after the whole rest of a result set. It ends the drain and the call before anything of the call's
    /// own is sent, and leaves what the drain had not read yet for the next call: `dbresults` and `dbnextrow` on a
    /// connection with nothing pending answer that there is nothing and send nothing, measured.
    private func drainAbandonedRequest(_ proc: UnsafeMutablePointer<DBPROCESS>, call: UInt64) throws {
        guard hasAbandonedRequest else {
            _ = dbcanquery(proc)
            return
        }
        freetdsClearError(for: proc)
        try skipRows(proc, call: call)
        while true {
            guard !isCancelled(call) else { throw CancellationError() }
            let code = dbresults(proc)
            if code == Int32(NO_MORE_RESULTS) {
                hasAbandonedRequest = false
                return
            }
            if code == FAIL {
                guard freetdsDiagnostics(for: proc).libraryError.isEmpty else {
                    hasAbandonedRequest = false
                    return
                }
                continue
            }
            if dbnumcols(proc) > 0 {
                try skipRows(proc, call: call)
            }
        }
    }

    private func skipRows(_ proc: UnsafeMutablePointer<DBPROCESS>, call: UInt64) throws {
        var skipped = 0
        while true {
            let code = dbnextrow(proc)
            if code == Int32(NO_MORE_ROWS) || code == FAIL { return }
            skipped += 1
            if skipped.isMultiple(of: 1_000), isCancelled(call) {
                throw CancellationError()
            }
        }
    }

    /// Marks the call's request as on the wire before the last look for a Stop, so a Stop is either seen here and
    /// nothing is sent, or lands after this and cancels the request on the server.
    private func beginRequest(_ call: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard call > cancelledThroughCall else { throw CancellationError() }
        requestInFlight = true
    }

    private func endRequest() {
        lock.lock()
        requestInFlight = false
        lock.unlock()
    }

    private func enqueueCall() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        enqueuedCalls += 1
        return enqueuedCalls
    }

    private func isCancelled(_ call: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return call <= cancelledThroughCall
    }

    /// `isAborted` is how a consumer that stopped reaches this loop. It is a closure rather than a
    /// PluginKit type because this file is compiled into the iOS app too and may not import
    /// PluginKit. It is polled instead of `Task.isCancelled`, which is always false here: the body
    /// runs inside a bare `queue.async` with no task context.
    ///
    /// Only the request's first result set is streamed. A later one is read past, so the statements behind it still
    /// run, and a server error anywhere in the request finishes the stream with that error.
    func streamQuery(
        _ query: String,
        isAborted: @escaping @Sendable () -> Bool = { false },
        continuation: AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation
    ) async throws {
        let queryToRun = String(query)
        let call = enqueueCall()
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
        case .encryption: return Int32(DBSETENCRYPT)
        case .database: return Int32(DBSETDBNAME)
        }
    }
}

/// How much of a request one call keeps.
///
/// Every limit here is the app's own, so none of them sends the server an attention: under `SET XACT_ABORT ON` that
/// rolls back the session's open transaction. `abandonsRequestAtRowCap` stops reading and leaves the rest for the next
/// call to skip; every other limit skips the rest of the one result set with `dbcanquery` and reads on.
nonisolated private struct FreeTDSReadPlan: Sendable {
    let keptResultSetLimit: Int
    let rowCap: Int?
    let abandonsRequestAtRowCap: Bool
    let rowBudget: Int

    /// Results without columns at the head of the request whose counts are not the request's own: a statement the
    /// caller put in front of the batch, such as the declaration that binds its parameters.
    var leadingCountsToSkip = 0

    static let singleResult = FreeTDSReadPlan(
        keptResultSetLimit: 1,
        rowCap: nil,
        abandonsRequestAtRowCap: false,
        rowBudget: MSSQLRowLimits.emergencyMax
    )

    static let stream = FreeTDSReadPlan(
        keptResultSetLimit: 1,
        rowCap: nil,
        abandonsRequestAtRowCap: false,
        rowBudget: .max
    )

    static func boundedQuery(rowCap: Int) -> FreeTDSReadPlan {
        FreeTDSReadPlan(
            keptResultSetLimit: 1,
            rowCap: max(rowCap, 1),
            abandonsRequestAtRowCap: true,
            rowBudget: MSSQLRowLimits.emergencyMax
        )
    }

    static func batch(rowCap: Int?, countsToSkip: Int) -> FreeTDSReadPlan {
        FreeTDSReadPlan(
            keptResultSetLimit: MSSQLRowLimits.batchResultSetLimit,
            rowCap: rowCap.map { max($0, 1) },
            abandonsRequestAtRowCap: false,
            rowBudget: MSSQLRowLimits.emergencyMax,
            leadingCountsToSkip: countsToSkip
        )
    }
}

nonisolated private enum FreeTDSRowSink {
    case buffer
    case stream(AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation)
}

/// Reads one request to its end, or stops at a limit and says so, so the connection is never left with results nobody
/// will read.
///
/// db-lib reports a failed statement as a `FAIL` from `dbresults` and then carries on to the next one, and it refuses
/// `dbresults` while a result set still has rows unread, failing with 20019 for as long as nothing reads them. A read
/// that stopped at either used to leave the connection answering every later request, the health ping included, with
/// 20019 until it reconnected. So every exit here reads on to `NO_MORE_RESULTS`, skips unread rows with `dbcanquery`,
/// or leaves the rest of the request marked as abandoned (``abandonedRequest``) for the next call to read past. Only a
/// Stop the user asked for cancels the request with `dbcancel`: an attention is an abort to the server, and under
/// `SET XACT_ABORT ON` one sent for a limit the app imposed rolled back the user's open transaction.
///
/// A result set counts only when no server error arrived while it was read: `SELECT 1/0` sends its columns and then
/// its error, and a conversion error cuts a scan short with `dbnextrow` answering `NO_MORE_ROWS`, so both would
/// otherwise read as a successful result with too few rows.
nonisolated private struct FreeTDSBatchReader {
    private enum ResultSetEnd {
        case readToEnd
        case requestAbandoned
    }

    private let proc: UnsafeMutablePointer<DBPROCESS>
    private let plan: FreeTDSReadPlan
    private let sink: FreeTDSRowSink
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

    /// Every error the request raised, the ones past the stored cap included. Whether a `FAIL` has a server error behind
    /// it is read off this, not off the kept errors: once the cap was reached a failing statement added nothing to
    /// those, and read as db-lib failing the whole request.
    private var errorTotal: Int {
        errors.count + droppedErrorCount
    }

    /// Whether the read stopped before the end of its request, leaving the rest on the connection.
    private(set) var abandonedRequest = false

    init(
        proc: UnsafeMutablePointer<DBPROCESS>,
        plan: FreeTDSReadPlan,
        sink: FreeTDSRowSink,
        userCancelled: @escaping () -> Bool,
        consumerStopped: @escaping () -> Bool
    ) {
        self.proc = proc
        self.plan = plan
        self.sink = sink
        self.userCancelled = userCancelled
        self.consumerStopped = consumerStopped
    }

    mutating func read() throws -> MSSQLBatchReadout {
        let executed = dbsqlexec(proc)
        absorbMessages()
        if executed == FAIL, errorTotal == 0 {
            try failWithoutServerError()
        }

        while true {
            try cancelIfUserAsked()
            if consumerStopped() {
                abandonedRequest = true
                break
            }
            let errorsBefore = errorTotal
            let code = dbresults(proc)
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
            guard keptCount < plan.keptResultSetLimit, !headerStreamed else {
                readPast(errorsBefore: errorsBefore)
                continue
            }
            if try readResultSet(columnCount: columnCount, errorsBefore: errorsBefore) == .requestAbandoned {
                abandonedRequest = true
                break
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
            if rowCode == Int32(NO_MORE_ROWS) || rowCode == FAIL {
                break
            }
            try cancelIfUserAsked()
            if consumerStopped() {
                end = .requestAbandoned
                break
            }
            if let cap = plan.rowCap, rowCount >= cap {
                isTruncated = true
                end = stopReading(atRowCap: true)
                break
            }
            if rowsKept >= plan.rowBudget {
                isTruncated = true
                end = stopReading(atRowCap: false)
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

    private func stopReading(atRowCap: Bool) -> ResultSetEnd {
        guard atRowCap, plan.abandonsRequestAtRowCap else {
            _ = dbcanquery(proc)
            return .readToEnd
        }
        return .requestAbandoned
    }

    private mutating func readPast(errorsBefore: Int) {
        _ = dbcanquery(proc)
        absorbMessages()
        guard errorTotal == errorsBefore else { return }
        readPastCount += 1
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

    /// A Stop the user asked for ends the request on the server, which is what they asked for.
    private func cancelIfUserAsked() throws {
        guard userCancelled() else { return }
        _ = dbcancel(proc)
        throw CancellationError()
    }

    /// db-lib failed the request with no server error to explain it: the connection is gone, or db-lib refused the
    /// call. Whatever the request left is marked abandoned rather than cancelled, for the same reason a cap is.
    private mutating func failWithoutServerError() throws -> Never {
        let diagnostics = freetdsDiagnostics(for: proc)
        if diagnostics.connectionEnded {
            throw MSSQLCoreError.connectionFailed(diagnostics.libraryError)
        }
        abandonedRequest = true
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
