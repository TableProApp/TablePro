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
    private var _currentDatabase: Int

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
        self._currentDatabase = database
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

            report(.preparingSession)
            do {
                let pingReply = try executeCommandSync(["PING"])
                if case .error(let msg) = pingReply {
                    throw RedisPluginError(code: 3, message: "PING failed: \(msg)")
                }
            } catch {
                freeContextSync()
                throw error
            }

            let versionString = fetchServerVersionSync()

            stateLock.lock()
            _cachedServerVersion = versionString
            _isConnected = true
            _currentDatabase = database
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
        _currentDatabase = database
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
        return _currentDatabase
    }

    // MARK: - Command Execution

    func executeCommand(_ args: [String]) async throws -> RedisReply {
        try await executeCommand(args.map { Data($0.utf8) })
    }

    func executePipeline(_ commands: [[String]]) async throws -> [RedisReply] {
        try await executePipeline(commands.map { $0.map { Data($0.utf8) } })
    }

    func executeCommand(_ args: [Data]) async throws -> RedisReply {
        #if canImport(CRedis)
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
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            let result = try executeCommandSyncRetrying(args)
            try throwIfCancelled(generation)
            return result
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply] {
        #if canImport(CRedis)
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
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            let results = try executePipelineSyncRetrying(commands)
            try throwIfCancelled(generation)
            return results
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    // MARK: - Database Selection

    func selectDatabase(_ index: Int) async throws {
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
            let generation = cancellationGate.beginQuery()
            defer { cancellationGate.endQuery(generation) }
            let reply = try executeCommandSyncRetrying(["SELECT", String(index)])
            if case .error(let msg) = reply {
                throw RedisPluginError(code: 2, message: "SELECT \(index) failed: \(msg)")
            }
            stateLock.lock()
            _currentDatabase = index
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
            if let password, !password.isEmpty {
                report(.authenticating)
            }
            try authenticateSync()
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

    func authenticateSync() throws {
        guard let authArgs = RedisAuthCommand.arguments(username: username, password: password) else { return }
        let reply = try executeCommandSync(authArgs)
        if case .error(let msg) = reply {
            throw RedisPluginError(code: 1, message: "AUTH failed: \(msg)")
        }
    }

    func freeContextSync() {
        stateLock.lock()
        let handle = context
        let ssl = sslContext
        context = nil
        sslContext = nil
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

    func executeCommandSyncRetrying(_ args: [String]) throws -> RedisReply {
        try executeCommandSyncRetrying(args.map { Data($0.utf8) })
    }

    /// A lost connection is only safe to replay over when the command provably never ran.
    ///
    /// hiredis reports a read timeout as REDIS_ERR_IO, exactly like a failed write, so the old
    /// "reconnect and send it again" retried commands the server had already executed: a stalled
    /// server made one INCR count twice. The write and the read are split so the failure knows
    /// which side it happened on. An incomplete RESP command is never executed, so a failed write
    /// is always replayable; once the command is on the wire only a read-only command is.
    func executeCommandSyncRetrying(_ args: [Data]) throws -> RedisReply {
        do {
            return try executeCommandSync(args)
        } catch let failure as RedisTransportFailure where !isShuttingDown && canReplay(args, after: failure) {
            try reconnectSync()
            return try executeCommandSync(args)
        }
    }

    /// A pipeline puts several commands in one buffer, so a read failure part-way through cannot
    /// say which of them ran. Replaying is only safe when none of them writes.
    func executePipelineSyncRetrying(_ commands: [[Data]]) throws -> [RedisReply] {
        do {
            return try executePipelineSync(commands)
        } catch let failure as RedisTransportFailure
            where !isShuttingDown && (!failure.wasDelivered || commands.allSatisfy({ routing.isReadOnly($0) }))
        {
            try reconnectSync()
            return try executePipelineSync(commands)
        }
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
