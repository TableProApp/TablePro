//
//  RedisPluginConnection.swift
//  RedisDriverPlugin
//
//  Swift wrapper around hiredis (Redis C client library)
//  Provides thread-safe, async-friendly Redis connections.
//  Adapted from TablePro's RedisConnection for the plugin architecture.
//

#if canImport(CRedis)
import CRedis
#endif
import Foundation
import os
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisPluginConnection")

// MARK: - Connection Class

final class RedisPluginConnection: RedisCommandChannel, @unchecked Sendable {
    // MARK: - Properties

    #if canImport(CRedis)
    private static let initOnce: Void = {
        let result = redisInitOpenSSL()
        if result != REDIS_OK {
            logger.warning("redisInitOpenSSL failed with code \(result)")
        }
    }()

    private var context: UnsafeMutablePointer<redisContext>?
    private var sslContext: OpaquePointer?
    #endif

    private let queue = DispatchQueue(label: "com.TablePro.redis.plugin", qos: .userInitiated)
    let host: String
    let port: Int

    var address: RedisNodeAddress { RedisNodeAddress(host: host, port: port) }
    private let username: String?
    private let password: String?
    private let database: Int
    private let sslConfig: SSLConfiguration
    private let connectTimeout: TimeInterval

    private let routingLock = NSLock()
    private var _routing = RedisCommandRouting()

    /// Which commands may be replayed after a lost connection. Defaults to the curated table and is
    /// replaced with the server's own COMMAND answer once a cluster channel has fetched it.
    var routing: RedisCommandRouting {
        routingLock.lock()
        defer { routingLock.unlock() }
        return _routing
    }

    func adoptRouting(_ newRouting: RedisCommandRouting) {
        routingLock.lock()
        _routing = newRouting
        routingLock.unlock()
    }

