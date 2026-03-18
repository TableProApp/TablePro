//
//  RedisCommandParserTests.swift
//  TableProTests
//
//  Tests for RedisCommandParser, which parses Redis CLI-style commands
//  into structured RedisOperation values.
//
//  The parser lives inside RedisDriverPlugin (a bundle target), so we copy
//  the pure-value types here as private helpers instead of using @testable import.
//

import Foundation
import Testing

// MARK: - Key Commands

@Suite("RedisCommandParser - Key Commands")
struct RedisCommandParserKeyCommandTests {
    @Test("GET parses key")
    func getCommand() throws {
        let op = try TestRedisCommandParser.parse("GET mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get, got \(op)")
            return
        }
        #expect(key == "mykey")
    }

    @Test("GET missing key throws")
    func getMissingKey() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("GET")
        }
    }

    @Test("SET parses key and value")
    func setCommand() throws {
        let op = try TestRedisCommandParser.parse("SET mykey myvalue")
        guard case .set(let key, let value, let options) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(value == "myvalue")
        #expect(options == nil)
    }

    @Test("SET with EX option")
    func setWithExpiry() throws {
        let op = try TestRedisCommandParser.parse("SET mykey myvalue EX 60")
        guard case .set(_, _, let options) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(options?.ex == 60)
    }

    @Test("SET with NX option")
    func setWithNx() throws {
        let op = try TestRedisCommandParser.parse("SET mykey myvalue NX")
        guard case .set(_, _, let options) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(options?.nx == true)
    }

    @Test("SET missing value throws")
    func setMissingValue() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("SET mykey")
        }
    }

    @Test("DEL parses single key")
    func delSingleKey() throws {
        let op = try TestRedisCommandParser.parse("DEL mykey")
        guard case .del(let keys) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(keys == ["mykey"])
    }

    @Test("DEL parses multiple keys")
    func delMultipleKeys() throws {
        let op = try TestRedisCommandParser.parse("DEL key1 key2 key3")
        guard case .del(let keys) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(keys == ["key1", "key2", "key3"])
    }

    @Test("DEL missing key throws")
    func delMissingKey() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("DEL")
        }
    }

    @Test("KEYS parses pattern")
    func keysCommand() throws {
        let op = try TestRedisCommandParser.parse("KEYS user:*")
        guard case .keys(let pattern) = op else {
            Issue.record("Expected .keys")
            return
        }
        #expect(pattern == "user:*")
    }

    @Test("SCAN parses cursor with MATCH and COUNT")
    func scanWithOptions() throws {
        let op = try TestRedisCommandParser.parse("SCAN 0 MATCH user:* COUNT 100")
        guard case .scan(let cursor, let pattern, let count) = op else {
            Issue.record("Expected .scan")
            return
        }
        #expect(cursor == 0)
        #expect(pattern == "user:*")
        #expect(count == 100)
    }

    @Test("SCAN without options")
    func scanBasic() throws {
        let op = try TestRedisCommandParser.parse("SCAN 0")
        guard case .scan(let cursor, let pattern, let count) = op else {
            Issue.record("Expected .scan")
            return
        }
        #expect(cursor == 0)
        #expect(pattern == nil)
        #expect(count == nil)
    }

    @Test("TYPE parses key")
    func typeCommand() throws {
        let op = try TestRedisCommandParser.parse("TYPE mykey")
        guard case .type(let key) = op else {
            Issue.record("Expected .type")
            return
        }
        #expect(key == "mykey")
    }

    @Test("TTL parses key")
    func ttlCommand() throws {
        let op = try TestRedisCommandParser.parse("TTL mykey")
        guard case .ttl(let key) = op else {
            Issue.record("Expected .ttl")
            return
        }
        #expect(key == "mykey")
    }

    @Test("EXPIRE parses key and seconds")
    func expireCommand() throws {
        let op = try TestRedisCommandParser.parse("EXPIRE mykey 300")
        guard case .expire(let key, let seconds) = op else {
            Issue.record("Expected .expire")
            return
        }
        #expect(key == "mykey")
        #expect(seconds == 300)
    }

    @Test("EXPIRE with non-integer seconds throws")
    func expireInvalidSeconds() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("EXPIRE mykey abc")
        }
    }

    @Test("RENAME parses key and newKey")
    func renameCommand() throws {
        let op = try TestRedisCommandParser.parse("RENAME oldkey newkey")
        guard case .rename(let key, let newKey) = op else {
            Issue.record("Expected .rename")
            return
        }
        #expect(key == "oldkey")
        #expect(newKey == "newkey")
    }

    @Test("EXISTS parses multiple keys")
    func existsCommand() throws {
        let op = try TestRedisCommandParser.parse("EXISTS k1 k2")
        guard case .exists(let keys) = op else {
            Issue.record("Expected .exists")
            return
        }
        #expect(keys == ["k1", "k2"])
    }
}

