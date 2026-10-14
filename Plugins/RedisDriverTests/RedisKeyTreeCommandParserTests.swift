//
//  RedisKeyTreeCommandParserTests.swift
//  RedisDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct RedisKeyTreeCommandParserTests {
    @Test("KEYTREE with a limit parses to a key tree operation")
    func parsesLimit() throws {
        let op = try RedisCommandParser.parse("KEYTREE LIMIT 50000")
        guard case .keyTree(let pattern, let limit, let database) = op else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(pattern == nil)
        #expect(limit == 50_000)
        #expect(database == nil)
    }

    @Test("KEYTREE carries a MATCH pattern through")
    func parsesPattern() throws {
        guard case .keyTree(let pattern, _, _) = try RedisCommandParser.parse("KEYTREE MATCH cache:* LIMIT 10") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(pattern == "cache:*")
    }

    @Test("KEYTREE without a limit falls back to the row cap")
    func defaultsToRowCap() throws {
        guard case .keyTree(_, let limit, _) = try RedisCommandParser.parse("KEYTREE") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(limit == PluginRowLimits.emergencyMax)
    }

    private func database(of command: String) throws -> Int? {
        guard case .keyTree(_, _, let database) = try RedisCommandParser.parse(command) else {
            Issue.record("Expected a keyTree operation for \(command)")
            return nil
        }
        return database
    }

    @Test("DB names the database the tree lists, as an index or as the sidebar spells it")
    func parsesDatabase() throws {
        #expect(try database(of: "KEYTREE DB 3 LIMIT 10") == 3)
        #expect(try database(of: "KEYTREE MATCH a* DB db12") == 12)
        #expect(try database(of: "KEYTREE LIMIT 10") == nil)
    }

    @Test(
        "A DB that names no database is refused rather than read as the current one",
        arguments: ["KEYTREE DB", "KEYTREE DB x", "KEYTREE DB -1", "KEYTREE DB dbx"]
    )
    func rejectsInvalidDatabase(command: String) {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse(command)
        }
    }

    @Test("A DB with no index names the command it belongs to", arguments: ["KEYTREE", "KEYBROWSE"])
    func missingIndexNamesItsCommand(command: String) throws {
        do {
            _ = try RedisCommandParser.parse("\(command) DB")
            Issue.record("Expected \(command) DB to be refused")
        } catch let error as RedisParseError {
            #expect(error.pluginErrorMessage.contains("\(command) DB requires a database index"))
        }
    }

    @Test("KEYBROWSE still parses to a key browse operation")
    func keyBrowseUnaffected() throws {
        guard case .keyBrowse(let pattern, let typeScope, let limit, let offset, _) =
            try RedisCommandParser.parse("KEYBROWSE MATCH session:* TYPE hash LIMIT 100 OFFSET 50") else {
            Issue.record("Expected a keyBrowse operation")
            return
        }
        #expect(pattern == "session:*")
        #expect(typeScope == "hash")
        #expect(limit == 100)
        #expect(offset == 50)
    }
}

// TableProTests' RedisKeyTreeAppCommandTests pins the app's key tree to sending exactly these commands.
struct RedisKeyTreeAppCommandParseTests {
    @Test("The key tree's listing reads the database and the limit it names")
    func listingParses() throws {
        guard case .keyTree(let pattern, let limit, let database) =
            try RedisCommandParser.parse("KEYTREE DB 7 LIMIT 50000") else {
            Issue.record("Expected a keyTree operation")
            return
        }
        #expect(pattern == nil)
        #expect(limit == 50_000)
        #expect(database == 7)
    }

    private func opened(_ read: String) throws -> RedisOperation? {
        guard case .inDatabase(4, let operation) = try RedisCommandParser.parse("DB 4 \(read)") else {
            Issue.record("Expected a read in database 4 for \(read)")
            return nil
        }
        return operation
    }

    @Test("Opening a key reads that key with the read its type takes")
    func openedKeyParses() throws {
        guard case .get(let getKey) = try opened("GET k") else {
            Issue.record("Expected GET")
            return
        }
        #expect(getKey == "k")

        guard case .hgetall(let hashKey) = try opened("HGETALL k") else {
            Issue.record("Expected HGETALL")
            return
        }
        #expect(hashKey == "k")

        guard case .lrange(let listKey, let start, let stop) = try opened("LRANGE k 0 -1") else {
            Issue.record("Expected LRANGE")
            return
        }
        #expect(listKey == "k")
        #expect(start == 0)
        #expect(stop == -1)

        guard case .smembers(let setKey) = try opened("SMEMBERS k") else {
            Issue.record("Expected SMEMBERS")
            return
        }
        #expect(setKey == "k")

        guard case .zrange(let zsetKey, _, _, let flags) = try opened("ZRANGE k 0 -1 WITHSCORES") else {
            Issue.record("Expected ZRANGE")
            return
        }
        #expect(zsetKey == "k")
        #expect(flags == ["WITHSCORES"])

        guard case .xrange(let streamKey, _, _, let count) = try opened("XRANGE k - +") else {
            Issue.record("Expected XRANGE")
            return
        }
        #expect(streamKey == "k")
        #expect(count == nil)
    }

    @Test("A quoted key reaches the read as the bytes the quoting stands for")
    func quotedKeyParses() throws {
        guard case .get(let key) = try opened(#"GET "new\nline""#) else {
            Issue.record("Expected GET")
            return
        }
        #expect(key == "new\nline")
    }
}