    private let stateLock = NSLock()
    private let cancellationGate = PluginQueryCancellationGate()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _database: RedisSessionDatabase
    private var _footprint = RedisSessionFootprint()

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    private var isShuttingDown: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isShuttingDown
        }
        set {
            stateLock.lock()
            _isShuttingDown = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Initialization

    init(
        host: String,
        port: Int,
        username: String? = nil,
        password: String?,
        database: Int = 0,
        sslConfig: SSLConfiguration = SSLConfiguration(),
        connectTimeout: TimeInterval = 10
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
        self.connectTimeout = connectTimeout
        self._database = RedisSessionDatabase(database)
    }

    deinit {
        #if canImport(CRedis)
        stateLock.lock()
        let handle = context
        let ssl = sslContext
        context = nil
        sslContext = nil
        stateLock.unlock()

        // Dispatch cleanup to the serial queue to ensure in-flight commands complete first
        if handle != nil || ssl != nil {
            let cleanupQueue = queue
            cleanupQueue.async {
                if let handle { redisFree(handle) }
                if let ssl { redisFreeSSLContext(ssl) }
            }
        }
        #endif
    }

    // MARK: - Connection Management

    func connect(reportingStage report: @escaping ConnectionStageReporter = { _ in }) async throws {
        #if canImport(CRedis)
        _ = Self.initOnce
        try await pluginDispatchAsync(on: queue) { [self] in
            logger.debug("Connecting to Redis at \(self.host):\(self.port)")

            try openContextSync(selectDatabase: database, reportingStage: report)

            let versionString = fetchServerVersionSync()

            stateLock.lock()
            _cachedServerVersion = versionString
            _isConnected = true
            _database = RedisSessionDatabase(database)
            stateLock.unlock()

            logger.info("Connected to Redis \(versionString ?? "unknown")")
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        #if canImport(CRedis)
        let handle = context
        let ssl = sslContext
        context = nil
        sslContext = nil
        #endif
        _isConnected = false
        _cachedServerVersion = nil
        _database = RedisSessionDatabase(database)
        _footprint = RedisSessionFootprint()
        stateLock.unlock()

        #if canImport(CRedis)
        let cleanupQueue = queue
        if handle != nil || ssl != nil {
            cleanupQueue.async {
                if let handle = handle {
                    redisFree(handle)
                }
                if let ssl = ssl {
                    redisFreeSSLContext(ssl)
                }
            }
        }
        #endif
    }

    // MARK: - Cancellation

    func cancelCurrentQuery() {
        cancellationGate.cancel()
    }

    private func throwIfCancelled(_ generation: Int) throws {
        guard cancellationGate.isCancelled(generation) else { return }
        throw CancellationError()
    }

    // MARK: - Server Information

    func serverVersion() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cachedServerVersion
    }

    func currentDatabase() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _database.current
    }

    func databaseForNextCommand() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _footprint.pendingDatabase ?? _database.current
    }

    func homeDatabase() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _database.home
    }

    // MARK: - Command Execution

    /// The session's held state is read on the serial queue, right before the send, so a `MULTI`
    /// already queued ahead of this command is what it is checked against.
    func executeCommand(_ args: [Data], scope: RedisCommandScope) async throws -> RedisReply {
        #if canImport(CRedis)
        let visiting = RedisDatabaseVisit.database
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else {
                throw RedisPluginError.notConnected
            }
            stateLock.lock()
            guard context != nil else {
                stateLock.unlock()
                throw RedisPluginError.notConnected
            }
            stateLock.unlock()
            try admit(scope, command: args.first)
            try moveToCommandDatabase(visiting: visiting)
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            let result = try executeCommandSyncRetrying(args, scope: scope)
            try throwIfCancelled(generation)
            return result
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    func executePipeline(_ commands: [[Data]], scope: RedisCommandScope) async throws -> [RedisReply] {
        #if canImport(CRedis)
        let visiting = RedisDatabaseVisit.database
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else {
                throw RedisPluginError.notConnected
            }
            stateLock.lock()
            guard context != nil else {
                stateLock.unlock()
                throw RedisPluginError.notConnected
            }
            stateLock.unlock()
            try admit(scope, command: commands.first?.first)
            try moveToCommandDatabase(visiting: visiting)
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            let results = try executePipelineSyncRetrying(commands, scope: scope)
            try throwIfCancelled(generation)
            return results
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    /// Hands a lost block or `WATCH` to the connection that replaces this one, so a Sentinel
    /// failover that re-points mid-block still reports it.
    func sessionStateForHandOver() -> RedisHeldState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _footprint.pendingLoss ?? _footprint.heldState
    }

    func adoptLostSessionState(_ held: RedisHeldState?) {
        stateLock.lock()
        _footprint.adoptLoss(held)
        stateLock.unlock()
    }

    /// Runs on the serial queue right before the send, so no other command can land between the
    /// move and the command it is for. An open block is left alone: a visit is held back from one,
    /// so the session cannot be away from home while it is open.
    private func moveToCommandDatabase(visiting: Int?) throws {
        stateLock.lock()
        let target = _footprint.hasOpenBlock ? nil : _database.databaseToMoveTo(visiting: visiting)
        stateLock.unlock()
        guard let target else { return }
        try select(target, scope: .outsideBlock)
        stateLock.lock()
        _database.visited(target)
        stateLock.unlock()
    }

    private func select(_ index: Int, scope: RedisCommandScope) throws {
        let reply = try executeCommandSyncRetrying(["SELECT", String(index)].map { Data($0.utf8) }, scope: scope)
        if case .error(let msg) = reply {
            throw RedisPluginError(code: 2, message: "SELECT \(index) failed: \(msg)")
        }
        guard reply.isQueued else { return }
        stateLock.lock()
        _footprint.queueDatabase(index)
        stateLock.unlock()
        throw RedisQueuedCommand(command: "SELECT")
    }

    private func admit(_ scope: RedisCommandScope, command: Data?) throws {
        let name = command.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        stateLock.lock()
        defer { stateLock.unlock() }
        if scope == .session, let lost = _footprint.takePendingLoss() {
            throw RedisSessionStateLost(held: lost, outcomeUnknown: false)
        }
        if let held = _footprint.heldBack(scope) {
            throw RedisHeldBackCommand(command: name, held: held)
        }
    }

    // MARK: - Database Selection

    /// A `SELECT` the server queued into an open `MULTI` block has not moved the session, so the
    /// index is held aside until the block resolves rather than recorded now, and the caller hears
    /// it was queued. Recording it now is right only if `EXEC` follows: after a `DISCARD` the
    /// session is still on the old database, and a `FLUSHDB` staged against the row the app
    /// believed it was on would empty that one.
    func selectDatabase(_ index: Int, scope: RedisCommandScope) async throws {
        try await moveSession(to: index, scope: scope) { $0.selected(index) }
    }

    func visitDatabase(_ index: Int) async throws {
        try await moveSession(to: index, scope: .outsideBlock) { $0.visited(index) }
    }

    private func moveSession(
        to index: Int,
        scope: RedisCommandScope,
        recording move: @escaping @Sendable (inout RedisSessionDatabase) -> Void
    ) async throws {
        #if canImport(CRedis)
        try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else {
                throw RedisPluginError.notConnected
            }
            stateLock.lock()
            guard context != nil else {
                stateLock.unlock()
                throw RedisPluginError.notConnected
            }
            stateLock.unlock()
            try admit(scope, command: Data("SELECT".utf8))
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            try select(index, scope: scope)
            stateLock.lock()
            move(&_database)
            stateLock.unlock()
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }
}

