//
//  RedisCommandParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

// MARK: - Key Commands

@Suite("RedisCommandParser - Key Commands")
struct RedisCommandParserKeyCommandTests {
    @Test("GET parses key")
    func getCommand() throws {
        let op = try RedisCommandParser.parse("GET mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get, got \(op)")
            return
        }
        #expect(key == "mykey")
    }

    @Test("GET missing key throws")
    func getMissingKey() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("GET")
        }
    }

    @Test("SET parses key and value")
    func setCommand() throws {
        let op = try RedisCommandParser.parse("SET mykey myvalue")
        guard case .set(let key, let value, let options) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(key == "mykey")
        #expect(value == Data("myvalue".utf8))
        #expect(options == nil)
    }

    @Test("SET with EX option")
    func setWithExpiry() throws {
        let op = try RedisCommandParser.parse("SET mykey myvalue EX 60")
        guard case .set(_, _, let options) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(options?.ex == 60)
    }

    @Test("SET with NX option")
    func setWithNx() throws {
        let op = try RedisCommandParser.parse("SET mykey myvalue NX")
        guard case .set(_, _, let options) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(options?.nx == true)
    }

    @Test("SET missing value throws")
    func setMissingValue() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("SET mykey")
        }
    }

    @Test("DEL parses single key")
    func delSingleKey() throws {
        let op = try RedisCommandParser.parse("DEL mykey")
        guard case .del(let keys) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(keys == ["mykey"])
    }

    @Test("DEL parses multiple keys")
    func delMultipleKeys() throws {
        let op = try RedisCommandParser.parse("DEL key1 key2 key3")
        guard case .del(let keys) = op else {
            Issue.record("Expected .del")
            return
        }
        #expect(keys == ["key1", "key2", "key3"])
    }

    @Test("DEL missing key throws")
    func delMissingKey() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("DEL")
        }
    }

    @Test("KEYS parses pattern")
    func keysCommand() throws {
        let op = try RedisCommandParser.parse("KEYS user:*")
        guard case .keys(let pattern) = op else {
            Issue.record("Expected .keys")
            return
        }
        #expect(pattern == "user:*")
    }

    @Test("SCAN parses cursor with MATCH and COUNT")
    func scanWithOptions() throws {
        let op = try RedisCommandParser.parse("SCAN 0 MATCH user:* COUNT 100")
        guard case .scan(let cursor, let pattern, let count, let type) = op else {
            Issue.record("Expected .scan")
            return
        }
        #expect(cursor == "0")
        #expect(pattern == "user:*")
        #expect(count == 100)
        #expect(type == nil)
    }

    @Test("SCAN without options")
    func scanBasic() throws {
        let op = try RedisCommandParser.parse("SCAN 0")
        guard case .scan(let cursor, let pattern, let count, let type) = op else {
            Issue.record("Expected .scan")
            return
        }
        #expect(cursor == "0")
        #expect(pattern == nil)
        #expect(count == nil)
        #expect(type == nil)
    }

    @Test("TYPE parses key")
    func typeCommand() throws {
        let op = try RedisCommandParser.parse("TYPE mykey")
        guard case .type(let key) = op else {
            Issue.record("Expected .type")
            return
        }
        #expect(key == "mykey")
    }

    @Test("TTL parses key")
    func ttlCommand() throws {
        let op = try RedisCommandParser.parse("TTL mykey")
        guard case .ttl(let key) = op else {
            Issue.record("Expected .ttl")
            return
        }
        #expect(key == "mykey")
    }

    @Test("EXPIRE parses key and seconds")
    func expireCommand() throws {
        let op = try RedisCommandParser.parse("EXPIRE mykey 300")
        guard case .expire(let key, let seconds) = op else {
            Issue.record("Expected .expire")
            return
        }
        #expect(key == "mykey")
        #expect(seconds == 300)
    }

    @Test("EXPIRE with non-integer seconds throws")
    func expireInvalidSeconds() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("EXPIRE mykey abc")
        }
    }

    @Test("RENAME parses key and newKey")
    func renameCommand() throws {
        let op = try RedisCommandParser.parse("RENAME oldkey newkey")
        guard case .rename(let key, let newKey) = op else {
            Issue.record("Expected .rename")
            return
        }
        #expect(key == "oldkey")
        #expect(newKey == "newkey")
    }

    @Test("EXISTS parses multiple keys")
    func existsCommand() throws {
        let op = try RedisCommandParser.parse("EXISTS k1 k2")
        guard case .exists(let keys) = op else {
            Issue.record("Expected .exists")
            return
        }
        #expect(keys == ["k1", "k2"])
    }

    @Test(
        "A SET option the parser does not model goes out verbatim",
        arguments: ["SET k v KEEPTTL", "SET k v GET"]
    )
    func setWithUnmodelledOptionIsVerbatim(input: String) throws {
        let op = try RedisCommandParser.parse(input)
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == input.split(separator: " ").map(String.init))
    }

    @Test("SET with EXAT carries the timestamp")
    func setWithExat() throws {
        let op = try RedisCommandParser.parse("SET k v EXAT 100")
        guard case .set(_, _, let options) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(options?.exat == 100)
    }

    @Test("SET with an EX that is not a positive integer throws", arguments: ["SET k v EX abc", "SET k v EX 0"])
    func setWithInvalidExpiryThrows(input: String) {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse(input)
        }
    }

    @Test("EXPIRE with a condition flag goes out verbatim")
    func expireWithFlagIsVerbatim() throws {
        let op = try RedisCommandParser.parse("EXPIRE k 10 NX")
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == ["EXPIRE", "k", "10", "NX"])
    }

    @Test("A SCAN cursor above Int.max keeps its text")
    func scanCursorAboveIntMax() throws {
        let op = try RedisCommandParser.parse("SCAN 18446744073709551615")
        guard case .scan(let cursor, _, _, _) = op else {
            Issue.record("Expected .scan, got \(op)")
            return
        }
        #expect(cursor == "18446744073709551615")
    }

    @Test("A SCAN COUNT that is not an integer throws")
    func scanWithInvalidCountThrows() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("SCAN 0 COUNT abc")
        }
    }

    @Test("SCAN carries its TYPE along with MATCH and COUNT")
    func scanWithType() throws {
        let op = try RedisCommandParser.parse("SCAN 0 MATCH u:* TYPE hash COUNT 5")
        guard case .scan(let cursor, let pattern, let count, let type) = op else {
            Issue.record("Expected .scan, got \(op)")
            return
        }
        #expect(cursor == "0")
        #expect(pattern == "u:*")
        #expect(count == 5)
        #expect(type == "hash")
    }

    @Test("A SCAN option the typed scan cannot carry goes out verbatim", arguments: ["SCAN 0 NOVALUES", "SCAN 0 MATCH"])
    func scanWithUnmodelledOptionIsVerbatim(input: String) throws {
        let op = try RedisCommandParser.parse(input)
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == input.split(separator: " ").map(String.init))
    }
}

