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

// MARK: - SSL Configuration

struct RedisSSLConfig {
    var isEnabled: Bool = false
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""

    init() {}

    init(additionalFields: [String: String]) {
        let sslMode = additionalFields["sslMode"] ?? "Disabled"
        self.isEnabled = sslMode != "Disabled"
        self.caCertificatePath = additionalFields["sslCaCertPath"] ?? ""
        self.clientCertificatePath = additionalFields["sslClientCertPath"] ?? ""
        self.clientKeyPath = additionalFields["sslClientKeyPath"] ?? ""
    }
}

// MARK: - Reply Type

enum RedisReply {
    case string(String)
    case integer(Int64)
    case array([RedisReply])
    case data(Data)
    case status(String)
    case error(String)
    case null

    var stringValue: String? {
        switch self {
        case .string(let s), .status(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringArrayValue: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }

    var arrayValue: [RedisReply]? {
        guard case .array(let items) = self else { return nil }
        return items
    }
}

// MARK: - Error Type

struct RedisPluginError: Error {
    let code: Int
    let message: String

    static let notConnected = RedisPluginError(code: 0, message: String(localized: "Not connected to Redis"))
    static let connectionFailed = RedisPluginError(code: 0, message: String(localized: "Failed to establish connection"))
    static let hiredisUnavailable = RedisPluginError(
        code: 0,
        message: String(localized: "Redis support requires hiredis. Run scripts/build-hiredis.sh first.")
    )
}

extension RedisPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { code }
}

// MARK: - Connection Class

final class RedisPluginConnection: @unchecked Sendable {
    // MARK: - Properties

    #if canImport(CRedis)
    private static let initOnce: Void = {
        redisInitOpenSSL()
    }()

    private var context: UnsafeMutablePointer<redisContext>?
    private var sslContext: OpaquePointer?
    #endif

    private let queue = DispatchQueue(label: "com.TablePro.redis.plugin", qos: .userInitiated)
    private let host: String
    private let port: Int
    private let password: String?
    private let database: Int
    private let sslConfig: RedisSSLConfig

    private let stateLock = NSLock()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _isCancelled: Bool = false
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
        password: String?,
        database: Int = 0,
        sslConfig: RedisSSLConfig = RedisSSLConfig()
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
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

    // MARK: - Connection Management

    func connect() async throws {
        #if canImport(CRedis)
        _ = Self.initOnce
        try await pluginDispatchAsync(on: queue) { [self] in
            logger.debug("Connecting to Redis at \(self.host):\(self.port)")

            guard let ctx = redisConnect(host, Int32(port)) else {
                logger.error("Failed to create Redis context")
                throw RedisPluginError.connectionFailed
            }

            if ctx.pointee.err != 0 {
                let errMsg = withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                }
                logger.error("Redis connection error: \(errMsg)")
                let errCode = Int(ctx.pointee.err)
                redisFree(ctx)
                throw RedisPluginError(code: errCode, message: errMsg)
            }

            self.context = ctx

            if sslConfig.isEnabled {
                do {
                    try connectSSL(ctx)
                } catch {
                    redisFree(ctx)
                    self.context = nil
                    throw error
                }
            }

            if let password = password, !password.isEmpty {
                do {
                    let reply = try executeCommandSync(["AUTH", password])
                    if case .error(let msg) = reply {
                        redisFree(ctx)
                        self.context = nil
                        throw RedisPluginError(code: 1, message: "AUTH failed: \(msg)")
                    }
                } catch {
                    redisFree(ctx)
                    self.context = nil
                    throw error
                }
            }

            if database != 0 {
                do {
                    let reply = try executeCommandSync(["SELECT", String(database)])
                    if case .error(let msg) = reply {
                        redisFree(ctx)
                        self.context = nil
                        throw RedisPluginError(code: 2, message: "SELECT \(database) failed: \(msg)")
                    }
                } catch {
                    redisFree(ctx)
                    self.context = nil
                    throw error
                }
            }

            do {
                let reply = try executeCommandSync(["PING"])
                if case .error(let msg) = reply {
                    redisFree(ctx)
                    self.context = nil
                    throw RedisPluginError(code: 3, message: "PING failed: \(msg)")
                }
            } catch {
                redisFree(ctx)
                self.context = nil
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
        _isCancelled = false
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
        stateLock.lock()
        _isCancelled = true
        stateLock.unlock()
    }

    private func checkCancelled() throws {
        stateLock.lock()
        let cancelled = _isCancelled
        if cancelled { _isCancelled = false }
        stateLock.unlock()
        if cancelled {
            throw RedisPluginError(code: 0, message: "Query cancelled")
        }
    }

    private func resetCancellation() {
        stateLock.lock()
        _isCancelled = false
        stateLock.unlock()
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
        #if canImport(CRedis)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, context != nil else {
                throw RedisPluginError.notConnected
            }
            try checkCancelled()
            let result = try executeCommandSync(args)
            try checkCancelled()
            return result
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    func executePipeline(_ commands: [[String]]) async throws -> [RedisReply] {
        #if canImport(CRedis)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, context != nil else {
                throw RedisPluginError.notConnected
            }
            try checkCancelled()
            let results = try executePipelineSync(commands)
            try checkCancelled()
            return results
        }
        #else
        throw RedisPluginError.hiredisUnavailable
        #endif
    }

