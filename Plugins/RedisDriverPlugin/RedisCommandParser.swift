//
//  RedisCommandParser.swift
//  TablePro
//
//  Parses Redis CLI-style commands into structured operations.
//  Supports: GET, SET, DEL, KEYS, SCAN, hash/list/set/sorted-set/stream commands, and server commands.
//

import Foundation
import os
import TableProPluginKit

/// A parsed Redis command ready for execution
enum RedisOperation {
    case get(key: String)
    case set(key: String, value: String, options: RedisSetOptions?)
    case del(keys: [String])
    case keys(pattern: String)
    case scan(cursor: Int, pattern: String?, count: Int?)
    case type(key: String)
    case ttl(key: String)
    case pttl(key: String)
    case expire(key: String, seconds: Int)
    case persist(key: String)
    case rename(key: String, newKey: String)
    case exists(keys: [String])

    // Hash
    case hget(key: String, field: String)
    case hset(key: String, fieldValues: [(String, String)])
    case hgetall(key: String)
    case hdel(key: String, fields: [String])

    // List
    case lrange(key: String, start: Int, stop: Int)
    case lpush(key: String, values: [String])
    case rpush(key: String, values: [String])
    case llen(key: String)

    // Set
    case smembers(key: String)
    case sadd(key: String, members: [String])
    case srem(key: String, members: [String])
    case scard(key: String)

    // Sorted set
    case zrange(key: String, start: String, stop: String, flags: [String])
    case zadd(key: String, flags: [String], scoreMembers: [(Double, String)])
    case zrem(key: String, members: [String])
    case zcard(key: String)

    // Stream
    case xrange(key: String, start: String, end: String, count: Int?)
    case xlen(key: String)

    // Server
    case ping
    case info(section: String?)
    case dbsize
    case flushdb
    case select(database: Int)
    case configGet(parameter: String)
    case configSet(parameter: String, value: String)
    case command(args: [String])

    // Multi
    case multi
    case exec
    case discard
}

/// Options for SET command
struct RedisSetOptions {
    var ex: Int?
    var px: Int?
    var exat: Int?
    var pxat: Int?
    var nx: Bool = false
    var xx: Bool = false
}

/// Error from parsing Redis CLI syntax
enum RedisParseError: Error {
    case emptySyntax
    case invalidArgument(String)
    case missingArgument(String)
}

extension RedisParseError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .emptySyntax: return String(localized: "Empty Redis command")
        case .invalidArgument(let msg): return String(localized: "Invalid argument: \(msg)")
        case .missingArgument(let msg): return String(localized: "Missing argument: \(msg)")
        }
    }
}