// MARK: - Hash Commands

@Suite("RedisCommandParser - Hash Commands")
struct RedisCommandParserHashTests {
    @Test("HGET parses key and field")
    func hgetCommand() throws {
        let op = try TestRedisCommandParser.parse("HGET myhash field1")
        guard case .hget(let key, let field) = op else {
            Issue.record("Expected .hget")
            return
        }
        #expect(key == "myhash")
        #expect(field == "field1")
    }

    @Test("HSET parses key and field-value pairs")
    func hsetCommand() throws {
        let op = try TestRedisCommandParser.parse("HSET myhash f1 v1 f2 v2")
        guard case .hset(let key, let fieldValues) = op else {
            Issue.record("Expected .hset")
            return
        }
        #expect(key == "myhash")
        #expect(fieldValues.count == 2)
        #expect(fieldValues[0].0 == "f1")
        #expect(fieldValues[0].1 == "v1")
        #expect(fieldValues[1].0 == "f2")
        #expect(fieldValues[1].1 == "v2")
    }

    @Test("HSET with odd argument count throws")
    func hsetOddArgs() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("HSET myhash f1 v1 f2")
        }
    }

    @Test("HGETALL parses key")
    func hgetallCommand() throws {
        let op = try TestRedisCommandParser.parse("HGETALL myhash")
        guard case .hgetall(let key) = op else {
            Issue.record("Expected .hgetall")
            return
        }
        #expect(key == "myhash")
    }

    @Test("HDEL parses key and fields")
    func hdelCommand() throws {
        let op = try TestRedisCommandParser.parse("HDEL myhash f1 f2")
        guard case .hdel(let key, let fields) = op else {
            Issue.record("Expected .hdel")
            return
        }
        #expect(key == "myhash")
        #expect(fields == ["f1", "f2"])
    }
}

// MARK: - List Commands

@Suite("RedisCommandParser - List Commands")
struct RedisCommandParserListTests {
    @Test("LRANGE parses key, start, stop")
    func lrangeCommand() throws {
        let op = try TestRedisCommandParser.parse("LRANGE mylist 0 -1")
        guard case .lrange(let key, let start, let stop) = op else {
            Issue.record("Expected .lrange")
            return
        }
        #expect(key == "mylist")
        #expect(start == 0)
        #expect(stop == -1)
    }

    @Test("LRANGE with non-integer bounds throws")
    func lrangeInvalidBounds() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("LRANGE mylist abc def")
        }
    }

    @Test("LPUSH parses key and values")
    func lpushCommand() throws {
        let op = try TestRedisCommandParser.parse("LPUSH mylist a b c")
        guard case .lpush(let key, let values) = op else {
            Issue.record("Expected .lpush")
            return
        }
        #expect(key == "mylist")
        #expect(values == ["a", "b", "c"])
    }

    @Test("RPUSH parses key and values")
    func rpushCommand() throws {
        let op = try TestRedisCommandParser.parse("RPUSH mylist x y")
        guard case .rpush(let key, let values) = op else {
            Issue.record("Expected .rpush")
            return
        }
        #expect(key == "mylist")
        #expect(values == ["x", "y"])
    }

    @Test("LLEN parses key")
    func llenCommand() throws {
        let op = try TestRedisCommandParser.parse("LLEN mylist")
        guard case .llen(let key) = op else {
            Issue.record("Expected .llen")
            return
        }
        #expect(key == "mylist")
    }
}