// MARK: - Synchronous Helpers (must be called on the serial queue)

#if canImport(CRedis)
private extension RedisPluginConnection {
    func connectSSL(_ ctx: UnsafeMutablePointer<redisContext>) throws {
        var sslError = redisSSLContextError(0)

        let useCaCert = sslConfig.verifiesCertificate && !sslConfig.caCertificatePath.isEmpty
        let caCert: UnsafePointer<CChar>? = useCaCert
            ? (sslConfig.caCertificatePath as NSString).utf8String
            : nil
        let clientCert: UnsafePointer<CChar>? = sslConfig.clientCertificatePath.isEmpty
            ? nil
            : (sslConfig.clientCertificatePath as NSString).utf8String
        let clientKey: UnsafePointer<CChar>? = sslConfig.clientKeyPath.isEmpty
            ? nil
            : (sslConfig.clientKeyPath as NSString).utf8String
        let sniHostname: UnsafePointer<CChar>? = sslConfig.isEnabled
            ? (host as NSString).utf8String
            : nil

        var options = redisSSLOptions()
        options.cacert_filename = caCert
        options.capath = nil
        options.cert_filename = clientCert
        options.private_key_filename = clientKey
        options.server_name = sniHostname
        options.verify_mode = sslConfig.verifiesCertificate
            ? REDIS_SSL_VERIFY_PEER
            : REDIS_SSL_VERIFY_NONE

        guard let ssl = redisCreateSSLContextWithOptions(&options, &sslError) else {
            let errCode = Int(sslError.rawValue)
            throw RedisPluginError(
                code: errCode,
                message: "Failed to create SSL context (error \(errCode))"
            )
        }

        let result = redisInitiateSSLWithContext(ctx, ssl)
        if result != REDIS_OK {
            redisFreeSSLContext(ssl)
            let errMsg = Self.contextErrorMessage(ctx)
            if let sslError = RedisSSLClassifier.classifySSLError(errMsg) {
                throw sslError
            }
            throw RedisPluginError(code: Int(result), message: "SSL handshake failed: \(errMsg)")
        }

        self.sslContext = ssl
        logger.debug("SSL connection established")
    }

    static func contextErrorMessage(_ ctx: UnsafeMutablePointer<redisContext>) -> String {
        withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
    }