struct RedisCommandParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RedisCommandParser")

    // MARK: - Public API

    /// Parse a Redis CLI command string into a RedisOperation
    static func parse(_ input: String) throws -> RedisOperation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RedisParseError.emptySyntax }

        let tokens = tokenize(trimmed)
        guard let first = tokens.first else { throw RedisParseError.emptySyntax }

        let command = first.uppercased()
        let args = Array(tokens.dropFirst())

        switch command {
        case "GET", "SET", "DEL", "KEYS", "SCAN", "TYPE", "TTL", "PTTL",
             "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT",
             "PERSIST", "RENAME", "EXISTS",
             "GETSET", "GETDEL", "GETEX",
             "MGET", "MSET",
             "INCR", "DECR", "INCRBY", "DECRBY", "INCRBYFLOAT",
             "APPEND":
            return try parseKeyCommand(command, args: args, tokens: tokens)

        case "HGET", "HSET", "HGETALL", "HDEL", "HSCAN":
            return try parseHashCommand(command, args: args, tokens: tokens)

        case "LRANGE", "LPUSH", "RPUSH", "LLEN",
             "LPOP", "RPOP", "LSET", "LINSERT", "LREM", "LPOS", "LMOVE":
            return try parseListCommand(command, args: args, tokens: tokens)

        case "SMEMBERS", "SADD", "SREM", "SCARD",
             "SPOP", "SRANDMEMBER", "SMOVE",
             "SUNION", "SINTER", "SDIFF",
             "SUNIONSTORE", "SINTERSTORE", "SDIFFSTORE",
             "SSCAN":
            return try parseSetCommand(command, args: args, tokens: tokens)

        case "ZRANGE", "ZADD", "ZREM", "ZCARD",
             "ZSCORE", "ZRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYSCORE",
             "ZINCRBY", "ZCOUNT", "ZRANK", "ZREVRANK",
             "ZPOPMIN", "ZPOPMAX",
             "ZSCAN":
            return try parseSortedSetCommand(command, args: args, tokens: tokens)

        case "XRANGE", "XLEN", "XADD", "XREAD", "XREVRANGE", "XDEL",
             "XTRIM", "XINFO", "XGROUP", "XACK":
            return try parseStreamCommand(command, args: args, tokens: tokens)

        case "PING", "INFO", "DBSIZE", "FLUSHDB", "FLUSHALL", "SELECT", "CONFIG",
             "MULTI", "EXEC", "DISCARD", "AUTH", "OBJECT":
            return try parseServerCommand(command, args: args, tokens: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Key Commands

    private static func parseKeyCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "GET":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("GET requires a key") }
            return .get(key: args[0])

        case "SET":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("SET requires key and value") }
            let options = try parseSetOptions(Array(args.dropFirst(2)))
            return .set(key: args[0], value: args[1], options: options)

        case "DEL":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("DEL requires at least one key") }
            return .del(keys: args)

        case "KEYS":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("KEYS requires a pattern") }
            return .keys(pattern: args[0])

        case "SCAN":
            guard args.count >= 1, let cursor = Int(args[0]) else {
                throw RedisParseError.missingArgument("SCAN requires a cursor (integer)")
            }
            let (pattern, count) = try parseScanOptions(Array(args.dropFirst()))
            return .scan(cursor: cursor, pattern: pattern, count: count)

        case "TYPE":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("TYPE requires a key") }
            return .type(key: args[0])

        case "TTL":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("TTL requires a key") }
            return .ttl(key: args[0])

        case "PTTL":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("PTTL requires a key") }
            return .pttl(key: args[0])

        case "EXPIRE":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("EXPIRE requires key and seconds") }
            guard let seconds = Int(args[1]) else {
                throw RedisParseError.invalidArgument("EXPIRE seconds must be an integer")
            }
            // Redis 7.0+ supports optional NX|XX|GT|LT flags; pass through as raw command
            if args.count > 2 {
                return .command(args: tokens)
            }
            return .expire(key: args[0], seconds: seconds)

        case "PEXPIRE":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("PEXPIRE requires key and milliseconds")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("PEXPIRE milliseconds must be an integer")
            }
            return .command(args: tokens)

        case "EXPIREAT":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("EXPIREAT requires key and timestamp")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("EXPIREAT timestamp must be an integer")
            }
            return .command(args: tokens)

        case "PEXPIREAT":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("PEXPIREAT requires key and milliseconds-timestamp")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("PEXPIREAT milliseconds-timestamp must be an integer")
            }
            return .command(args: tokens)

        case "PERSIST":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("PERSIST requires a key") }
            return .persist(key: args[0])

        case "RENAME":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("RENAME requires key and newKey") }
            return .rename(key: args[0], newKey: args[1])

        case "EXISTS":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("EXISTS requires at least one key") }
            return .exists(keys: args)

        case "GETSET":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("GETSET requires key and value") }
            return .command(args: tokens)

        case "GETDEL":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("GETDEL requires a key") }
            return .command(args: tokens)

        case "GETEX":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("GETEX requires a key") }
            return .command(args: tokens)

        case "MGET":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("MGET requires at least one key") }
            return .command(args: tokens)

        case "MSET":
            guard args.count >= 2, args.count % 2 == 0 else {
                throw RedisParseError.missingArgument("MSET requires key value pairs")
            }
            return .command(args: tokens)

        case "INCR":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("INCR requires a key") }
            return .command(args: tokens)

        case "DECR":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("DECR requires a key") }
            return .command(args: tokens)

        case "INCRBY":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("INCRBY requires key and increment") }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("INCRBY increment must be an integer")
            }
            return .command(args: tokens)

        case "DECRBY":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("DECRBY requires key and decrement") }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("DECRBY decrement must be an integer")
            }
            return .command(args: tokens)

        case "INCRBYFLOAT":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("INCRBYFLOAT requires key and increment")
            }
            guard Double(args[1]) != nil else {
                throw RedisParseError.invalidArgument("INCRBYFLOAT increment must be a number")
            }
            return .command(args: tokens)

        case "APPEND":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("APPEND requires key and value") }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Hash Commands

    private static func parseHashCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "HGET":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("HGET requires key and field") }
            return .hget(key: args[0], field: args[1])

        case "HSET":
            guard args.count >= 3, args.count % 2 == 1 else {
                throw RedisParseError.missingArgument("HSET requires key followed by field value pairs")
            }
            var fieldValues: [(String, String)] = []
            var i = 1
            while i + 1 < args.count {
                fieldValues.append((args[i], args[i + 1]))
                i += 2
            }
            return .hset(key: args[0], fieldValues: fieldValues)

        case "HGETALL":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("HGETALL requires a key") }
            return .hgetall(key: args[0])

        case "HDEL":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("HDEL requires key and at least one field")
            }
            return .hdel(key: args[0], fields: Array(args.dropFirst()))

        case "HSCAN":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("HSCAN requires key and cursor")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("HSCAN cursor must be an integer")
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - List Commands

    private static func parseListCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "LRANGE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("LRANGE requires key, start, and stop")
            }
            guard let start = Int(args[1]), let stop = Int(args[2]) else {
                throw RedisParseError.invalidArgument("LRANGE start and stop must be integers")
            }
            return .lrange(key: args[0], start: start, stop: stop)

        case "LPUSH":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("LPUSH requires key and at least one value")
            }
            return .lpush(key: args[0], values: Array(args.dropFirst()))

        case "RPUSH":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("RPUSH requires key and at least one value")
            }
            return .rpush(key: args[0], values: Array(args.dropFirst()))

        case "LLEN":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("LLEN requires a key") }
            return .llen(key: args[0])

        case "LPOP":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("LPOP requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("LPOP count must be an integer")
                }
            }
            return .command(args: tokens)

        case "RPOP":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("RPOP requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("RPOP count must be an integer")
                }
            }
            return .command(args: tokens)

        case "LSET":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("LSET requires key, index, and element")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("LSET index must be an integer")
            }
            return .command(args: tokens)

        case "LINSERT":
            guard args.count >= 4 else {
                throw RedisParseError.missingArgument("LINSERT requires key, BEFORE|AFTER, pivot, and element")
            }
            let position = args[1].uppercased()
            guard position == "BEFORE" || position == "AFTER" else {
                throw RedisParseError.invalidArgument("LINSERT position must be BEFORE or AFTER")
            }
            return .command(args: tokens)

        case "LREM":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("LREM requires key, count, and element")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("LREM count must be an integer")
            }
            return .command(args: tokens)

        case "LPOS":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("LPOS requires key and element")
            }
            return .command(args: tokens)

        case "LMOVE":
            guard args.count >= 4 else {
                throw RedisParseError.missingArgument("LMOVE requires source, destination, LEFT|RIGHT, LEFT|RIGHT")
            }
            let dir1 = args[2].uppercased()
            let dir2 = args[3].uppercased()
            guard (dir1 == "LEFT" || dir1 == "RIGHT") && (dir2 == "LEFT" || dir2 == "RIGHT") else {
                throw RedisParseError.invalidArgument("LMOVE directions must be LEFT or RIGHT")
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Set Commands

    private static func parseSetCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "SMEMBERS":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SMEMBERS requires a key") }
            return .smembers(key: args[0])

        case "SADD":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SADD requires key and at least one member")
            }
            return .sadd(key: args[0], members: Array(args.dropFirst()))

        case "SREM":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SREM requires key and at least one member")
            }
            return .srem(key: args[0], members: Array(args.dropFirst()))

        case "SCARD":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SCARD requires a key") }
            return .scard(key: args[0])

        case "SPOP":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SPOP requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("SPOP count must be an integer")
                }
            }
            return .command(args: tokens)

        case "SRANDMEMBER":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SRANDMEMBER requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("SRANDMEMBER count must be an integer")
                }
            }
            return .command(args: tokens)

        case "SMOVE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("SMOVE requires source, destination, and member")
            }
            return .command(args: tokens)

        case "SUNION":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("SUNION requires at least one key") }
            return .command(args: tokens)

        case "SINTER":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("SINTER requires at least one key") }
            return .command(args: tokens)

        case "SDIFF":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("SDIFF requires at least one key") }
            return .command(args: tokens)

        case "SUNIONSTORE":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SUNIONSTORE requires destination and at least one key")
            }
            return .command(args: tokens)

        case "SINTERSTORE":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SINTERSTORE requires destination and at least one key")
            }
            return .command(args: tokens)

        case "SDIFFSTORE":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SDIFFSTORE requires destination and at least one key")
            }
            return .command(args: tokens)

        case "SSCAN":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("SSCAN requires key and cursor")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("SSCAN cursor must be an integer")
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Sorted Set Commands

    private static func parseSortedSetCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "ZRANGE":
            guard args.count >= 3 else { throw RedisParseError.missingArgument("ZRANGE requires key, start, and stop") }
            let start = args[1]
            let stop = args[2]
            // Parse optional trailing flags: BYSCORE, BYLEX, REV, WITHSCORES, LIMIT offset count
            let knownFlags: Set<String> = ["BYSCORE", "BYLEX", "REV", "WITHSCORES", "LIMIT"]
            var flags: [String] = []
            var i = 3
            while i < args.count {
                let upper = args[i].uppercased()
                if knownFlags.contains(upper) {
                    flags.append(upper)
                    if upper == "LIMIT" {
                        // LIMIT requires offset and count
                        guard i + 2 < args.count else {
                            throw RedisParseError.missingArgument("LIMIT requires offset and count")
                        }
                        flags.append(args[i + 1])
                        flags.append(args[i + 2])
                        i += 2
                    }
                }
                i += 1
            }
            return .zrange(key: args[0], start: start, stop: stop, flags: flags)

        case "ZADD":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZADD requires key followed by score member pairs")
            }
            // Skip known flags after key: NX, XX, GT, LT, CH, INCR (case-insensitive)
            let zaddFlags: Set<String> = ["NX", "XX", "GT", "LT", "CH", "INCR"]
            var collectedFlags: [String] = []
            var i = 1
            while i < args.count, zaddFlags.contains(args[i].uppercased()) {
                collectedFlags.append(args[i].uppercased())
                i += 1
            }
            let remaining = Array(args[i...])
            guard !remaining.isEmpty, remaining.count % 2 == 0 else {
                throw RedisParseError.missingArgument("ZADD requires score member pairs after flags")
            }
            var scoreMembers: [(Double, String)] = []
            var j = 0
            while j + 1 < remaining.count {
                guard let score = Double(remaining[j]) else {
                    throw RedisParseError.invalidArgument("ZADD score must be a number: \(remaining[j])")
                }
                scoreMembers.append((score, remaining[j + 1]))
                j += 2
            }
            return .zadd(key: args[0], flags: collectedFlags, scoreMembers: scoreMembers)

        case "ZREM":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZREM requires key and at least one member")
            }
            return .zrem(key: args[0], members: Array(args.dropFirst()))

        case "ZCARD":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("ZCARD requires a key") }
            return .zcard(key: args[0])

        case "ZSCORE":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZSCORE requires key and member")
            }
            return .command(args: tokens)

        case "ZRANGEBYSCORE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("ZRANGEBYSCORE requires key, min, and max")
            }
            return .command(args: tokens)

        case "ZREVRANGE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("ZREVRANGE requires key, start, and stop")
            }
            guard Int(args[1]) != nil, Int(args[2]) != nil else {
                throw RedisParseError.invalidArgument("ZREVRANGE start and stop must be integers")
            }
            return .command(args: tokens)

        case "ZREVRANGEBYSCORE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("ZREVRANGEBYSCORE requires key, max, and min")
            }
            return .command(args: tokens)

        case "ZINCRBY":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("ZINCRBY requires key, increment, and member")
            }
            guard Double(args[1]) != nil else {
                throw RedisParseError.invalidArgument("ZINCRBY increment must be a number")
            }
            return .command(args: tokens)

        case "ZCOUNT":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("ZCOUNT requires key, min, and max")
            }
            return .command(args: tokens)

        case "ZRANK":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZRANK requires key and member")
            }
            return .command(args: tokens)

        case "ZREVRANK":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZREVRANK requires key and member")
            }
            return .command(args: tokens)

        case "ZPOPMIN":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("ZPOPMIN requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("ZPOPMIN count must be an integer")
                }
            }
            return .command(args: tokens)

        case "ZPOPMAX":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("ZPOPMAX requires a key") }
            if args.count >= 2 {
                guard Int(args[1]) != nil else {
                    throw RedisParseError.invalidArgument("ZPOPMAX count must be an integer")
                }
            }
            return .command(args: tokens)

        case "ZSCAN":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("ZSCAN requires key and cursor")
            }
            guard Int(args[1]) != nil else {
                throw RedisParseError.invalidArgument("ZSCAN cursor must be an integer")
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Stream Commands

    private static func parseStreamCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "XRANGE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("XRANGE requires key, start, and end")
            }
            var count: Int?
            if args.count >= 5, args[3].uppercased() == "COUNT" {
                count = Int(args[4])
            }
            return .xrange(key: args[0], start: args[1], end: args[2], count: count)

        case "XLEN":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("XLEN requires a key") }
            return .xlen(key: args[0])

        case "XADD":
            // XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold] *|ID field value [field value ...]
            guard args.count >= 4 else {
                throw RedisParseError.missingArgument("XADD requires key, ID, and at least one field-value pair")
            }
            return .command(args: tokens)

        case "XREAD":
            // XREAD [COUNT count] [BLOCK ms] STREAMS key [key ...] ID [ID ...]
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("XREAD requires STREAMS keyword, at least one key, and an ID")
            }
            let hasStreams = args.contains { $0.uppercased() == "STREAMS" }
            guard hasStreams else {
                throw RedisParseError.missingArgument("XREAD requires the STREAMS keyword")
            }
            return .command(args: tokens)

        case "XREVRANGE":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("XREVRANGE requires key, end, and start")
            }
            return .command(args: tokens)

        case "XDEL":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("XDEL requires key and at least one ID")
            }
            return .command(args: tokens)

        case "XTRIM":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("XTRIM requires key, MAXLEN|MINID, and threshold")
            }
            return .command(args: tokens)

        case "XINFO":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("XINFO requires a subcommand and key")
            }
            let sub = args[0].uppercased()
            guard sub == "STREAM" || sub == "GROUPS" || sub == "CONSUMERS" || sub == "HELP" else {
                throw RedisParseError.invalidArgument(
                    "XINFO subcommand must be STREAM, GROUPS, CONSUMERS, or HELP"
                )
            }
            return .command(args: tokens)

        case "XGROUP":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("XGROUP requires a subcommand and key")
            }
            let sub = args[0].uppercased()
            guard sub == "CREATE" || sub == "SETID" || sub == "DELCONSUMER" || sub == "DESTROY" else {
                throw RedisParseError.invalidArgument(
                    "XGROUP subcommand must be CREATE, SETID, DELCONSUMER, or DESTROY"
                )
            }
            return .command(args: tokens)

        case "XACK":
            guard args.count >= 3 else {
                throw RedisParseError.missingArgument("XACK requires key, group, and at least one ID")
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Server Commands

    private static func parseServerCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> RedisOperation {
        switch command {
        case "PING":
            return .ping

        case "INFO":
            return .info(section: args.first)

        case "DBSIZE":
            return .dbsize

        case "FLUSHDB":
            return .flushdb

        case "FLUSHALL":
            // Optional ASYNC|SYNC flag
            if let flag = args.first?.uppercased() {
                guard flag == "ASYNC" || flag == "SYNC" else {
                    throw RedisParseError.invalidArgument("FLUSHALL flag must be ASYNC or SYNC")
                }
            }
            return .command(args: tokens)

        case "SELECT":
            guard args.count >= 1, let db = Int(args[0]) else {
                throw RedisParseError.missingArgument("SELECT requires a database index (integer)")
            }
            return .select(database: db)

        case "CONFIG":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("CONFIG requires a subcommand and parameter")
            }
            let subcommand = args[0].uppercased()
            switch subcommand {
            case "GET":
                return .configGet(parameter: args[1])
            case "SET":
                guard args.count >= 3 else {
                    throw RedisParseError.missingArgument("CONFIG SET requires parameter and value")
                }
                return .configSet(parameter: args[1], value: args[2])
            default:
                return .command(args: tokens)
            }

        case "MULTI":
            return .multi

        case "EXEC":
            return .exec

        case "DISCARD":
            return .discard

        case "AUTH":
            guard !args.isEmpty else {
                throw RedisParseError.missingArgument("AUTH requires a password (and optionally a username)")
            }
            return .command(args: tokens)

        case "OBJECT":
            guard args.count >= 2 else {
                throw RedisParseError.missingArgument("OBJECT requires a subcommand and key")
            }
            let sub = args[0].uppercased()
            guard sub == "ENCODING" || sub == "REFCOUNT" || sub == "IDLETIME"
                || sub == "HELP" || sub == "FREQ" else {
                throw RedisParseError.invalidArgument(
                    "OBJECT subcommand must be ENCODING, REFCOUNT, IDLETIME, FREQ, or HELP"
                )
            }
            return .command(args: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Tokenizer

    /// Split input by whitespace, respecting quoted strings (single and double quotes).
    /// Escape sequences (\n, \t, \r, \\, \", \') are only decoded inside quoted strings.
    /// Outside quotes, backslash is treated as a literal character (matching Redis CLI behavior).
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var escapeNext = false
        var escapedInsideQuote = false
        var hadQuote = false

        for char in input {
            if escapeNext {
                escapeNext = false
                if escapedInsideQuote {
                    // Decode known escape sequences inside quoted strings
                    switch char {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    case "r": current.append("\r")
                    case "\\": current.append("\\")
                    case "\"": current.append("\"")
                    case "'": current.append("'")
                    default:
                        // Unknown escape: preserve both characters
                        current.append("\\")
                        current.append(char)
                    }
                } else {
                    // Outside quotes: backslash is literal
                    current.append("\\")
                    current.append(char)
                }
                continue
            }

            if char == "\\" {
                escapeNext = true
                escapedInsideQuote = inQuote
                continue
            }

            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                inQuote = true
                hadQuote = true
                quoteChar = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty || hadQuote {
                    tokens.append(current)
                    current = ""
                    hadQuote = false
                }
                continue
            }

            current.append(char)
        }

        // Handle trailing backslash
        if escapeNext {
            current.append("\\")
        }

        if !current.isEmpty || hadQuote {
            tokens.append(current)
        }

        return tokens
    }

    // MARK: - Option Parsers

    /// Parse SET command options: EX, PX, EXAT, PXAT, NX, XX
    private static func parseSetOptions(_ args: [String]) throws -> RedisSetOptions? {
        guard !args.isEmpty else { return nil }

        var options = RedisSetOptions()
        var hasOption = false
        var i = 0

        while i < args.count {
            let arg = args[i].uppercased()
            switch arg {
            case "EX":
                guard i + 1 < args.count else {
                    throw RedisParseError.missingArgument("EX requires a value")
                }
                guard let seconds = Int(args[i + 1]), seconds > 0 else {
                    throw RedisParseError.invalidArgument("EX value must be a positive integer")
                }
                options.ex = seconds
                hasOption = true
                i += 1
            case "PX":
                guard i + 1 < args.count else {
                    throw RedisParseError.missingArgument("PX requires a value")
                }
                guard let millis = Int(args[i + 1]), millis > 0 else {
                    throw RedisParseError.invalidArgument("PX value must be a positive integer")
                }
                options.px = millis
                hasOption = true
                i += 1
            case "EXAT":
                guard i + 1 < args.count else {
                    throw RedisParseError.missingArgument("EXAT requires a value")
                }
                guard let timestamp = Int(args[i + 1]) else {
                    throw RedisParseError.invalidArgument("EXAT value must be a positive integer")
                }
                options.exat = timestamp
                hasOption = true
                i += 1
            case "PXAT":
                guard i + 1 < args.count else {
                    throw RedisParseError.missingArgument("PXAT requires a value")
                }
                guard let timestamp = Int(args[i + 1]) else {
                    throw RedisParseError.invalidArgument("PXAT value must be a positive integer")
                }
                options.pxat = timestamp
                hasOption = true
                i += 1
            case "NX":
                options.nx = true
                hasOption = true
            case "XX":
                options.xx = true
                hasOption = true
            default:
                break
            }
            i += 1
        }

        return hasOption ? options : nil
    }

    /// Parse SCAN options: MATCH pattern, COUNT count
    private static func parseScanOptions(_ args: [String]) throws -> (pattern: String?, count: Int?) {
        var pattern: String?
        var count: Int?
        var i = 0

        while i < args.count {
            let arg = args[i].uppercased()
            switch arg {
            case "MATCH":
                if i + 1 < args.count {
                    pattern = args[i + 1]
                    i += 1
                }
            case "COUNT":
                guard i + 1 < args.count else {
                    throw RedisParseError.missingArgument("COUNT requires a value")
                }
                guard let countVal = Int(args[i + 1]) else {
                    throw RedisParseError.invalidArgument("COUNT must be a positive integer")
                }
                count = countVal
                i += 1
            default:
                break
            }
            i += 1
        }

        return (pattern, count)
    }
}
