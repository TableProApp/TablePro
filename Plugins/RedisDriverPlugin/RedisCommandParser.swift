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
    case zrange(key: String, start: Int, stop: Int, withScores: Bool)
    case zadd(key: String, scoreMembers: [(Double, String)])
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
             "EXPIRE", "PERSIST", "RENAME", "EXISTS":
            return try parseKeyCommand(command, args: args)

        case "HGET", "HSET", "HGETALL", "HDEL":
            return try parseHashCommand(command, args: args)

        case "LRANGE", "LPUSH", "RPUSH", "LLEN":
            return try parseListCommand(command, args: args)

        case "SMEMBERS", "SADD", "SREM", "SCARD":
            return try parseSetCommand(command, args: args)

        case "ZRANGE", "ZADD", "ZREM", "ZCARD":
            return try parseSortedSetCommand(command, args: args)

        case "XRANGE", "XLEN":
            return try parseStreamCommand(command, args: args)

        case "PING", "INFO", "DBSIZE", "FLUSHDB", "SELECT", "CONFIG",
             "MULTI", "EXEC", "DISCARD":
            return try parseServerCommand(command, args: args, tokens: tokens)

        default:
            return .command(args: tokens)
        }
    }

    // MARK: - Key Commands

    private static func parseKeyCommand(_ command: String, args: [String]) throws -> RedisOperation {
        switch command {
        case "GET":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("GET requires a key") }
            return .get(key: args[0])

        case "SET":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("SET requires key and value") }
            let options = parseSetOptions(Array(args.dropFirst(2)))
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
            let (pattern, count) = parseScanOptions(Array(args.dropFirst()))
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
            return .expire(key: args[0], seconds: seconds)

        case "PERSIST":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("PERSIST requires a key") }
            return .persist(key: args[0])

        case "RENAME":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("RENAME requires key and newKey") }
            return .rename(key: args[0], newKey: args[1])

        case "EXISTS":
            guard !args.isEmpty else { throw RedisParseError.missingArgument("EXISTS requires at least one key") }
            return .exists(keys: args)

        default:
            throw RedisParseError.invalidArgument("Unknown key command: \(command)")
        }
    }

    // MARK: - Hash Commands

    private static func parseHashCommand(_ command: String, args: [String]) throws -> RedisOperation {
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
            guard args.count >= 2 else { throw RedisParseError.missingArgument("HDEL requires key and at least one field") }
            return .hdel(key: args[0], fields: Array(args.dropFirst()))

        default:
            throw RedisParseError.invalidArgument("Unknown hash command: \(command)")
        }
    }

    // MARK: - List Commands

    private static func parseListCommand(_ command: String, args: [String]) throws -> RedisOperation {
        switch command {
        case "LRANGE":
            guard args.count >= 3 else { throw RedisParseError.missingArgument("LRANGE requires key, start, and stop") }
            guard let start = Int(args[1]), let stop = Int(args[2]) else {
                throw RedisParseError.invalidArgument("LRANGE start and stop must be integers")
            }
            return .lrange(key: args[0], start: start, stop: stop)

        case "LPUSH":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("LPUSH requires key and at least one value") }
            return .lpush(key: args[0], values: Array(args.dropFirst()))

        case "RPUSH":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("RPUSH requires key and at least one value") }
            return .rpush(key: args[0], values: Array(args.dropFirst()))

        case "LLEN":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("LLEN requires a key") }
            return .llen(key: args[0])

        default:
            throw RedisParseError.invalidArgument("Unknown list command: \(command)")
        }
    }

    // MARK: - Set Commands

    private static func parseSetCommand(_ command: String, args: [String]) throws -> RedisOperation {
        switch command {
        case "SMEMBERS":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SMEMBERS requires a key") }
            return .smembers(key: args[0])

        case "SADD":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("SADD requires key and at least one member") }
            return .sadd(key: args[0], members: Array(args.dropFirst()))

        case "SREM":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("SREM requires key and at least one member") }
            return .srem(key: args[0], members: Array(args.dropFirst()))

        case "SCARD":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("SCARD requires a key") }
            return .scard(key: args[0])

        default:
            throw RedisParseError.invalidArgument("Unknown set command: \(command)")
        }
    }

    // MARK: - Sorted Set Commands

    private static func parseSortedSetCommand(_ command: String, args: [String]) throws -> RedisOperation {
        switch command {
        case "ZRANGE":
            guard args.count >= 3 else { throw RedisParseError.missingArgument("ZRANGE requires key, start, and stop") }
            guard let start = Int(args[1]), let stop = Int(args[2]) else {
                throw RedisParseError.invalidArgument("ZRANGE start and stop must be integers")
            }
            let withScores = args.count > 3 && args[3].uppercased() == "WITHSCORES"
            return .zrange(key: args[0], start: start, stop: stop, withScores: withScores)

        case "ZADD":
            guard args.count >= 3, (args.count - 1) % 2 == 0 else {
                throw RedisParseError.missingArgument("ZADD requires key followed by score member pairs")
            }
            var scoreMembers: [(Double, String)] = []
            var i = 1
            while i + 1 < args.count {
                guard let score = Double(args[i]) else {
                    throw RedisParseError.invalidArgument("ZADD score must be a number: \(args[i])")
                }
                scoreMembers.append((score, args[i + 1]))
                i += 2
            }
            return .zadd(key: args[0], scoreMembers: scoreMembers)

        case "ZREM":
            guard args.count >= 2 else { throw RedisParseError.missingArgument("ZREM requires key and at least one member") }
            return .zrem(key: args[0], members: Array(args.dropFirst()))

        case "ZCARD":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("ZCARD requires a key") }
            return .zcard(key: args[0])

        default:
            throw RedisParseError.invalidArgument("Unknown sorted set command: \(command)")
        }
    }

    // MARK: - Stream Commands

    private static func parseStreamCommand(_ command: String, args: [String]) throws -> RedisOperation {
        switch command {
        case "XRANGE":
            guard args.count >= 3 else { throw RedisParseError.missingArgument("XRANGE requires key, start, and end") }
            var count: Int?
            if args.count >= 5, args[3].uppercased() == "COUNT" {
                count = Int(args[4])
            }
            return .xrange(key: args[0], start: args[1], end: args[2], count: count)

        case "XLEN":
            guard args.count >= 1 else { throw RedisParseError.missingArgument("XLEN requires a key") }
            return .xlen(key: args[0])

        default:
            throw RedisParseError.invalidArgument("Unknown stream command: \(command)")
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

        default:
            throw RedisParseError.invalidArgument("Unknown server command: \(command)")
        }
    }

    // MARK: - Tokenizer

    /// Split input by whitespace, respecting quoted strings (single and double quotes)
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var escapeNext = false

        for char in input {
            if escapeNext {
                current.append(char)
                escapeNext = false
                continue
            }

            if char == "\\" {
                escapeNext = true
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
                quoteChar = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    // MARK: - Option Parsers

    /// Parse SET command options: EX, PX, NX, XX
    private static func parseSetOptions(_ args: [String]) -> RedisSetOptions? {
        guard !args.isEmpty else { return nil }

        var options = RedisSetOptions()
        var hasOption = false
        var i = 0

        while i < args.count {
            let arg = args[i].uppercased()
            switch arg {
            case "EX":
                if i + 1 < args.count, let seconds = Int(args[i + 1]) {
                    options.ex = seconds
                    hasOption = true
                    i += 1
                }
            case "PX":
                if i + 1 < args.count, let millis = Int(args[i + 1]) {
                    options.px = millis
                    hasOption = true
                    i += 1
                }
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
    private static func parseScanOptions(_ args: [String]) -> (pattern: String?, count: Int?) {
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
                if i + 1 < args.count {
                    count = Int(args[i + 1])
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        return (pattern, count)
    }
}