    func openContextSync(
        selectDatabase dbIndex: Int,
        reportingStage report: ConnectionStageReporter = { _ in }
    ) throws {
        let budget = timeval(
            tv_sec: Int(connectTimeout),
            tv_usec: Int32((connectTimeout - connectTimeout.rounded(.down)) * 1_000_000)
        )
        guard let ctx = redisConnectWithTimeout(host, Int32(port), budget) else {
            logger.error("Failed to create Redis context")
            throw RedisPluginError.connectionFailed
        }

        if ctx.pointee.err != 0 {
            let errMsg = Self.contextErrorMessage(ctx)
            logger.error("Redis connection error: \(errMsg)")
            let errCode = Int(ctx.pointee.err)
            redisFree(ctx)
            throw RedisPluginError(code: errCode, message: errMsg)
        }

        let commandTimeout = timeval(tv_sec: 30, tv_usec: 0)
        redisSetTimeout(ctx, commandTimeout)
        redisEnableKeepAliveWithInterval(ctx, 60)

        stateLock.lock()
        self.context = ctx
        stateLock.unlock()

        do {
            if sslConfig.isEnabled {
                report(.negotiatingEncryption)
                try connectSSL(ctx)
            }
            if !(try authenticateSync(reportingStage: report)) {
                report(.preparingSession)
                try probeSessionSync()
            }
            if dbIndex != 0 {
                let reply = try executeCommandSync(["SELECT", String(dbIndex)])
                if case .error(let msg) = reply {
                    throw RedisPluginError(code: 2, message: "SELECT \(dbIndex) failed: \(msg)")
                }
            }
        } catch {
            freeContextSync()
            throw error
        }
    }

    /// Reports whether credentials were sent, which decides whether the session still needs
    /// proving. A `+OK` to AUTH is the server naming the identity it bound and answering a round
    /// trip in the same breath, so nothing more is needed. Sending nothing proves nothing, and
    /// only a reply separates an open server from one that will refuse every command.
    @discardableResult
    func authenticateSync(reportingStage report: ConnectionStageReporter = { _ in }) throws -> Bool {
        guard let authArgs = RedisAuthCommand.arguments(username: username, password: password) else { return false }
        report(.authenticating)
        let reply = try executeCommandSync(authArgs)
        guard case .error(let msg) = reply else { return true }
        let failure = RedisAuthCommand.failure(
            serverError: msg,
            hadUsername: !(username ?? "").isEmpty,
            hadPassword: !(password ?? "").isEmpty
        )
        throw RedisPluginError(
            code: 1,
            message: String(format: String(localized: "AUTH failed: %@"), msg),
            detail: RedisAuthCommand.hint(for: failure),
            refusedByServer: true
        )
    }

    /// Asks the server whether this connection holds any identity, for the case where nothing was
    /// sent to give it one. Runs on every path that makes a connection usable, `reconnectSync`
    /// included, so an unauthenticated session is never declared live.
    func probeSessionSync() throws {
        let reply = try executeCommandSync(RedisConnectProbe.command)
        let outcome = RedisConnectProbe.outcome(errorMessage: reply.errorMessage)
        guard let message = outcome.failureMessage else { return }
        throw RedisPluginError(
            code: 3,
            message: message,
            detail: outcome.failureHint,
            refusedByServer: true
        )
    }

    /// Freeing the context is what makes the connection unusable, so the flag that reports it
    /// usable goes with it. A reconnect that frees the old context and then fails to open a new
    /// one used to leave `isConnected` true over a nil context, and the cluster channel went on
    /// handing that object out until the health monitor replaced it.
    func freeContextSync() {
        stateLock.lock()
        let handle = context
        let ssl = sslContext
        context = nil
        sslContext = nil
        _isConnected = false
        _footprint.sessionEnded()
        stateLock.unlock()
        if let handle { redisFree(handle) }
        if let ssl { redisFreeSSLContext(ssl) }
    }

    func reconnectSync() throws {
        guard !isShuttingDown else { throw RedisPluginError.notConnected }
        let targetDatabase = currentDatabase()
        logger.warning("Redis connection lost; reconnecting to \(self.host):\(self.port), database \(targetDatabase)")
        freeContextSync()
        try openContextSync(selectDatabase: targetDatabase)
        stateLock.lock()
        _isConnected = true
        stateLock.unlock()
    }

