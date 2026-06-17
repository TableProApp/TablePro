//
//  RedisPluginDriver+Operations.swift
//  RedisDriverPlugin
//

import Foundation
import OSLog
import TableProPluginKit

extension RedisPluginDriver {
    func executeOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .get, .set, .del, .keys, .scan, .type, .ttl, .pttl, .expire, .persist, .rename, .exists:
            return try await executeKeyOperation(operation, connection: conn, startTime: startTime)

        case .keyBrowse(let pattern, let typeScope, let limit, let offset):
            return try await executeKeyBrowse(
                pattern: pattern, typeScope: typeScope, limit: limit, offset: offset,
                connection: conn, startTime: startTime
            )

        case .hget, .hset, .hgetall, .hdel:
            return try await executeHashOperation(operation, connection: conn, startTime: startTime)

        case .lrange, .lpush, .rpush, .llen:
            return try await executeListOperation(operation, connection: conn, startTime: startTime)

        case .smembers, .sadd, .srem, .scard:
            return try await executeSetOperation(operation, connection: conn, startTime: startTime)

        case .zrange, .zadd, .zrem, .zcard:
            return try await executeSortedSetOperation(operation, connection: conn, startTime: startTime)

        case .xrange, .xlen:
            return try await executeStreamOperation(operation, connection: conn, startTime: startTime)