// MARK: - Hash Commands

@Suite("RedisCommandParser - Hash Commands")
struct RedisCommandParserHashTests {
    @Test("HGET parses key and field")
    func hgetCommand() throws {
        let op = try RedisCommandParser.parse("HGET myhash field1")
        guard case .hget(let key, let field) = op else {
            Issue.record("Expected .hget")
            return
        }
        #expect(key == "myhash")
        #expect(field == "field1")
    }

    @Test("HSET parses key and field-value pairs")
    func hsetCommand() throws {
        let op = try RedisCommandParser.parse("HSET myhash f1 v1 f2 v2")
        guard case .hset(let key, let fieldValues) = op else {
            Issue.record("Expected .hset")
            return
        }
        #expect(key == "myhash")
        #expect(fieldValues.count == 2)
        #expect(fieldValues[0].0 == "f1")
        #expect(fieldValues[0].1 == Data("v1".utf8))
        #expect(fieldValues[1].0 == "f2")
        #expect(fieldValues[1].1 == Data("v2".utf8))
    }

    @Test("HSET with odd argument count throws")
    func hsetOddArgs() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("HSET myhash f1 v1 f2")
        }
    }

    @Test("HGETALL parses key")
    func hgetallCommand() throws {
        let op = try RedisCommandParser.parse("HGETALL myhash")
        guard case .hgetall(let key) = op else {
            Issue.record("Expected .hgetall")
            return
        }
        #expect(key == "myhash")
    }

    @Test("HDEL parses key and fields")
    func hdelCommand() throws {
        let op = try RedisCommandParser.parse("HDEL myhash f1 f2")
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
        let op = try RedisCommandParser.parse("LRANGE mylist 0 -1")
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
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("LRANGE mylist abc def")
        }
    }

    @Test("LPUSH parses key and values")
    func lpushCommand() throws {
        let op = try RedisCommandParser.parse("LPUSH mylist a b c")
        guard case .lpush(let key, let values) = op else {
            Issue.record("Expected .lpush")
            return
        }
        let expected = ["a", "b", "c"].map { Data($0.utf8) }
        #expect(key == "mylist")
        #expect(values == expected)
    }

    @Test("RPUSH parses key and values")
    func rpushCommand() throws {
        let op = try RedisCommandParser.parse("RPUSH mylist x y")
        guard case .rpush(let key, let values) = op else {
            Issue.record("Expected .rpush")
            return
        }
        let expected = ["x", "y"].map { Data($0.utf8) }
        #expect(key == "mylist")
        #expect(values == expected)
    }

    @Test("LLEN parses key")
    func llenCommand() throws {
        let op = try RedisCommandParser.parse("LLEN mylist")
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
        let op = try RedisCommandParser.parse("SMEMBERS myset")
        guard case .smembers(let key) = op else {
            Issue.record("Expected .smembers")
            return
        }
        #expect(key == "myset")
    }

    @Test("SADD parses key and members")
    func saddCommand() throws {
        let op = try RedisCommandParser.parse("SADD myset a b c")
        guard case .sadd(let key, let members) = op else {
            Issue.record("Expected .sadd")
            return
        }
        let expected = ["a", "b", "c"].map { Data($0.utf8) }
        #expect(key == "myset")
        #expect(members == expected)
    }

    @Test("SREM parses key and members")
    func sremCommand() throws {
        let op = try RedisCommandParser.parse("SREM myset a")
        guard case .srem(let key, let members) = op else {
            Issue.record("Expected .srem")
            return
        }
        #expect(key == "myset")
        #expect(members == [Data("a".utf8)])
    }

    @Test("SCARD parses key")
    func scardCommand() throws {
        let op = try RedisCommandParser.parse("SCARD myset")
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
        let op = try RedisCommandParser.parse("ZRANGE myzset 0 -1")
        guard case .zrange(let key, let start, let stop, let flags) = op else {
            Issue.record("Expected .zrange")
            return
        }
        #expect(key == "myzset")
        #expect(start == "0")
        #expect(stop == "-1")
        #expect(flags.isEmpty)
    }

    @Test("ZRANGE with WITHSCORES")
    func zrangeWithScores() throws {
        let op = try RedisCommandParser.parse("ZRANGE myzset 0 -1 WITHSCORES")
        guard case .zrange(_, _, _, let flags) = op else {
            Issue.record("Expected .zrange")
            return
        }
        #expect(flags == ["WITHSCORES"])
    }

    @Test("ZRANGE keeps score bounds as text and every flag in order")
    func zrangeByScoreWithLimit() throws {
        let op = try RedisCommandParser.parse("ZRANGE z (1 +inf BYSCORE LIMIT 0 10 WITHSCORES")
        guard case .zrange(let key, let start, let stop, let flags) = op else {
            Issue.record("Expected .zrange, got \(op)")
            return
        }
        #expect(key == "z")
        #expect(start == "(1")
        #expect(stop == "+inf")
        #expect(flags == ["BYSCORE", "LIMIT", "0", "10", "WITHSCORES"])
    }

    @Test("ZRANGE with a LIMIT missing its count throws")
    func zrangeWithShortLimitThrows() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("ZRANGE z 0 -1 LIMIT 0")
        }
    }

    @Test("ZADD carries its flags ahead of the score-member pairs")
    func zaddWithFlags() throws {
        let op = try RedisCommandParser.parse("ZADD z NX CH 1 a")
        guard case .zadd(let key, let flags, let scoreMembers) = op else {
            Issue.record("Expected .zadd, got \(op)")
            return
        }
        #expect(key == "z")
        #expect(flags == ["NX", "CH"])
        #expect(scoreMembers.count == 1)
        #expect(scoreMembers.first?.0 == 1)
        #expect(scoreMembers.first?.1 == Data("a".utf8))
    }

    @Test("ZADD parses key and score-member pairs")
    func zaddCommand() throws {
        let op = try RedisCommandParser.parse("ZADD myzset 1.5 a 2.0 b")
        guard case .zadd(let key, let flags, let scoreMembers) = op else {
            Issue.record("Expected .zadd")
            return
        }
        #expect(key == "myzset")
        #expect(flags.isEmpty)
        #expect(scoreMembers.count == 2)
        #expect(scoreMembers[0].0 == 1.5)
        #expect(scoreMembers[0].1 == Data("a".utf8))
        #expect(scoreMembers[1].0 == 2.0)
        #expect(scoreMembers[1].1 == Data("b".utf8))
    }

    @Test("ZADD with non-numeric score throws")
    func zaddInvalidScore() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("ZADD myzset notanumber member")
        }
    }

    @Test("ZREM parses key and members")
    func zremCommand() throws {
        let op = try RedisCommandParser.parse("ZREM myzset a b")
        guard case .zrem(let key, let members) = op else {
            Issue.record("Expected .zrem")
            return
        }
        let expected = ["a", "b"].map { Data($0.utf8) }
        #expect(key == "myzset")
        #expect(members == expected)
    }

    @Test("ZCARD parses key")
    func zcardCommand() throws {
        let op = try RedisCommandParser.parse("ZCARD myzset")
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
        let op = try RedisCommandParser.parse("XRANGE mystream - +")
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
        let op = try RedisCommandParser.parse("XRANGE mystream - + COUNT 10")
        guard case .xrange(_, _, _, let count) = op else {
            Issue.record("Expected .xrange")
            return
        }
        #expect(count == 10)
    }

    @Test("XLEN parses key")
    func xlenCommand() throws {
        let op = try RedisCommandParser.parse("XLEN mystream")
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
        let op = try RedisCommandParser.parse("PING")
        guard case .ping = op else {
            Issue.record("Expected .ping")
            return
        }
    }

    @Test("INFO without section")
    func infoCommand() throws {
        let op = try RedisCommandParser.parse("INFO")
        guard case .info(let sections) = op else {
            Issue.record("Expected .info")
            return
        }
        #expect(sections.isEmpty)
    }

    @Test("INFO with section")
    func infoWithSection() throws {
        let op = try RedisCommandParser.parse("INFO memory")
        guard case .info(let sections) = op else {
            Issue.record("Expected .info")
            return
        }
        #expect(sections == ["memory"])
    }

    @Test("INFO carries every section it names")
    func infoWithSeveralSections() throws {
        let op = try RedisCommandParser.parse("INFO server clients")
        guard case .info(let sections) = op else {
            Issue.record("Expected .info, got \(op)")
            return
        }
        #expect(sections == ["server", "clients"])
    }

    @Test("DBSIZE")
    func dbsizeCommand() throws {
        let op = try RedisCommandParser.parse("DBSIZE")
        guard case .dbsize = op else {
            Issue.record("Expected .dbsize")
            return
        }
    }

    @Test("SELECT parses database index")
    func selectCommand() throws {
        let op = try RedisCommandParser.parse("SELECT 3")
        guard case .select(let database) = op else {
            Issue.record("Expected .select")
            return
        }
        #expect(database == 3)
    }

    @Test("SELECT with non-integer throws")
    func selectInvalid() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("SELECT abc")
        }
    }

    @Test("CONFIG GET parses parameter")
    func configGetCommand() throws {
        let op = try RedisCommandParser.parse("CONFIG GET maxmemory")
        guard case .configGet(let parameters) = op else {
            Issue.record("Expected .configGet")
            return
        }
        #expect(parameters == ["maxmemory"])
    }

    @Test("CONFIG GET carries every parameter it names")
    func configGetSeveralParameters() throws {
        let op = try RedisCommandParser.parse("CONFIG GET maxmemory maxclients")
        guard case .configGet(let parameters) = op else {
            Issue.record("Expected .configGet, got \(op)")
            return
        }
        #expect(parameters == ["maxmemory", "maxclients"])
    }

    @Test("FLUSHDB with no argument stays typed")
    func flushdbCommand() throws {
        let op = try RedisCommandParser.parse("FLUSHDB")
        guard case .flushdb = op else {
            Issue.record("Expected .flushdb, got \(op)")
            return
        }
    }

    @Test("CONFIG SET parses parameter and value")
    func configSetCommand() throws {
        let op = try RedisCommandParser.parse("CONFIG SET maxmemory 100mb")
        guard case .configSet(let parameter, let value) = op else {
            Issue.record("Expected .configSet")
            return
        }
        #expect(parameter == "maxmemory")
        #expect(value == "100mb")
    }

    @Test("MULTI")
    func multiCommand() throws {
        let op = try RedisCommandParser.parse("MULTI")
        guard case .multi = op else {
            Issue.record("Expected .multi")
            return
        }
    }

    @Test("EXEC")
    func execCommand() throws {
        let op = try RedisCommandParser.parse("EXEC")
        guard case .exec = op else {
            Issue.record("Expected .exec")
            return
        }
    }

    @Test("DISCARD")
    func discardCommand() throws {
        let op = try RedisCommandParser.parse("DISCARD")
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
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("")
        }
    }

    @Test("Whitespace-only input throws emptySyntax")
    func whitespaceOnly() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("   ")
        }
    }

    @Test("Unknown command returns .command with all tokens")
    func unknownCommand() throws {
        let op = try RedisCommandParser.parse("CUSTOM arg1 arg2")
        guard case .command(let args) = op else {
            Issue.record("Expected .command")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == ["CUSTOM", "arg1", "arg2"])
    }
}