    func executeCommandSync(_ args: [String]) throws -> RedisReply {
        try executeCommandSync(args.map { Data($0.utf8) })
    }

    /// A lost connection is only safe to replay over when the command provably never ran.
    ///
    /// hiredis reports a read timeout as REDIS_ERR_IO, exactly like a failed write, so the old
    /// "reconnect and send it again" retried commands the server had already executed: a stalled
    /// server made one INCR count twice. The write and the read are split so the failure knows
    /// which side it happened on. An incomplete RESP command is never executed, so a failed write
    /// is always replayable; once the command is on the wire only a read-only command is.
    func executeCommandSyncRetrying(_ args: [Data], scope: RedisCommandScope) throws -> RedisReply {
        let reply = try sendAllowingReplay(args, scope: scope)
        observe(command: args.first, reply: reply)
        return reply
    }

    private func sendAllowingReplay(_ args: [Data], scope: RedisCommandScope) throws -> RedisReply {
        do {
            return try executeCommandSync(args)
        } catch let failure as RedisTransportFailure where !isShuttingDown {
            try reportLostSessionState(for: args.first, scope: scope, after: failure)
            guard canReplay(args, after: failure) else { throw failure }
            try reconnectSync()
            return try executeCommandSync(args)
        }
    }

    /// The user's own command was meant for a block or a `WATCH` the dropped session held, so
    /// sending it again on a new session would run it outside the transaction it belongs to. It
    /// reports the loss instead, and the connection is reopened so the next command works. A read
    /// the app makes replays as before and leaves the loss for the user's next command.
    private func reportLostSessionState(
        for command: Data?,
        scope: RedisCommandScope,
        after failure: RedisTransportFailure
    ) throws {
        guard scope == .session, let held = heldOrLostState() else { return }
        let isExec = command.flatMap { String(data: $0, encoding: .utf8) }?.uppercased() == "EXEC"
        do {
            try reconnectSync()
        } catch {
            logger.warning("Reconnect after a lost \(String(describing: held), privacy: .public) failed")
        }
        stateLock.lock()
        _ = _footprint.takePendingLoss()
        stateLock.unlock()
        throw RedisSessionStateLost(held: held, outcomeUnknown: isExec && failure.wasDelivered)
    }

