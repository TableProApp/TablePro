//
//  RedisKeyTreeCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct RedisKeyTreeCommandTests {
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

struct RedisKeyTreeAppCommandTests {
    @Test("The tree's listing names its database and its limit")
    func listingRoundTrips() throws {
        let command = RedisKeyTreeCommand.listKeys(inDatabase: 7, limit: 50_000)
        guard case .keyTree(let pattern, let limit, let database) = try RedisCommandParser.parse(command) else {
            Issue.record("Expected a keyTree operation for \(command)")
            return
        }
        #expect(pattern == nil)
        #expect(limit == 50_000)
        #expect(database == 7)
    }

    static let keys = [
        "zero:a",
        "has space",
        #"back\slash"#,
        #"trailing\"#,
        #"quote"d"#,
        "it's",
        "new\nline",
        "tab\there",
        #"\x41 stays text"#,
        "semi;colon",
        "café ☕",
        "bell\u{07}and\u{7F}"
    ]

    private func opened(_ key: String, as keyType: String?) throws -> RedisOperation {
        let command = RedisKeyTreeCommand.openKey(key, keyType: keyType, inDatabase: 4)
        guard case .inDatabase(4, let operation) = try RedisCommandParser.parse(command) else {
            Issue.record("Expected a read in database 4 for \(key)")
            return .command(args: [])
        }
        return operation
    }

    @Test("Opening a key reads exactly that key, whatever it holds", arguments: keys)
    func openedKeyRoundTrips(key: String) throws {
        let expected = Data(key.utf8)

        guard case .get(let getKey) = try opened(key, as: "string") else {
            Issue.record("Expected GET for \(key)")
            return
        }
        #expect(Data(getKey.utf8) == expected)

        guard case .hgetall(let hashKey) = try opened(key, as: "hash") else {
            Issue.record("Expected HGETALL for \(key)")
            return
        }
        #expect(Data(hashKey.utf8) == expected)

        guard case .lrange(let listKey, let start, let stop) = try opened(key, as: "list") else {
            Issue.record("Expected LRANGE for \(key)")
            return
        }
        #expect(Data(listKey.utf8) == expected)
        #expect(start == 0)
        #expect(stop == -1)

        guard case .smembers(let setKey) = try opened(key, as: "set") else {
            Issue.record("Expected SMEMBERS for \(key)")
            return
        }
        #expect(Data(setKey.utf8) == expected)

        guard case .zrange(let zsetKey, _, _, let flags) = try opened(key, as: "zset") else {
            Issue.record("Expected ZRANGE for \(key)")
            return
        }
        #expect(Data(zsetKey.utf8) == expected)
        #expect(flags == ["WITHSCORES"])

        guard case .xrange(let streamKey, _, _, let count) = try opened(key, as: "STREAM") else {
            Issue.record("Expected XRANGE for \(key)")
            return
        }
        #expect(Data(streamKey.utf8) == expected)
        #expect(count == nil)
    }

    @Test("A key of unknown type is opened with GET")
    func unknownTypeOpensWithGet() throws {
        guard case .get(let key) = try opened("k", as: nil) else {
            Issue.record("Expected GET")
            return
        }
        #expect(key == "k")
    }
}
