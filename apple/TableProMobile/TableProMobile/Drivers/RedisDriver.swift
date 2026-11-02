import CRedis
import Foundation
import os
import TableProDatabase
import TableProModels
import TableProRedisCore

nonisolated final class RedisDriver: DatabaseDriver, KeyContentsBrowsing, @unchecked Sendable {
    private let actor = RedisActor()
    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?
    private let database: Int
    let ssl: DriverSSLConfiguration

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }

    // Set once during connect() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(
        host: String,
        port: Int,
        username: String? = nil,
        password: String?,
        database: Int = 0,
        ssl: DriverSSLConfiguration = .disabled
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.ssl = ssl
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            ssl: ssl
        )
        serverVersion = try? await actor.fetchServerVersion()
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        let reply = try await actor.command(["PING"])
        if case .status(let s) = reply, s == "PONG" { return true }
        if case .string(let s) = reply, s == "PONG" { return true }
        return false
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let start = Date()
        let reply = try await actor.command(Self.commandArguments(query))
        let elapsed = Date().timeIntervalSince(start)
        return try RedisQueryResultBuilder.result(for: reply, executionTime: elapsed)
    }

    func cancelCurrentQuery() async throws {
        // hiredis does not support async cancel
    }

    // MARK: - Schema (Redis key space mapped to tables)

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        try await RedisKeyspaceReads.keys(sending: send).sorted().map {
            TableInfo(name: $0, type: .table, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let typeName = try await RedisKeyspaceReads.typeName(ofKey: table, sending: send)

        return [
            ColumnInfo(
                name: "key",
                typeName: "string",
                isPrimaryKey: true,
                isNullable: false,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: 0
            ),
            ColumnInfo(
                name: "value",
                typeName: typeName,
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: 1
            )
        ]
    }

    func keyContentsPage(ofKey key: String, limit: Int, offset: Int) async throws -> KeyContentsPage {
        try await RedisKeyBrowse.page(ofKey: key, limit: limit, offset: offset, sending: send)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        []
    }

    func fetchDatabases() async throws -> [String] {
        let reply = try await actor.command(["CONFIG", "GET", "databases"])
        var count = 16
        if case .array(let parts) = reply, parts.count >= 2 {
            if case .string(let numStr) = parts[1], let n = Int(numStr) {
                count = n
            }
        }
        return (0..<count).map { "db\($0)" }
    }

    func switchDatabase(to name: String) async throws {
        let dbNum: String
        if name.hasPrefix("db"), let n = Int(name.dropFirst(2)) {
            dbNum = String(n)
        } else if Int(name) != nil {
            dbNum = name
        } else {
            throw RedisError.queryFailed("Invalid database name: \(name). Expected db0, db1, etc.")
        }

        try await send(["SELECT", dbNum]).throwIfError().throwIfQueued("SELECT")
    }

    func switchSchema(to name: String) async throws {
        throw RedisError.unsupported("Redis does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        throw RedisError.unsupported("Transactions not supported in mobile Redis driver")
    }

    func commitTransaction() async throws {
        throw RedisError.unsupported("Transactions not supported in mobile Redis driver")
    }

    func rollbackTransaction() async throws {
        throw RedisError.unsupported("Transactions not supported in mobile Redis driver")
    }

    // MARK: - Private Helpers

    private func send(_ arguments: [String]) async throws -> RedisReplyValue {
        try await actor.command(arguments)
    }

    static func commandArguments(_ query: String) throws -> [Data] {
        switch RedisSingleCommand(query) {
        case .arguments(let arguments):
            return arguments
        case .empty:
            throw RedisError.queryFailed("Empty command")
        case .unbalancedQuotes:
            throw RedisError.queryFailed(String(localized: "unbalanced quotes"))
        case .severalCommands:
            throw RedisError.queryFailed(RedisSingleCommand.severalCommandsMessage)
        }
    }
}

// MARK: - Redis Actor (thread-safe C API access)

private actor RedisActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RedisActor")
    private var ctx: UnsafeMutablePointer<redisContext>?

    private static let initSSL: Void = {
        let result = redisInitOpenSSL()
        if result != REDIS_OK {
            logger.warning("redisInitOpenSSL failed with code \(result)")
        }
    }()

    func connect(
        host: String,
        port: Int,
        username: String?,
        password: String?,
        database: Int,
        ssl: DriverSSLConfiguration
    ) throws {
        close()

        guard let portI32 = Int32(exactly: port), (1...65_535).contains(port) else {
            throw RedisError.connectionFailed(
                "Port \(port) is out of range. Use a value between 1 and 65535."
            )
        }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        guard let context = redisConnectWithTimeout(host, portI32, tv) else {
            throw RedisError.connectionFailed("Failed to create Redis context")
        }
        HiredisReply.installIterativeFree(on: context)

        if context.pointee.err != 0 {
            let msg = withUnsafePointer(to: &context.pointee.errstr.0) { String(cString: $0) }
            redisFree(context)
            throw RedisError.connectionFailed(msg)
        }

        tv = timeval(tv_sec: 30, tv_usec: 0)
        redisSetTimeout(context, tv)

        if ssl.isEnabled {
            _ = Self.initSSL
            do throws(RedisTLSFailure) {
                try RedisTLSSession.initiate(on: context, options: RedisTLSOptions(ssl: ssl, host: host))
            } catch {
                redisFree(context)
                throw RedisError(tlsFailure: error)
            }
        }

        self.ctx = context

        do {
            if let authArgs = RedisAuthCommand.arguments(username: username, password: password) {
                let reply = try executeCommand(authArgs)
                if case .error(let msg) = reply {
                    throw RedisError.authenticationFailed(
                        serverMessage: msg,
                        failure: RedisAuthCommand.failure(
                            serverError: msg,
                            hadUsername: !(username ?? "").isEmpty,
                            hadPassword: !(password ?? "").isEmpty
                        )
                    )
                }
            } else {
                let probe = try executeCommand(RedisConnectProbe.command)
                let outcome = RedisConnectProbe.outcome(errorMessage: probe.errorMessage)
                if outcome != .established {
                    throw RedisError.sessionUnverified(outcome)
                }
            }

            if database != 0 {
                let reply = try executeCommand(["SELECT", String(database)])
                if case .error(let msg) = reply {
                    throw RedisError.connectionFailed("Failed to select database \(database): \(msg)")
                }
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        guard let ctx else { return }
        redisFree(ctx)
        self.ctx = nil
    }

    func command(_ args: [String]) throws -> RedisReplyValue {
        try executeCommand(args.map { Data($0.utf8) })
    }

    func command(_ args: [Data]) throws -> RedisReplyValue {
        try executeCommand(args)
    }

    func fetchServerVersion() throws -> String? {
        let reply = try executeCommand(["INFO", "server"])
        guard case .string(let info) = reply else { return nil }

        for line in info.split(separator: "\n") {
            if line.hasPrefix("redis_version:") {
                return String(line.dropFirst("redis_version:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func executeCommand(_ args: [String]) throws -> RedisReplyValue {
        try executeCommand(args.map { Data($0.utf8) })
    }

    private func executeCommand(_ args: [Data]) throws -> RedisReplyValue {
        guard let ctx else { throw RedisError.notConnected }

        let rawReply = RedisCommandArgv.withPointers(args) { argv, argvlen in
            redisCommandArgv(ctx, Int32(args.count), argv, argvlen)
        }
        guard let rawReply else {
            if ctx.pointee.err != 0 {
                let msg = withUnsafePointer(to: &ctx.pointee.errstr.0) { String(cString: $0) }
                throw RedisError.connectionFailed(msg)
            }
            throw RedisError.connectionFailed("No reply from server")
        }

        defer { HiredisReply.release(rawReply) }

        return HiredisReply.value(of: rawReply.assumingMemoryBound(to: redisReply.self))
    }
}

// A server decides how deep a reply nests, a few bytes a level.
nonisolated enum HiredisReply {
    // Deeper than any command or module replies. Past it a reply is not built, so nothing that walks one later
    // runs out of stack.
    static let maximumDepth = 128

    static func value(of reply: UnsafeMutablePointer<redisReply>, depth: Int = 0) -> RedisReplyValue {
        switch reply.pointee.type {
        case REDIS_REPLY_STRING:
            return text(of: reply).map(RedisReplyValue.string) ?? .null

        case REDIS_REPLY_INTEGER:
            return .integer(reply.pointee.integer)

        case REDIS_REPLY_ARRAY:
            guard depth < maximumDepth else {
                return .error(String(localized: "Reply nested too deeply to show"))
            }
            let count = reply.pointee.elements
            guard count > 0, let elements = reply.pointee.element else {
                return .array([])
            }
            var items: [RedisReplyValue] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                items.append(elements[index].map { value(of: $0, depth: depth + 1) } ?? .null)
            }
            return .array(items)

        case REDIS_REPLY_STATUS:
            return .status(text(of: reply) ?? "OK")

        case REDIS_REPLY_ERROR:
            return .error(text(of: reply) ?? "Unknown error")

        case REDIS_REPLY_NIL:
            return .null

        default:
            return .null
        }
    }

    // freeReplyObject recurses once per level, which a deeply nested reply overflows. Detaching each node's
    // children first leaves every call one node to free.
    static func release(_ reply: UnsafeMutableRawPointer) {
        var pending = [reply.assumingMemoryBound(to: redisReply.self)]
        while let node = pending.popLast() {
            if let elements = node.pointee.element {
                for index in 0..<node.pointee.elements {
                    guard let child = elements[index] else { continue }
                    pending.append(child)
                    elements[index] = nil
                }
            }
            freeReplyObject(node)
        }
    }

    // hiredis frees a reply it has not handed over (cut short by a protocol error or a freed context) and every
    // RESP3 push it drops with freeReplyObject. Both go through release instead.
    static func installIterativeFree(on context: UnsafeMutablePointer<redisContext>) {
        if let functions, let reader = context.pointee.reader {
            reader.pointee.fn = functions
        }
        redisSetPushCallback(context) { _, reply in
            if let reply { HiredisReply.release(reply) }
        }
    }

    // A reader keeps this pointer for its whole life, so the table is built once and never written again.
    nonisolated(unsafe) private static let functions: UnsafeMutablePointer<redisReplyObjectFunctions>? = {
        guard let reader = redisReaderCreate() else { return nil }
        defer { redisReaderFree(reader) }
        guard let defaults = reader.pointee.fn else { return nil }
        let table = UnsafeMutablePointer<redisReplyObjectFunctions>.allocate(capacity: 1)
        table.initialize(to: defaults.pointee)
        table.pointee.freeObject = { reply in
            if let reply { HiredisReply.release(reply) }
        }
        return table
    }()

    // Read by length: a bulk string can hold a NUL.
    private static func text(of reply: UnsafeMutablePointer<redisReply>) -> String? {
        guard let str = reply.pointee.str else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: str, count: reply.pointee.len), as: UTF8.self)
    }
}

// MARK: - Errors

nonisolated enum RedisError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case authenticationFailed(serverMessage: String, failure: RedisAuthCommand.Failure)
    case sessionUnverified(RedisConnectProbe.Outcome)
    case notConnected
    case queryFailed(String)
    case commandQueued(String)
    case keyNotFound(String)
    case keyTypeNotBrowsable(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Redis connection failed: \(msg)"
        case .authenticationFailed(let serverMessage, let failure):
            guard let hint = RedisAuthCommand.hint(for: failure) else {
                return String(format: String(localized: "Redis authentication failed: %@"), serverMessage)
            }
            return String(
                format: String(localized: "Redis authentication failed: %1$@ %2$@"),
                serverMessage,
                hint
            )
        case .sessionUnverified(let outcome):
            let message = outcome.failureMessage ?? String(localized: "Redis connection failed")
            guard let hint = outcome.failureHint else { return message }
            return "\(message) \(hint)"
        case .notConnected: return "Not connected to Redis"
        case .queryFailed(let msg): return "Redis command failed: \(msg)"
        case .commandQueued(let command):
            let message = String(format: String(localized: "Redis queued %@ instead of running it."), command)
            let hint = String(
                localized: "A MULTI block is open on this connection. Run EXEC to apply it, or DISCARD to drop it."
            )
            return "\(message) \(hint)"
        case .keyNotFound(let key):
            return String(format: String(localized: "The key %@ no longer exists."), key)
        case .keyTypeNotBrowsable(let typeName):
            return String(format: String(localized: "Keys of type %@ cannot be opened here."), typeName)
        case .unsupported(let msg): return msg
        }
    }
}

nonisolated extension RedisError {
    init(tlsFailure: RedisTLSFailure) {
        switch tlsFailure {
        case .contextRejected(let code):
            self = .connectionFailed("Failed to create SSL context (error \(code))")
        case .handshakeFailed(let message), .certificateNameMismatch(let message):
            self = .connectionFailed("SSL handshake failed: \(message)")
        }
    }
}

nonisolated extension RedisTLSOptions {
    init(ssl: DriverSSLConfiguration, host: String) {
        self.init(
            host: ssl.serverName ?? host,
            verifiesCertificate: ssl.verifiesCertificate,
            verifiesHostname: ssl.verifiesHostname,
            caCertificatePath: ssl.existingCACertificatePath,
            clientCertificatePath: ssl.existingClientCertificatePath,
            clientKeyPath: ssl.existingClientKeyPath
        )
    }
}