// MARK: - Set Commands

@Suite("RedisCommandParser - Set Commands")
struct RedisCommandParserSetTests {
    @Test("SMEMBERS parses key")
    func smembersCommand() throws {
        let op = try TestRedisCommandParser.parse("SMEMBERS myset")
        guard case .smembers(let key) = op else {
            Issue.record("Expected .smembers")
            return
        }
        #expect(key == "myset")
    }

    @Test("SADD parses key and members")
    func saddCommand() throws {
        let op = try TestRedisCommandParser.parse("SADD myset a b c")
        guard case .sadd(let key, let members) = op else {
            Issue.record("Expected .sadd")
            return
        }
        #expect(key == "myset")
        #expect(members == ["a", "b", "c"])
    }

    @Test("SREM parses key and members")
    func sremCommand() throws {
        let op = try TestRedisCommandParser.parse("SREM myset a")
        guard case .srem(let key, let members) = op else {
            Issue.record("Expected .srem")
            return
        }
        #expect(key == "myset")
        #expect(members == ["a"])
    }

    @Test("SCARD parses key")
    func scardCommand() throws {
        let op = try TestRedisCommandParser.parse("SCARD myset")
        guard case .scard(let key) = op else {
            Issue.record("Expected .scard")
            return
        }
        #expect(key == "myset")
    }
}

// MARK: - Sorted Set Commands

@Suite("RedisCommandParser - Sorted Set Commands")
struct RedisCommandParserSortedSetTests {
    @Test("ZRANGE parses key, start, stop")
    func zrangeCommand() throws {
        let op = try TestRedisCommandParser.parse("ZRANGE myzset 0 -1")
        guard case .zrange(let key, let start, let stop, let withScores) = op else {
            Issue.record("Expected .zrange")
            return
        }
        #expect(key == "myzset")
        #expect(start == 0)
        #expect(stop == -1)
        #expect(withScores == false)
    }

    @Test("ZRANGE with WITHSCORES")
    func zrangeWithScores() throws {
        let op = try TestRedisCommandParser.parse("ZRANGE myzset 0 -1 WITHSCORES")
        guard case .zrange(_, _, _, let withScores) = op else {
            Issue.record("Expected .zrange")
            return
        }
        #expect(withScores == true)
    }

    @Test("ZADD parses key and score-member pairs")
    func zaddCommand() throws {
        let op = try TestRedisCommandParser.parse("ZADD myzset 1.5 a 2.0 b")
        guard case .zadd(let key, let scoreMembers) = op else {
            Issue.record("Expected .zadd")
            return
        }
        #expect(key == "myzset")
        #expect(scoreMembers.count == 2)
        #expect(scoreMembers[0].0 == 1.5)
        #expect(scoreMembers[0].1 == "a")
        #expect(scoreMembers[1].0 == 2.0)
        #expect(scoreMembers[1].1 == "b")
    }

    @Test("ZADD with non-numeric score throws")
    func zaddInvalidScore() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("ZADD myzset notanumber member")
        }
    }

    @Test("ZREM parses key and members")
    func zremCommand() throws {
        let op = try TestRedisCommandParser.parse("ZREM myzset a b")
        guard case .zrem(let key, let members) = op else {
            Issue.record("Expected .zrem")
            return
        }
        #expect(key == "myzset")
        #expect(members == ["a", "b"])
    }

    @Test("ZCARD parses key")
    func zcardCommand() throws {
        let op = try TestRedisCommandParser.parse("ZCARD myzset")
        guard case .zcard(let key) = op else {
            Issue.record("Expected .zcard")
            return
        }
        #expect(key == "myzset")
    }
}