        case .ping, .info, .dbsize, .flushdb, .select, .configGet, .configSet, .command, .multi, .exec, .discard:
            return try await executeServerOperation(operation, connection: conn, startTime: startTime)
        }
    }

    // MARK: - Key Operations

    func executeKeyOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .get(let key):
            let result = try await conn.executeCommand(["GET", key])
            let value = result.stringValue
            return PluginQueryResult(
                columns: ["Key", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [[key, value].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .set(let key, let value, let options):
            var args = ["SET", key, value]
            if let opts = options {
                if let ex = opts.ex { args += ["EX", String(ex)] }
                if let px = opts.px { args += ["PX", String(px)] }
                if let exat = opts.exat { args += ["EXAT", String(exat)] }
                if let pxat = opts.pxat { args += ["PXAT", String(pxat)] }
                if opts.nx { args.append("NX") }
                if opts.xx { args.append("XX") }
            }
            _ = try await conn.executeCommand(args)
            return buildStatusResult("OK", startTime: startTime)

        case .del(let keys):
            let args = ["DEL"] + keys
            let result = try await conn.executeCommand(args)
            let deleted = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["deleted"],
                columnTypeNames: ["Int64"],
                rows: [[String(deleted)].asCells],
                rowsAffected: deleted,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .keys(let pattern):
            let result = try await conn.executeCommand(["KEYS", pattern])
            guard let items = result.arrayValue else {
                return buildEmptyKeyResult(startTime: startTime)
            }
            let keys = items.map { redisReplyToString($0) }
            let capped = Array(keys.prefix(PluginRowLimits.emergencyMax))
            let keysTruncated = keys.count > PluginRowLimits.emergencyMax
            return try await buildKeyBrowseResult(
                keys: capped, connection: conn, startTime: startTime, isTruncated: keysTruncated
            )

        case .scan(let cursor, let pattern, let count):
            var args = ["SCAN", String(cursor)]
            if let p = pattern { args += ["MATCH", p] }
            if let c = count { args += ["COUNT", String(c)] }
            let result = try await conn.executeCommand(args)
            return try await handleScanResult(result, connection: conn, startTime: startTime)

        case .type(let key):
            let result = try await conn.executeCommand(["TYPE", key])
            let typeName = result.stringValue ?? "none"
            return PluginQueryResult(
                columns: ["Key", "Type"],
                columnTypeNames: ["String", "String"],
                rows: [[key, typeName].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .ttl(let key):
            let result = try await conn.executeCommand(["TTL", key])
            let ttl = result.intValue ?? -1
            return PluginQueryResult(
                columns: ["Key", "TTL"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(ttl)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .pttl(let key):
            let result = try await conn.executeCommand(["PTTL", key])
            let pttl = result.intValue ?? -1
            return PluginQueryResult(
                columns: ["Key", "PTTL"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(pttl)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .expire(let key, let seconds):
            let result = try await conn.executeCommand(["EXPIRE", key, String(seconds)])
            let success = (result.intValue ?? 0) == 1
            return buildStatusResult(success ? "OK" : "Key not found", startTime: startTime)

        case .persist(let key):
            let result = try await conn.executeCommand(["PERSIST", key])
            let success = (result.intValue ?? 0) == 1
            return buildStatusResult(success ? "OK" : "Key not found or no TTL", startTime: startTime)

        case .rename(let key, let newKey):
            let reply = try await conn.executeCommand(["RENAME", key, newKey])
            if case .error(let msg) = reply {
                throw RedisPluginError(code: 0, message: "RENAME failed: \(msg)")
            }
            return buildStatusResult("OK", startTime: startTime)

        case .exists(let keys):
            let args = ["EXISTS"] + keys
            let result = try await conn.executeCommand(args)
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["exists"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeKeyOperation")
        }
    }

    // MARK: - Hash Operations

    func executeHashOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .hget(let key, let field):
            let result = try await conn.executeCommand(["HGET", key, field])
            let value = result.stringValue
            return PluginQueryResult(
                columns: ["Field", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [[field, value].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .hset(let key, let fieldValues):
            var args = ["HSET", key]
            for (field, value) in fieldValues {
                args += [field, value]
            }
            let result = try await conn.executeCommand(args)
            let added = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["added"],
                columnTypeNames: ["Int64"],
                rows: [[String(added)].asCells],
                rowsAffected: added,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .hgetall(let key):
            let result = try await conn.executeCommand(["HGETALL", key])
            return buildHashResult(result, startTime: startTime)

        case .hdel(let key, let fields):
            let args = ["HDEL", key] + fields
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)].asCells],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeHashOperation")
        }
    }

    // MARK: - List Operations

    func executeListOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .lrange(let key, let start, let stop):
            let result = try await conn.executeCommand(["LRANGE", key, String(start), String(stop)])
            return buildListResult(result, startOffset: start, startTime: startTime)

        case .lpush(let key, let values):
            let args = ["LPUSH", key] + values
            let result = try await conn.executeCommand(args)
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["length"],
                columnTypeNames: ["Int64"],
                rows: [[String(length)].asCells],
                rowsAffected: values.count,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .rpush(let key, let values):
            let args = ["RPUSH", key] + values
            let result = try await conn.executeCommand(args)
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["length"],
                columnTypeNames: ["Int64"],
                rows: [[String(length)].asCells],
                rowsAffected: values.count,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .llen(let key):
            let result = try await conn.executeCommand(["LLEN", key])
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Length"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(length)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeListOperation")
        }
    }

    // MARK: - Set Operations

    func executeSetOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .smembers(let key):
            let result = try await conn.executeCommand(["SMEMBERS", key])
            return buildSetResult(result, startTime: startTime)

        case .sadd(let key, let members):
            let args = ["SADD", key] + members
            let result = try await conn.executeCommand(args)
            let added = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["added"],
                columnTypeNames: ["Int64"],
                rows: [[String(added)].asCells],
                rowsAffected: added,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .srem(let key, let members):
            let args = ["SREM", key] + members
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)].asCells],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .scard(let key):
            let result = try await conn.executeCommand(["SCARD", key])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Cardinality"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(count)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeSetOperation")
        }
    }

    // MARK: - Sorted Set Operations

    func executeSortedSetOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .zrange(let key, let start, let stop, let flags):
            var args = ["ZRANGE", key, start, stop]
            args += flags
            let withScores = flags.contains("WITHSCORES")
            let result = try await conn.executeCommand(args)
            return buildSortedSetResult(result, withScores: withScores, startTime: startTime)

        case .zadd(let key, let flags, let scoreMembers):
            var args = ["ZADD", key]
            args += flags
            for (score, member) in scoreMembers {
                args += [String(score), member]
            }
            let result = try await conn.executeCommand(args)
            if flags.contains("INCR") {
                // INCR mode returns the new score (or nil for NX miss)
                let scoreStr = result.stringValue ?? "nil"
                return PluginQueryResult(
                    columns: ["score"],
                    columnTypeNames: ["String"],
                    rows: [[scoreStr].asCells],
                    rowsAffected: 0,
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }
            let count = result.intValue ?? 0
            let columnName = flags.contains("CH") ? "changed" : "added"
            return PluginQueryResult(
                columns: [columnName],
                columnTypeNames: ["Int64"],
                rows: [[String(count)].asCells],
                rowsAffected: count,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .zrem(let key, let members):
            let args = ["ZREM", key] + members
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)].asCells],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .zcard(let key):
            let result = try await conn.executeCommand(["ZCARD", key])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Cardinality"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(count)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeSortedSetOperation")
        }
    }

    // MARK: - Stream Operations

    func executeStreamOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .xrange(let key, let start, let end, let count):
            var args = ["XRANGE", key, start, end]
            if let c = count { args += ["COUNT", String(c)] }
            let result = try await conn.executeCommand(args)
            return buildStreamResult(result, startTime: startTime)

        case .xlen(let key):
            let result = try await conn.executeCommand(["XLEN", key])
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Length"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(length)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeStreamOperation")
        }
    }

    // MARK: - Server Operations

    func executeServerOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .ping:
            _ = try await conn.executeCommand(["PING"])
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .info(let section):
            var args = ["INFO"]
            if let s = section { args.append(s) }
            let result = try await conn.executeCommand(args)
            let infoText = result.stringValue ?? String(describing: result)
            return PluginQueryResult(
                columns: ["info"],
                columnTypeNames: ["String"],
                rows: [[infoText].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .dbsize:
            let result = try await conn.executeCommand(["DBSIZE"])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["keys"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .flushdb:
            _ = try await conn.executeCommand(["FLUSHDB"])
            return buildStatusResult("OK", startTime: startTime)

        case .select(let database):
            try await conn.selectDatabase(database)
            return buildStatusResult("OK", startTime: startTime)

        case .configGet(let parameter):
            let result = try await conn.executeCommand(["CONFIG", "GET", parameter])
            return buildConfigResult(result, startTime: startTime)

        case .configSet(let parameter, let value):
            _ = try await conn.executeCommand(["CONFIG", "SET", parameter, value])
            return buildStatusResult("OK", startTime: startTime)

        case .command(let args):
            let result = try await conn.executeCommand(args)
            return buildGenericResult(result, startTime: startTime)

        case .multi:
            _ = try await conn.executeCommand(["MULTI"])
            return buildStatusResult("OK", startTime: startTime)

        case .exec:
            let result = try await conn.executeCommand(["EXEC"])
            return buildGenericResult(result, startTime: startTime)

        case .discard:
            _ = try await conn.executeCommand(["DISCARD"])
            return buildStatusResult("OK", startTime: startTime)

        default:
            throw RedisPluginError(code: 0, message: "Unexpected operation in executeServerOperation")
        }
    }
}