    // MARK: - Database Selection

    func selectDatabase(_ index: Int) async throws {
        #if canImport(CRedis)
        resetCancellation()
        try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, context != nil else {
                throw RedisPluginError.notConnected
            }
            try checkCancelled()
            let reply = try executeCommandSync(["SELECT", String(index)])
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

        let caCert: UnsafePointer<CChar>? = sslConfig.caCertificatePath.isEmpty
            ? nil
            : (sslConfig.caCertificatePath as NSString).utf8String
        let clientCert: UnsafePointer<CChar>? = sslConfig.clientCertificatePath.isEmpty
            ? nil
            : (sslConfig.clientCertificatePath as NSString).utf8String
        let clientKey: UnsafePointer<CChar>? = sslConfig.clientKeyPath.isEmpty
            ? nil
            : (sslConfig.clientKeyPath as NSString).utf8String

        guard let ssl = redisCreateSSLContext(caCert, nil, clientCert, clientKey, nil, &sslError) else {
            let errCode = Int(sslError.rawValue)
            throw RedisPluginError(code: errCode, message: "Failed to create SSL context (error \(errCode))")
        }

        self.sslContext = ssl

        let result = redisInitiateSSLWithContext(ctx, ssl)
        if result != REDIS_OK {
            let errMsg = withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            throw RedisPluginError(code: Int(result), message: "SSL handshake failed: \(errMsg)")
        }

        logger.debug("SSL connection established")
    }

    func executeCommandSync(_ args: [String]) throws -> RedisReply {
        guard let ctx = context else { throw RedisPluginError.notConnected }

        let argc = Int32(args.count)
        let lengths = args.map { $0.utf8.count }

        return try withArgvPointers(args: args, lengths: lengths) { argv, argvlen in
            guard let rawReply = redisCommandArgv(ctx, argc, argv, argvlen) else {
                if ctx.pointee.err != 0 {
                    let errMsg = withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                    }
                    throw RedisPluginError(code: Int(ctx.pointee.err), message: errMsg)
                }
                throw RedisPluginError(code: -1, message: "No reply from Redis")
            }

            let replyPtr = rawReply.assumingMemoryBound(to: redisReply.self)
            let parsed = parseReply(replyPtr)
            freeReplyObject(rawReply)
            return parsed
        }
    }

    func executePipelineSync(_ commands: [[String]]) throws -> [RedisReply] {
        guard let ctx = context else { throw RedisPluginError.notConnected }
        guard !commands.isEmpty else { return [] }

        var appendedCount = 0
        for args in commands {
            let argc = Int32(args.count)
            let lengths = args.map { $0.utf8.count }
            try withArgvPointers(args: args, lengths: lengths) { argv, argvlen in
                let status = redisAppendCommandArgv(ctx, argc, argv, argvlen)
                if status != REDIS_OK {
                    for _ in 0 ..< appendedCount {
                        var discard: UnsafeMutableRawPointer?
                        if redisGetReply(ctx, &discard) != REDIS_OK { break }
                        if let d = discard { freeReplyObject(d) }
                    }
                    let errMsg = withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                    }
                    throw RedisPluginError(code: Int(ctx.pointee.err), message: errMsg)
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
                let errMsg = withUnsafePointer(to: &ctx.pointee.errstr) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                }
                for _ in (i + 1) ..< commands.count {
                    var discard: UnsafeMutableRawPointer?
                    if redisGetReply(ctx, &discard) == REDIS_OK, let d = discard {
                        freeReplyObject(d)
                    }
                }
                throw RedisPluginError(code: Int(ctx.pointee.err), message: errMsg)
            }
            let replyPtr = reply.assumingMemoryBound(to: redisReply.self)
            let parsed = parseReply(replyPtr)
            freeReplyObject(reply)
            replies.append(parsed)
        }
        return replies
    }

    func withArgvPointers<T>(
        args: [String],
        lengths: [Int],
        body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, UnsafeMutablePointer<Int>) throws -> T
    ) rethrows -> T {
        let count = args.count

        let cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        let argv = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: count)
        let argvlen = UnsafeMutablePointer<Int>.allocate(capacity: count)
        defer {
            argv.deallocate()
            argvlen.deallocate()
        }

        for i in 0 ..< count {
            argv[i] = UnsafePointer(cStrings[i])
            argvlen[i] = lengths[i]
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
        guard context != nil else { return nil }
        do {
            let reply = try executeCommandSync(["INFO", "server"])
            if case .string(let info) = reply {
                return parseVersionFromInfo(info)
            }
        } catch {
            logger.debug("Failed to fetch server version: \(error.localizedDescription)")
        }
        return nil
    }

    func parseVersionFromInfo(_ info: String) -> String? {
        for line in info.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("redis_version:") {
                let value = trimmed.dropFirst("redis_version:".count)
                return String(value).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
#endif