// MARK: - Stream Commands

@Suite("RedisCommandParser - Stream Commands")
struct RedisCommandParserStreamTests {
    @Test("XRANGE parses key, start, end")
    func xrangeCommand() throws {
        let op = try TestRedisCommandParser.parse("XRANGE mystream - +")
        guard case .xrange(let key, let start, let end, let count) = op else {
            Issue.record("Expected .xrange")
            return
        }
        #expect(key == "mystream")
        #expect(start == "-")
        #expect(end == "+")
        #expect(count == nil)
    }

    @Test("XRANGE with COUNT")
    func xrangeWithCount() throws {
        let op = try TestRedisCommandParser.parse("XRANGE mystream - + COUNT 10")
        guard case .xrange(_, _, _, let count) = op else {
            Issue.record("Expected .xrange")
            return
        }
        #expect(count == 10)
    }

    @Test("XLEN parses key")
    func xlenCommand() throws {
        let op = try TestRedisCommandParser.parse("XLEN mystream")
        guard case .xlen(let key) = op else {
            Issue.record("Expected .xlen")
            return
        }
        #expect(key == "mystream")
    }
}

// MARK: - Server Commands

@Suite("RedisCommandParser - Server Commands")
struct RedisCommandParserServerTests {
    @Test("PING")
    func pingCommand() throws {
        let op = try TestRedisCommandParser.parse("PING")
        guard case .ping = op else {
            Issue.record("Expected .ping")
            return
        }
    }

    @Test("INFO without section")
    func infoCommand() throws {
        let op = try TestRedisCommandParser.parse("INFO")
        guard case .info(let section) = op else {
            Issue.record("Expected .info")
            return
        }
        #expect(section == nil)
    }

    @Test("INFO with section")
    func infoWithSection() throws {
        let op = try TestRedisCommandParser.parse("INFO memory")
        guard case .info(let section) = op else {
            Issue.record("Expected .info")
            return
        }
        #expect(section == "memory")
    }

    @Test("DBSIZE")
    func dbsizeCommand() throws {
        let op = try TestRedisCommandParser.parse("DBSIZE")
        guard case .dbsize = op else {
            Issue.record("Expected .dbsize")
            return
        }
    }

    @Test("SELECT parses database index")
    func selectCommand() throws {
        let op = try TestRedisCommandParser.parse("SELECT 3")
        guard case .select(let database) = op else {
            Issue.record("Expected .select")
            return
        }
        #expect(database == 3)
    }

    @Test("SELECT with non-integer throws")
    func selectInvalid() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("SELECT abc")
        }
    }

    @Test("CONFIG GET parses parameter")
    func configGetCommand() throws {
        let op = try TestRedisCommandParser.parse("CONFIG GET maxmemory")
        guard case .configGet(let parameter) = op else {
            Issue.record("Expected .configGet")
            return
        }
        #expect(parameter == "maxmemory")
    }

    @Test("CONFIG SET parses parameter and value")
    func configSetCommand() throws {
        let op = try TestRedisCommandParser.parse("CONFIG SET maxmemory 100mb")
        guard case .configSet(let parameter, let value) = op else {
            Issue.record("Expected .configSet")
            return
        }
        #expect(parameter == "maxmemory")
        #expect(value == "100mb")
    }

    @Test("MULTI")
    func multiCommand() throws {
        let op = try TestRedisCommandParser.parse("MULTI")
        guard case .multi = op else {
            Issue.record("Expected .multi")
            return
        }
    }

    @Test("EXEC")
    func execCommand() throws {
        let op = try TestRedisCommandParser.parse("EXEC")
        guard case .exec = op else {
            Issue.record("Expected .exec")
            return
        }
    }

    @Test("DISCARD")
    func discardCommand() throws {
        let op = try TestRedisCommandParser.parse("DISCARD")
        guard case .discard = op else {
            Issue.record("Expected .discard")
            return
        }
    }
}

