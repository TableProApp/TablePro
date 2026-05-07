//
//  RedisDriver.swift
//  TableProMobile
//
//  Redis driver conforming to DatabaseDriver directly (no plugin layer).
//  Maps Redis key-value concepts to the relational DatabaseDriver protocol.
//

import CRedis
import Foundation
import os
import TableProDatabase
import TableProModels

final class RedisDriver: DatabaseDriver, @unchecked Sendable {
    private let actor = RedisActor()
    private let host: String
    private let port: Int
    private let password: String?
    private let database: Int
    let sslEnabled: Bool

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }

    // Set once during connect() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(host: String, port: Int, password: String?, database: Int = 0, sslEnabled: Bool = false) {
        self.host = host
        self.port = port
        self.password = password
        self.database = database
        self.sslEnabled = sslEnabled
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(host: host, port: port, password: password, database: database, sslEnabled: sslEnabled)
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
        let args = parseRedisCommand(query)
        guard !args.isEmpty else {
            throw RedisError.queryFailed("Empty command")
        }

        let reply = try await actor.command(args)
        let elapsed = Date().timeIntervalSince(start)
        return formatReply(reply, executionTime: elapsed)
    }

    func cancelCurrentQuery() async throws {
        // hiredis does not support async cancel
    }

    // MARK: - Schema (Redis key space mapped to tables)

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        var keys: [String] = []
        var cursor = "0"

        repeat {
            let reply = try await actor.command(["SCAN", cursor, "MATCH", "*", "COUNT", "1000"])
            guard case .array(let parts) = reply, parts.count == 2 else { break }

            if case .string(let nextCursor) = parts[0] {
                cursor = nextCursor
            } else {
                break
            }

            if case .array(let keyReplies) = parts[1] {
                for kr in keyReplies {
                    if case .string(let k) = kr { keys.append(k) }
                }
            }

            if keys.count >= 100_000 { break }
        } while cursor != "0"

        return keys.sorted().map {
            TableInfo(name: $0, type: .table, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let reply = try await actor.command(["TYPE", table])
        let typeName: String
        if case .status(let s) = reply {
            typeName = s
        } else if case .string(let s) = reply {
            typeName = s
        } else {
            typeName = "unknown"
        }

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

        let reply = try await actor.command(["SELECT", dbNum])
        if case .error(let msg) = reply {
            throw RedisError.queryFailed(msg)
        }
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

    private func parseRedisCommand(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote: Character?
        var escape = false

        for ch in input {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if let q = inQuote {
                if ch == q {
                    inQuote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                continue
            }
            if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    private func formatReply(_ reply: RedisReplyValue, executionTime: TimeInterval) -> QueryResult {
        switch reply {
        case .string(let s):
            return QueryResult(
                columns: [ColumnInfo(name: "value", typeName: "string", ordinalPosition: 0)],
                rows: [[s]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: nil
            )
        case .integer(let i):
            return QueryResult(
                columns: [ColumnInfo(name: "value", typeName: "integer", ordinalPosition: 0)],
                rows: [[String(i)]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: nil
            )
        case .status(let s):
            return QueryResult(
                columns: [ColumnInfo(name: "status", typeName: "string", ordinalPosition: 0)],
                rows: [[s]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: s
            )
        case .error(let msg):
            return QueryResult(
                columns: [ColumnInfo(name: "error", typeName: "string", ordinalPosition: 0)],
                rows: [[msg]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: nil
            )
        case .array(let items):
            if isHashResult(items) {
                var rows: [[String?]] = []
                for i in stride(from: 0, to: items.count - 1, by: 2) {
                    let key = items[i].stringRepresentation
                    let value = items[i + 1].stringRepresentation
                    rows.append([key, value])
                }
                return QueryResult(
                    columns: [
                        ColumnInfo(name: "key", typeName: "string", ordinalPosition: 0),
                        ColumnInfo(name: "value", typeName: "string", ordinalPosition: 1)
                    ],
                    rows: rows,
                    rowsAffected: 0,
                    executionTime: executionTime,
                    isTruncated: rows.count >= 100_000,
                    statusMessage: nil
                )
            }

            let rows: [[String?]] = items.prefix(100_000).enumerated().map { index, item in
                [String(index), item.stringRepresentation]
            }
            return QueryResult(
                columns: [
                    ColumnInfo(name: "index", typeName: "integer", ordinalPosition: 0),
                    ColumnInfo(name: "value", typeName: "string", ordinalPosition: 1)
                ],
                rows: rows,
                rowsAffected: 0,
                executionTime: executionTime,
                isTruncated: items.count > 100_000,
                statusMessage: nil
            )
        case .null:
            return QueryResult(
                columns: [ColumnInfo(name: "value", typeName: "string", ordinalPosition: 0)],
                rows: [[nil]],
                rowsAffected: 0,
                executionTime: executionTime,
                statusMessage: nil
            )
        }
    }

    private func isHashResult(_ items: [RedisReplyValue]) -> Bool {
        guard items.count >= 2, items.count % 2 == 0 else { return false }
        for i in stride(from: 0, to: items.count, by: 2) {
            if case .string = items[i] { continue }
            return false
        }
        return true
    }
}

// MARK: - Redis Reply Value

private enum RedisReplyValue: Sendable {
    case string(String)
    case integer(Int64)
    case array([RedisReplyValue])
    case status(String)
    case error(String)
    case null

    var stringRepresentation: String? {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .status(let s): return s
        case .error(let s): return s
        case .null: return nil
        case .array(let items): return "[\(items.compactMap(\.stringRepresentation).joined(separator: ", "))]"
        }
    }
}

// MARK: - Redis Actor (thread-safe C API access)

private actor RedisActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RedisActor")
    private var ctx: UnsafeMutablePointer<redisContext>?
    private var sslContext: OpaquePointer?

    private static let initSSL: Void = {
        let result = redisInitOpenSSL()
        if result != REDIS_OK {
            logger.warning("redisInitOpenSSL failed with code \(result)")
        }
    }()

    func connect(host: String, port: Int, password: String?, database: Int, sslEnabled: Bool) throws {
        // Close existing connection if reconnecting
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

        if context.pointee.err != 0 {
            let msg = withUnsafePointer(to: &context.pointee.errstr.0) { String(cString: $0) }
            redisFree(context)
            throw RedisError.connectionFailed(msg)
        }

        tv = timeval(tv_sec: 30, tv_usec: 0)
        redisSetTimeout(context, tv)

        if sslEnabled {
            _ = Self.initSSL

            let ssl: OpaquePointer = try host.withCString { hostCStr in
                var sslError = redisSSLContextError(0)
                var options = redisSSLOptions()
                memset(&options, 0, MemoryLayout<redisSSLOptions>.size)
                options.server_name = hostCStr
                options.verify_mode = REDIS_SSL_VERIFY_NONE

                guard let ssl = redisCreateSSLContextWithOptions(&options, &sslError) else {
                    redisFree(context)
                    throw RedisError.connectionFailed("Failed to create SSL context (error \(sslError.rawValue))")
                }
                return ssl
            }

            let result = redisInitiateSSLWithContext(context, ssl)
            if result != REDIS_OK {
                redisFreeSSLContext(ssl)
                let msg = withUnsafePointer(to: &context.pointee.errstr.0) { String(cString: $0) }
                redisFree(context)
                throw RedisError.connectionFailed("SSL handshake failed: \(msg)")
            }

            self.sslContext = ssl
        }

        self.ctx = context

        do {
            if let password, !password.isEmpty {
                let reply = try executeCommand(["AUTH", password])
                if case .error(let msg) = reply {
                    throw RedisError.connectionFailed("Authentication failed: \(msg)")
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
        if let ctx {
            redisFree(ctx)
            self.ctx = nil
        }
        if let sslContext {
            redisFreeSSLContext(sslContext)
            self.sslContext = nil
        }
    }

    func command(_ args: [String]) throws -> RedisReplyValue {
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
        guard let ctx else { throw RedisError.notConnected }

        let argc = Int32(args.count)
        let cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        var argvlen: [Int] = args.map { $0.utf8.count }

        guard let rawReply = redisCommandArgv(ctx, argc, &argv, &argvlen) else {
            if ctx.pointee.err != 0 {
                let msg = withUnsafePointer(to: &ctx.pointee.errstr.0) { String(cString: $0) }
                throw RedisError.queryFailed(msg)
            }
            throw RedisError.queryFailed("No reply from server")
        }

        let reply = rawReply.assumingMemoryBound(to: redisReply.self)
        defer { freeReplyObject(rawReply) }

        return parseReply(reply)
    }

    private func parseReply(_ reply: UnsafeMutablePointer<redisReply>) -> RedisReplyValue {
        switch reply.pointee.type {
        case REDIS_REPLY_STRING:
            if let str = reply.pointee.str {
                return .string(String(cString: str))
            }
            return .null

        case REDIS_REPLY_INTEGER:
            return .integer(reply.pointee.integer)

        case REDIS_REPLY_ARRAY:
            let count = reply.pointee.elements
            guard count > 0, let elements = reply.pointee.element else {
                return .array([])
            }
            var items: [RedisReplyValue] = []
            for i in 0..<count {
                if let element = elements[i] {
                    items.append(parseReply(element))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)

        case REDIS_REPLY_STATUS:
            if let str = reply.pointee.str {
                return .status(String(cString: str))
            }
            return .status("OK")

        case REDIS_REPLY_ERROR:
            if let str = reply.pointee.str {
                return .error(String(cString: str))
            }
            return .error("Unknown error")

        case REDIS_REPLY_NIL:
            return .null

        default:
            return .null
        }
    }
}

// MARK: - Errors

enum RedisError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Redis connection failed: \(msg)"
        case .notConnected: return "Not connected to Redis"
        case .queryFailed(let msg): return "Redis command failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