// MARK: - Tokenizer

@Suite("RedisCommandParser - Tokenizer")
struct RedisCommandParserTokenizerTests {
    @Test("Double-quoted strings are parsed correctly")
    func doubleQuotedString() throws {
        let op = try RedisCommandParser.parse("SET mykey \"hello world\"")
        guard case .set(let key, let value, _) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(key == "mykey")
        #expect(value == Data("hello world".utf8))
    }

    @Test("Single-quoted strings are parsed correctly")
    func singleQuotedString() throws {
        let op = try RedisCommandParser.parse("SET mykey 'hello world'")
        guard case .set(let key, let value, _) = op else {
            Issue.record("Expected .set")
            return
        }
        #expect(key == "mykey")
        #expect(value == Data("hello world".utf8))
    }

    @Test("A backslash outside quotes is a literal byte, as in redis-cli")
    func backslashOutsideQuotesIsLiteral() throws {
        let op = try RedisCommandParser.parse("SET mykey hello\\ world")
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == ["SET", "mykey", "hello\\", "world"])
    }

    @Test("Escapes inside double quotes are decoded")
    func doubleQuotedEscapesDecode() throws {
        let op = try RedisCommandParser.parse("SET k \"a\\nb\"")
        guard case .set(_, let value, _) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(value == Data([0x61, 0x0A, 0x62]))
    }

    @Test("A hex escape inside double quotes decodes to its byte")
    func doubleQuotedHexEscapeDecodes() throws {
        let op = try RedisCommandParser.parse("SET k \"\\x41\\x42\"")
        guard case .set(_, let value, _) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(value == Data("AB".utf8))
    }

    @Test("Inside single quotes only an escaped quote is decoded")
    func singleQuotedKeepsBackslashes() throws {
        let op = try RedisCommandParser.parse("SET k 'a\\b\\'c'")
        guard case .set(_, let value, _) = op else {
            Issue.record("Expected .set, got \(op)")
            return
        }
        #expect(value == Data("a\\b'c".utf8))
    }

    @Test("Text right after a closing quote is refused, as redis-cli refuses it")
    func textAfterClosingQuoteThrows() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("SET k a\"b c\"d")
        }
    }

    @Test("An unbalanced quote is refused")
    func unbalancedQuoteThrows() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("SET k \"abc")
        }
    }

    @Test("A no-break space is part of the argument, not a separator")
    func noBreakSpaceIsNotBlank() throws {
        let op = try RedisCommandParser.parse("GET a\u{00A0}b")
        guard case .get(let key) = op else {
            Issue.record("Expected .get, got \(op)")
            return
        }
        #expect(key == "a\u{00A0}b")
    }

    @Test("Case insensitivity for commands")
    func caseInsensitivity() throws {
        let op = try RedisCommandParser.parse("get mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Mixed case commands")
    func mixedCase() throws {
        let op = try RedisCommandParser.parse("GeT mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Multiple spaces between tokens")
    func multipleSpaces() throws {
        let op = try RedisCommandParser.parse("GET   mykey")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }

    @Test("Leading and trailing whitespace is trimmed")
    func leadingTrailingWhitespace() throws {
        let op = try RedisCommandParser.parse("  GET mykey  ")
        guard case .get(let key) = op else {
            Issue.record("Expected .get")
            return
        }
        #expect(key == "mykey")
    }
}

@Suite("RedisCommandParser - KEYBROWSE round-trip")
struct RedisKeyBrowseRoundTripTests {
    private let builder = RedisQueryBuilder()

    @Test("A built key-browse command parses back to its pattern, type, limit, and offset")
    func keyBrowseRoundTrips() throws {
        let command = builder.buildKeyBrowseQuery(pattern: "user:*", typeScope: "hash", limit: 100, offset: 200)
        let op = try RedisCommandParser.parse(command)
        guard case .keyBrowse(let pattern, let typeScope, let limit, let offset, let database) = op else {
            Issue.record("Expected .keyBrowse, got \(op)")
            return
        }
        #expect(pattern == "user:*")
        #expect(typeScope == "hash")
        #expect(limit == 100)
        #expect(offset == 200)
        #expect(database == nil)
    }

    @Test("A pattern with quotes and spaces survives the build and parse round-trip")
    func quotedPatternRoundTrips() throws {
        let raw = #"a "b" c*"#
        let command = builder.buildKeyBrowseQuery(pattern: raw, typeScope: nil, limit: 200, offset: 0)
        let op = try RedisCommandParser.parse(command)
        guard case .keyBrowse(let pattern, let typeScope, _, _, _) = op else {
            Issue.record("Expected .keyBrowse, got \(op)")
            return
        }
        #expect(pattern == raw)
        #expect(typeScope == nil)
    }

    @Test("A type-only key-browse command parses with no pattern")
    func typeOnlyRoundTrips() throws {
        let command = builder.buildKeyBrowseQuery(pattern: nil, typeScope: "stream", limit: 200, offset: 0)
        let op = try RedisCommandParser.parse(command)
        guard case .keyBrowse(let pattern, let typeScope, _, _, _) = op else {
            Issue.record("Expected .keyBrowse, got \(op)")
            return
        }
        #expect(pattern == nil)
        #expect(typeScope == "stream")
    }
}

@Suite("RedisCommandParser - arguments a typed case cannot carry")
struct RedisCommandParserVerbatimTests {
    @Test(
        "A recognised command with arguments its typed case cannot carry goes out exactly as typed",
        arguments: [
            "GET a b",
            "PING hello",
            "FLUSHDB ASYNC",
            "MULTI x",
            "SELECT 1 2",
            "XRANGE s - + COUNT abc",
            "ZRANGE z 0 -1 FOO",
            "CONFIG SET a 1 b 2",
            "CONFIG RESETSTAT",
            "CONFIG GET",
            "HGET h f extra",
            "LRANGE l 0 -1 extra",
            "RENAME a b c"
        ]
    )
    func extraArgumentsGoOutVerbatim(input: String) throws {
        let op = try RedisCommandParser.parse(input)
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let expected = RedisArgumentCodec.split(input)?.map { RedisArgument($0).text }
        let texts = args.map(\.text)
        #expect(texts == expected)
    }

    @Test(
        "A subcommand the parser never modelled is left for the server to judge",
        arguments: ["XGROUP CREATECONSUMER s g c1", "XGROUP HELP", "XINFO HELP", "OBJECT HELP"]
    )
    func unmodelledSubcommandsParse(input: String) throws {
        let op = try RedisCommandParser.parse(input)
        guard case .command(let args) = op else {
            Issue.record("Expected .command, got \(op)")
            return
        }
        let texts = args.map(\.text)
        #expect(texts == input.split(separator: " ").map(String.init))
    }

    @Test("XRANGE with a COUNT stays typed")
    func xrangeWithCountStaysTyped() throws {
        let op = try RedisCommandParser.parse("XRANGE s - + COUNT 5")
        guard case .xrange(let key, let start, let end, let count) = op else {
            Issue.record("Expected .xrange, got \(op)")
            return
        }
        #expect(key == "s")
        #expect(start == "-")
        #expect(end == "+")
        #expect(count == 5)
    }

    @Test("A too-short command still throws before it reaches the server")
    func tooFewArgumentsStillThrow() {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse("HGET h")
        }
    }
}