// MARK: - Error Cases

@Suite("RedisCommandParser - Error Cases")
struct RedisCommandParserErrorTests {
    @Test("Empty input throws emptySyntax")
    func emptyInput() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("")
        }
    }

    @Test("Whitespace-only input throws emptySyntax")
    func whitespaceOnly() {
        #expect(throws: TestRedisParseError.self) {
            try TestRedisCommandParser.parse("   ")
        }
    }

    @Test("Unknown command returns .command with all tokens")
    func unknownCommand() throws {
        let op = try TestRedisCommandParser.parse("CUSTOM arg1 arg2")
        guard case .command(let args) = op else {
            Issue.record("Expected .command")
            return
        }
        #expect(args == ["CUSTOM", "arg1", "arg2"])
    }
}

// MARK: - Tokenizer

@Suite("RedisCommandParser - Tokenizer")
struct RedisCommandParserTokenizerTests {
    @Test("Double-quoted strings are parsed correctly")
    func doubleQuotedString() throws {
        let op = try TestRedisCommandParser.parse("SET mykey \"hello world\"")
        guard case .set(let key, let value, _) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(key == "mykey")
        #expect(value == "hello world")
    }

    @Test("Single-quoted strings are parsed correctly")
    func singleQuotedString() throws {
        let op = try TestRedisCommandParser.parse("SET mykey 'hello world'")
        guard case .set(let key, let value, _) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(key == "mykey")
        #expect(value == "hello world")
    }

    @Test("Escaped characters are preserved")
    func escapedCharacters() throws {
        let op = try TestRedisCommandParser.parse("SET mykey hello\\ world")
        guard case .set(let key, let value, _) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(key == "mykey")
        #expect(value == "hello world")
    }

    @Test("Case insensitivity for commands")
    func caseInsensitivity() throws {
        let op = try TestRedisCommandParser.parse("get mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Mixed case commands")
    func mixedCase() throws {
        let op = try TestRedisCommandParser.parse("GeT mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Multiple spaces between tokens")
    func multipleSpaces() throws {
        let op = try TestRedisCommandParser.parse("GET   mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Leading and trailing whitespace is trimmed")
    func leadingTrailingWhitespace() throws {
        let op = try TestRedisCommandParser.parse("  GET mykey  ")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }
}

// MARK: - Private Local Helpers (copied from RedisDriverPlugin)

private enum TestRedisOperation {
    case get(key: String)
    case set(key: String, value: String, options: TestRedisSetOptions?)
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
    case hget(key: String, field: String)
    case hset(key: String, fieldValues: [(String, String)])
    case hgetall(key: String)
    case hdel(key: String, fields: [String])
    case lrange(key: String, start: Int, stop: Int)
    case lpush(key: String, values: [String])
    case rpush(key: String, values: [String])
    case llen(key: String)
    case smembers(key: String)
    case sadd(key: String, members: [String])
    case srem(key: String, members: [String])
    case scard(key: String)
    case zrange(key: String, start: Int, stop: Int, withScores: Bool)
    case zadd(key: String, scoreMembers: [(Double, String)])
    case zrem(key: String, members: [String])
    case zcard(key: String)
    case xrange(key: String, start: String, end: String, count: Int?)
    case xlen(key: String)
    case ping
    case info(section: String?)
    case dbsize
    case flushdb
    case select(database: Int)
    case configGet(parameter: String)
    case configSet(parameter: String, value: String)
    case command(args: [String])
    case multi
    case exec
    case discard
}

private struct TestRedisSetOptions {
    var ex: Int?
    var px: Int?
    var nx: Bool = false
    var xx: Bool = false
}

private enum TestRedisParseError: Error, LocalizedError {
    case emptySyntax
    case invalidArgument(String)
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .emptySyntax:
            return "Empty Redis command"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .missingArgument(let msg):
            return "Missing argument: \(msg)"
        }
    }
}

private struct TestRedisCommandParser {
    static func parse(_ input: String) throws -> TestRedisOperation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TestRedisParseError.emptySyntax }