    /// A pipeline that fails has already let go of its context, which latched what it held.
    private func heldOrLostState() -> RedisHeldState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _footprint.heldState ?? _footprint.pendingLoss
    }

    /// Every reply tells the footprint what the session holds now. The block a queued `SELECT` was
    /// held in may have resolved, so the session's database follows the server's own answer.
    /// `reconnectSync` frees the context, which drops any pending index, so a replay never promotes
    /// one the lost session had queued.
    private func observe(command: Data?, reply: RedisReply) {
        let name = command.flatMap { String(data: $0, encoding: .utf8) }
        stateLock.lock()
        if let selected = _footprint.observe(command: name, reply: reply) {
            _database.selected(selected)
        }
        stateLock.unlock()
    }

    /// A pipeline puts several commands in one buffer, so a read failure part-way through cannot
    /// say which of them ran. Replaying is only safe when none of them writes.
    func executePipelineSyncRetrying(_ commands: [[Data]], scope: RedisCommandScope) throws -> [RedisReply] {
        let replies: [RedisReply]
        do {
            replies = try executePipelineSync(commands)
        } catch let failure as RedisTransportFailure where !isShuttingDown {
            try reportLostSessionState(for: commands.first?.first, scope: scope, after: failure)
            guard !failure.wasDelivered || commands.allSatisfy({ routing.isReadOnly($0) }) else { throw failure }
            try reconnectSync()
            replies = try executePipelineSync(commands)
        }
        for (command, reply) in zip(commands, replies) {
            observe(command: command.first, reply: reply)
        }
        return replies
    }

    func canReplay(_ args: [Data], after failure: RedisTransportFailure) -> Bool {
        !failure.wasDelivered || routing.isReadOnly(args)
    }

    /// The append/flush/read split that `redisCommandArgv` performs internally, spelled out so a
    /// failure can say whether the command reached the server. hiredis does exactly these three
    /// steps, so the behaviour is unchanged.
    func executeCommandSync(_ args: [Data]) throws -> RedisReply {
        stateLock.lock()
        guard let ctx = context else {
            stateLock.unlock()
            throw RedisPluginError.notConnected
        }
        stateLock.unlock()

        let argc = Int32(args.count)

        try withArgvPointers(args: args) { argv, argvlen in
            guard redisAppendCommandArgv(ctx, argc, argv, argvlen) == REDIS_OK else {
                throw transportFailure(ctx, delivered: false)
            }
        }

        var done: Int32 = 0
        while done == 0 {
            guard redisBufferWrite(ctx, &done) == REDIS_OK else {
                throw transportFailure(ctx, delivered: false)
            }
        }

        var rawReply: UnsafeMutableRawPointer?
        guard redisGetReply(ctx, &rawReply) == REDIS_OK, let reply = rawReply else {
            throw transportFailure(ctx, delivered: true)
        }

        let replyPtr = reply.assumingMemoryBound(to: redisReply.self)
        let parsed = parseReply(replyPtr)
        freeReplyObject(reply)
        return parsed
    }

    func transportFailure(_ ctx: UnsafeMutablePointer<redisContext>, delivered: Bool) -> RedisTransportFailure {
        let code = Int(ctx.pointee.err)
        let message = code == 0 ? "No reply from Redis" : Self.contextErrorMessage(ctx)
        return RedisTransportFailure(code: code == 0 ? -1 : code, message: message, wasDelivered: delivered)
    }

    func executePipelineSync(_ commands: [[Data]]) throws -> [RedisReply] {
        stateLock.lock()
        guard let ctx = context else {
            stateLock.unlock()
            throw RedisPluginError.notConnected
        }
        stateLock.unlock()
        guard !commands.isEmpty else { return [] }

        var appendedCount = 0
        for args in commands {
            let argc = Int32(args.count)
            try withArgvPointers(args: args) { argv, argvlen in
                let status = redisAppendCommandArgv(ctx, argc, argv, argvlen)
                if status != REDIS_OK {
                    for _ in 0 ..< appendedCount {
                        var discard: UnsafeMutableRawPointer?
                        if redisGetReply(ctx, &discard) != REDIS_OK { break }
                        if let d = discard { freeReplyObject(d) }
                    }
                    let failure = transportFailure(ctx, delivered: false)
                    markDisconnected()
                    throw failure
                }
            }
            appendedCount += 1
        }

        var replies: [RedisReply] = []
        replies.reserveCapacity(commands.count)
        for i in 0 ..< commands.count {
            var rawReply: UnsafeMutableRawPointer?
            let status = redisGetReply(ctx, &rawReply)
            guard status == REDIS_OK, let reply = rawReply else {
                let failure = transportFailure(ctx, delivered: true)
                for _ in (i + 1) ..< commands.count {
                    var discard: UnsafeMutableRawPointer?
                    if redisGetReply(ctx, &discard) == REDIS_OK, let d = discard {
                        freeReplyObject(d)
                    }
                }
                markDisconnected()
                throw failure
            }
            let replyPtr = reply.assumingMemoryBound(to: redisReply.self)
            let parsed = parseReply(replyPtr)
            freeReplyObject(reply)
            replies.append(parsed)
        }
        return replies
    }

    func markDisconnected() {
        stateLock.lock()
        let handle = context
        context = nil
        _isConnected = false
        _footprint.sessionEnded()
        stateLock.unlock()
        #if canImport(CRedis)
        if let handle {
            let cleanupQueue = queue
            cleanupQueue.async {
                redisFree(handle)
            }
        }
        #endif
    }

    func withArgvPointers<T>(
        args: [Data],
        body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, UnsafeMutablePointer<Int>) throws -> T
    ) rethrows -> T {
        let count = args.count

        let buffers: [UnsafeMutablePointer<CChar>] = args.map { arg in
            let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: arg.count + 1)
            arg.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: CChar.self).baseAddress {
                    ptr.initialize(from: base, count: arg.count)
                }
            }
            ptr[arg.count] = 0
            return ptr
        }
        defer { buffers.forEach { $0.deallocate() } }

        let argv = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: count)
        let argvlen = UnsafeMutablePointer<Int>.allocate(capacity: count)
        defer {
            argv.deallocate()
            argvlen.deallocate()
        }

        for i in 0 ..< count {
            argv[i] = UnsafePointer(buffers[i])
            argvlen[i] = args[i].count
        }

        return try body(argv, argvlen)
    }

    func parseReply(_ reply: UnsafeMutablePointer<redisReply>) -> RedisReply {
        let type = reply.pointee.type

        switch type {
        case REDIS_REPLY_STRING:
            if let str = reply.pointee.str {
                let len = reply.pointee.len
                let data = Data(bytes: str, count: len)
                if let string = String(data: data, encoding: .utf8) {
                    return .string(string)
                }
                return .data(data)
            }
            return .null

        case REDIS_REPLY_INTEGER:
            return .integer(reply.pointee.integer)

        case REDIS_REPLY_ARRAY:
            let count = reply.pointee.elements
            guard count > 0, let elements = reply.pointee.element else {
                return .array([])
            }
            var items: [RedisReply] = []
            items.reserveCapacity(count)
            for i in 0 ..< count {
                if let element = elements[i] {
                    items.append(parseReply(element))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)

        case REDIS_REPLY_NIL:
            return .null

        case REDIS_REPLY_STATUS:
            if let str = reply.pointee.str {
                let len = reply.pointee.len
                let data = Data(bytes: str, count: len)
                return .status(String(data: data, encoding: .utf8) ?? "")
            }
            return .status("")

        case REDIS_REPLY_ERROR:
            if let str = reply.pointee.str {
                let len = reply.pointee.len
                let data = Data(bytes: str, count: len)
                return .error(String(data: data, encoding: .utf8) ?? "Unknown error")
            }
            return .error("Unknown error")

        case REDIS_REPLY_DOUBLE:
            if let str = reply.pointee.str {
                let len = reply.pointee.len
                let data = Data(bytes: str, count: len)
                if let string = String(data: data, encoding: .utf8) {
                    return .string(string)
                }
            }
            return .string(String(reply.pointee.dval))

        case REDIS_REPLY_BOOL:
            return .integer(reply.pointee.integer)

        case REDIS_REPLY_MAP:
            let count = reply.pointee.elements
            guard count > 0, let elements = reply.pointee.element else {
                return .array([])
            }
            var items: [RedisReply] = []
            items.reserveCapacity(count)
            for i in 0 ..< count {
                if let element = elements[i] {
                    items.append(parseReply(element))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)

        case REDIS_REPLY_SET, REDIS_REPLY_PUSH:
            let count = reply.pointee.elements
            guard count > 0, let elements = reply.pointee.element else {
                return .array([])
            }
            var items: [RedisReply] = []
            items.reserveCapacity(count)
            for i in 0 ..< count {
                if let element = elements[i] {
                    items.append(parseReply(element))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)

        case REDIS_REPLY_BIGNUM, REDIS_REPLY_VERB:
            if let str = reply.pointee.str {
                let len = reply.pointee.len
                let data = Data(bytes: str, count: len)
                if let string = String(data: data, encoding: .utf8) {
                    return .string(string)
                }
                return .data(data)
            }
            return .null

        default:
            logger.warning("Unknown Redis reply type: \(type)")
            return .null
        }
    }

    func fetchServerVersionSync() -> String? {
        stateLock.lock()
        guard context != nil else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        do {
            let reply = try executeCommandSync(["INFO", "server"])
            if case .string(let info) = reply {
                return RedisServerInfo.version(from: info)
            }
        } catch {
            logger.debug("Failed to fetch server version: \(error.localizedDescription)")
        }
        return nil
    }
}
#endif