@Suite("RedisCommandParser - statements the app builds stay typed")
struct RedisCommandParserAppStatementTests {
    private static let browseColumns = ["Key", "Type", "TTL", "Length", "Value"]

    private func isVerbatim(_ statement: String) throws -> Bool {
        if case .command = try RedisCommandParser.parse(statement) { return true }
        return false
    }

    private func insertStatements(key: String, type: String, value: String) -> [String] {
        let generator = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let row: [PluginCellValue] = [.text(key), .text(type), "60", .null, .text(value)]
        return generator.generateStatements(
            from: [change], insertedRowData: [0: row], deletedRowIndices: [], insertedRowIndices: [0]
        ).map(\.statement)
    }

    @Test(
        "Every insert the grid builds parses to its typed case",
        arguments: ["string", "hash", "list", "set", "zset"]
    )
    func insertsStayTyped(type: String) throws {
        let value = type == "hash" ? #"{"f":"v w"}"# : "a \"quoted\" value"
        let statements = insertStatements(key: "user:1 x", type: type, value: value)
        #expect(statements.count == 2)
        for statement in statements {
            #expect(try !isVerbatim(statement), "\(statement)")
        }
    }

    @Test("A grid update, rename, TTL change and delete parse to their typed cases")
    func updatesAndDeletesStayTyped() throws {
        let generator = RedisStatementGenerator(namespaceName: "", columns: Self.browseColumns)
        let original: [PluginCellValue] = [.text("old key"), .text("STRING"), "-1", "3", .text("old")]
        let update = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 0, columnName: "Key", oldValue: .text("old key"), newValue: .text("new key")),
                (columnIndex: 4, columnName: "Value", oldValue: .text("old"), newValue: .text("new value")),
                (columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "30")
            ],
            originalRow: original
        )
        let persist = PluginRowChange(
            rowIndex: 1,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "TTL", oldValue: "30", newValue: "-1")],
            originalRow: original
        )
        let delete = PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: original)
        let statements = generator.generateStatements(
            from: [update, persist, delete], insertedRowData: [:], deletedRowIndices: [2], insertedRowIndices: []
        ).map(\.statement)

        #expect(statements.count == 5)
        for statement in statements {
            #expect(try !isVerbatim(statement), "\(statement)")
        }
    }

    @Test("The count and browse queries parse to their typed cases")
    func browseQueriesStayTyped() throws {
        let builder = RedisQueryBuilder()
        let queries = [
            builder.buildCountQuery(namespace: ""),
            builder.buildCountQuery(namespace: "user:"),
            builder.buildKeyBrowseQuery(pattern: "a*", typeScope: "hash", database: 3, limit: 50, offset: 0),
            builder.buildExportQuery(database: 2)
        ]
        for query in queries {
            #expect(try !isVerbatim(query), "\(query)")
        }
    }

    @Test("A namespace is matched literally, quotes and glob characters included")
    func countQueryEscapesTheNamespace() throws {
        let query = RedisQueryBuilder().buildCountQuery(namespace: "a\"b*c\\")
        #expect(query == #"SCAN 0 MATCH "a\"b\\*c\\\\*" COUNT 10000"#)
        guard case .scan(_, let pattern, _, _) = try RedisCommandParser.parse(query) else {
            Issue.record("Expected SCAN"); return
        }
        #expect(pattern == #"a"b\*c\\*"#)
    }
}