        let tokens = tokenize(trimmed)
        guard let first = tokens.first else { throw TestRedisParseError.emptySyntax }

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

    private static func parseKeyCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "GET":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("GET requires a key") }
            return .get(key: args[0])
        case "SET":
            guard args.count >= 2 else { throw TestRedisParseError.missingArgument("SET requires key and value") }
            let options = parseSetOptions(Array(args.dropFirst(2)))
            return .set(key: args[0], value: args[1], options: options)
        case "DEL":
            guard !args.isEmpty else { throw TestRedisParseError.missingArgument("DEL requires at least one key") }
            return .del(keys: args)
        case "KEYS":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("KEYS requires a pattern") }
            return .keys(pattern: args[0])
        case "SCAN":
            guard args.count >= 1, let cursor = Int(args[0]) else {
                throw TestRedisParseError.missingArgument("SCAN requires a cursor (integer)")
            }
            let (pattern, count) = parseScanOptions(Array(args.dropFirst()))
            return .scan(cursor: cursor, pattern: pattern, count: count)
        case "TYPE":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("TYPE requires a key") }
            return .type(key: args[0])
        case "TTL":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("TTL requires a key") }
            return .ttl(key: args[0])
        case "PTTL":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("PTTL requires a key") }
            return .pttl(key: args[0])
        case "EXPIRE":
            guard args.count >= 2 else { throw TestRedisParseError.missingArgument("EXPIRE requires key and seconds") }
            guard let seconds = Int(args[1]) else {
                throw TestRedisParseError.invalidArgument("EXPIRE seconds must be an integer")
            }
            return .expire(key: args[0], seconds: seconds)
        case "PERSIST":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("PERSIST requires a key") }
            return .persist(key: args[0])
        case "RENAME":
            guard args.count >= 2 else { throw TestRedisParseError.missingArgument("RENAME requires key and newKey") }
            return .rename(key: args[0], newKey: args[1])
        case "EXISTS":
            guard !args.isEmpty else { throw TestRedisParseError.missingArgument("EXISTS requires at least one key") }
            return .exists(keys: args)
        default:
            throw TestRedisParseError.invalidArgument("Unknown key command: \(command)")
        }
    }

    private static func parseHashCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "HGET":
            guard args.count >= 2 else { throw TestRedisParseError.missingArgument("HGET requires key and field") }
            return .hget(key: args[0], field: args[1])
        case "HSET":
            guard args.count >= 3, args.count % 2 == 1 else {
                throw TestRedisParseError.missingArgument("HSET requires key followed by field value pairs")
            }
            var fieldValues: [(String, String)] = []
            var i = 1
            while i + 1 < args.count {
                fieldValues.append((args[i], args[i + 1]))
                i += 2
            }
            return .hset(key: args[0], fieldValues: fieldValues)
        case "HGETALL":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("HGETALL requires a key") }
            return .hgetall(key: args[0])
        case "HDEL":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("HDEL requires key and at least one field")
            }
            return .hdel(key: args[0], fields: Array(args.dropFirst()))
        default:
            throw TestRedisParseError.invalidArgument("Unknown hash command: \(command)")
        }
    }

    private static func parseListCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "LRANGE":
            guard args.count >= 3 else {
                throw TestRedisParseError.missingArgument("LRANGE requires key, start, and stop")
            }
            guard let start = Int(args[1]), let stop = Int(args[2]) else {
                throw TestRedisParseError.invalidArgument("LRANGE start and stop must be integers")
            }
            return .lrange(key: args[0], start: start, stop: stop)
        case "LPUSH":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("LPUSH requires key and at least one value")
            }
            return .lpush(key: args[0], values: Array(args.dropFirst()))
        case "RPUSH":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("RPUSH requires key and at least one value")
            }
            return .rpush(key: args[0], values: Array(args.dropFirst()))
        case "LLEN":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("LLEN requires a key") }
            return .llen(key: args[0])
        default:
            throw TestRedisParseError.invalidArgument("Unknown list command: \(command)")
        }
    }

    private static func parseSetCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "SMEMBERS":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("SMEMBERS requires a key") }
            return .smembers(key: args[0])
        case "SADD":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("SADD requires key and at least one member")
            }
            return .sadd(key: args[0], members: Array(args.dropFirst()))
        case "SREM":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("SREM requires key and at least one member")
            }
            return .srem(key: args[0], members: Array(args.dropFirst()))
        case "SCARD":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("SCARD requires a key") }
            return .scard(key: args[0])
        default:
            throw TestRedisParseError.invalidArgument("Unknown set command: \(command)")
        }
    }

    private static func parseSortedSetCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "ZRANGE":
            guard args.count >= 3 else {
                throw TestRedisParseError.missingArgument("ZRANGE requires key, start, and stop")
            }
            guard let start = Int(args[1]), let stop = Int(args[2]) else {
                throw TestRedisParseError.invalidArgument("ZRANGE start and stop must be integers")
            }
            let withScores = args.count > 3 && args[3].uppercased() == "WITHSCORES"
            return .zrange(key: args[0], start: start, stop: stop, withScores: withScores)
        case "ZADD":
            guard args.count >= 3, (args.count - 1) % 2 == 0 else {
                throw TestRedisParseError.missingArgument("ZADD requires key followed by score member pairs")
            }
            var scoreMembers: [(Double, String)] = []
            var i = 1
            while i + 1 < args.count {
                guard let score = Double(args[i]) else {
                    throw TestRedisParseError.invalidArgument("ZADD score must be a number: \(args[i])")
                }
                scoreMembers.append((score, args[i + 1]))
                i += 2
            }
            return .zadd(key: args[0], scoreMembers: scoreMembers)
        case "ZREM":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("ZREM requires key and at least one member")
            }
            return .zrem(key: args[0], members: Array(args.dropFirst()))
        case "ZCARD":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("ZCARD requires a key") }
            return .zcard(key: args[0])
        default:
            throw TestRedisParseError.invalidArgument("Unknown sorted set command: \(command)")
        }
    }

    private static func parseStreamCommand(_ command: String, args: [String]) throws -> TestRedisOperation {
        switch command {
        case "XRANGE":
            guard args.count >= 3 else {
                throw TestRedisParseError.missingArgument("XRANGE requires key, start, and end")
            }
            var count: Int?
            if args.count >= 5, args[3].uppercased() == "COUNT" {
                count = Int(args[4])
            }
            return .xrange(key: args[0], start: args[1], end: args[2], count: count)
        case "XLEN":
            guard args.count >= 1 else { throw TestRedisParseError.missingArgument("XLEN requires a key") }
            return .xlen(key: args[0])
        default:
            throw TestRedisParseError.invalidArgument("Unknown stream command: \(command)")
        }
    }

    private static func parseServerCommand(
        _ command: String, args: [String], tokens: [String]
    ) throws -> TestRedisOperation {
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
                throw TestRedisParseError.missingArgument("SELECT requires a database index (integer)")
            }
            return .select(database: db)
        case "CONFIG":
            guard args.count >= 2 else {
                throw TestRedisParseError.missingArgument("CONFIG requires a subcommand and parameter")
            }
            let subcommand = args[0].uppercased()
            switch subcommand {
            case "GET":
                return .configGet(parameter: args[1])
            case "SET":
                guard args.count >= 3 else {
                    throw TestRedisParseError.missingArgument("CONFIG SET requires parameter and value")
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
            throw TestRedisParseError.invalidArgument("Unknown server command: \(command)")
        }
    }

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

    private static func parseSetOptions(_ args: [String]) -> TestRedisSetOptions? {
        guard !args.isEmpty else { return nil }
        var options = TestRedisSetOptions()
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
