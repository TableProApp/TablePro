import Foundation
import TableProMemcachedCore
import Testing

struct MemcachedCommandParserTests {
    @Test("A storage command takes the value as its last argument and sends it as a data block")
    func storeIsDataBlock() throws {
        let command = try MemcachedCommandParser.parse(#"set user:1 5 300 "hello world""#)
        #expect(command == .store(.set, key: "user:1", flags: 5, exptime: 300, value: Data("hello world".utf8)))
        #expect(String(bytes: command.wireBytes, encoding: .utf8) == "set user:1 5 300 11\r\nhello world\r\n")
    }

    @Test("A quoted value round-trips byte for byte", arguments: [
        "plain", "two words", "line\nbreak\r\n", "tab\there", "quote \" and \\ slash", "bell\u{07}", "日本語",
    ])
    func quotedRoundTrips(value: String) throws {
        let command = try MemcachedCommandParser.parse("set k 0 0 \(MemcachedCommandParser.quoted(value))")
        #expect(command == .store(.set, key: "k", flags: 0, exptime: 0, value: Data(value.utf8)))
    }

    @Test("Bytes that are not UTF-8 round-trip through \\x escapes")
    func bytesRoundTrip() throws {
        let bytes = Data([0x00, 0xFF, 0xC3, 0x28, 0x41, 0x22])
        let command = try MemcachedCommandParser.parse("set k 0 0 \(MemcachedCommandParser.quoted(bytes: bytes))")
        #expect(command == .store(.set, key: "k", flags: 0, exptime: 0, value: bytes))
    }

    @Test("Single quotes keep backslashes as written")
    func singleQuotesAreLiteral() throws {
        let command = try MemcachedCommandParser.parse(#"append k 0 0 'a\nb'"#)
        #expect(command == .store(.append, key: "k", flags: 0, exptime: 0, value: Data(#"a\nb"#.utf8)))
    }

    @Test("Reads, counters and admin commands parse", arguments: [
        ("get a b", MemcachedCommand.get(keys: ["a", "b"], withCAS: false)),
        ("GETS a", .get(keys: ["a"], withCAS: true)),
        ("gat 60 a b", .getAndTouch(exptime: 60, keys: ["a", "b"], withCAS: false)),
        ("touch a 0", .touch(key: "a", exptime: 0)),
        ("delete a", .delete(key: "a")),
        ("incr hits 3", .increment(key: "hits", delta: 3)),
        ("decr hits 1", .decrement(key: "hits", delta: 1)),
        ("flush_all", .flushAll(delay: nil)),
        ("flush_all 10", .flushAll(delay: 10)),
        ("stats", .stats(arguments: [])),
        ("stats cachedump 1 0", .stats(arguments: ["cachedump", "1", "0"])),
        ("version", .version),
        ("lru_crawler metadump all", .metadump(selector: "all")),
    ])
    func parses(text: String, expected: MemcachedCommand) throws {
        #expect(try MemcachedCommandParser.parse(text) == expected)
    }

    @Test("cas puts the unique after the byte count")
    func casWire() throws {
        let command = try MemcachedCommandParser.parse("cas k 0 0 42 v")
        #expect(String(bytes: command.wireBytes, encoding: .utf8) == "cas k 0 0 1 42\r\nv\r\n")
    }

    @Test("A key with a space or over 250 bytes is refused before it reaches the server")
    func invalidKeys() {
        #expect(throws: MemcachedCommandError.invalidKey("a b")) { try MemcachedCommandParser.parse(#"get "a b""#) }
        let long = String(repeating: "k", count: 251)
        #expect(throws: MemcachedCommandError.invalidKey(long)) { try MemcachedCommandParser.parse("delete \(long)") }
    }

    @Test("A wrong argument count names the usage")
    func wrongArguments() {
        #expect(throws: MemcachedCommandError.wrongArguments(
            command: "set", usage: "set <key> <flags> <exptime> <value>"
        )) { try MemcachedCommandParser.parse("set k 0 0") }
        #expect(throws: MemcachedCommandError.unknownCommand("shutdown")) { try MemcachedCommandParser.parse("shutdown") }
        #expect(throws: MemcachedCommandError.unterminatedQuote) { try MemcachedCommandParser.parse(#"set k 0 0 "x"#) }
        #expect(throws: MemcachedCommandError.invalidNumber("-1")) { try MemcachedCommandParser.parse("set k -1 0 v") }
    }

    @Test("A stats argument cannot smuggle a second command")
    func statsArgumentsArePlain() {
        #expect(throws: MemcachedCommandError.self) { try MemcachedCommandParser.parse("stats \"items\r\nflush_all\"") }
    }
}

struct MemcachedStatementsTests {
    @Test("A TTL past 30 days is sent as the Unix time it ends, since memcached reads it that way")
    func longTTLIsAbsolute() {
        #expect(MemcachedStatements.exptime(forTTL: nil, now: 1_000) == 0)
        #expect(MemcachedStatements.exptime(forTTL: 0, now: 1_000) == 0)
        #expect(MemcachedStatements.exptime(forTTL: 300, now: 1_000) == 300)
        #expect(MemcachedStatements.exptime(forTTL: MemcachedStatements.relativeExptimeLimit, now: 1_000)
            == MemcachedStatements.relativeExptimeLimit)
        #expect(MemcachedStatements.exptime(forTTL: MemcachedStatements.relativeExptimeLimit + 1, now: 1_000)
            == 1_000 + MemcachedStatements.relativeExptimeLimit + 1)
    }

    @Test("Each write statement parses back into its command")
    func statementsParse() throws {
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.set(key: "k", flags: 3, exptime: 60, value: "a \"b\"\n"))
            == .store(.set, key: "k", flags: 3, exptime: 60, value: Data("a \"b\"\n".utf8)))
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.set(key: "k", flags: 0, exptime: 0, bytes: Data([0xFF])))
            == .store(.set, key: "k", flags: 0, exptime: 0, value: Data([0xFF])))
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.touch(key: "k", exptime: 10)) == .touch(key: "k", exptime: 10))
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.delete(key: "k")) == .delete(key: "k"))
    }
}

struct MemcachedKeyQuotingTests {
    @Test("A key holding a quote or backslash is quoted, so the statement addresses that key", arguments: [
        "user'1", "a\"b\"", "back\\slash", "plain:key",
    ])
    func keysRoundTrip(key: String) throws {
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.delete(key: key)) == .delete(key: key))
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.touch(key: key, exptime: 5)) == .touch(key: key, exptime: 5))
        #expect(try MemcachedCommandParser.parse(MemcachedStatements.set(key: key, flags: 0, exptime: 0, value: "v"))
            == .store(.set, key: key, flags: 0, exptime: 0, value: Data("v".utf8)))
    }

    @Test("A plain key is written as it is")
    func plainKey() {
        #expect(MemcachedStatements.delete(key: "user:1") == "delete user:1")
    }

    @Test("stats forms that change the server answer one status line", arguments: [
        ("stats reset", MemcachedReplyShape.status), ("stats detail on", .status), ("stats detail off", .status),
        ("stats sizes_enable", .status), ("stats detail dump", .lines), ("stats items", .lines), ("stats", .lines),
    ])
    func statsShapes(statement: String, shape: MemcachedReplyShape) throws {
        #expect(try MemcachedCommandParser.parse(statement).replyShape == shape)
    }
}
