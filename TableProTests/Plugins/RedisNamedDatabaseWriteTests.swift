//
//  RedisNamedDatabaseWriteTests.swift
//  TableProTests
//
//  A grid save on a cluster cannot wrap its writes in MULTI, so a SELECT sent ahead of them stayed
//  in force when one failed, and every command after it ran on the row's database. Each write
//  names its database instead, as `DB <index> <command>`, and the session never leaves home.
//

import Foundation
import TableProPluginKit
import Testing

struct RedisDatabasePrefixParsingTests {
    @Test("DB names the database a command runs on, as an index or as the sidebar spells it")
    func parsesDatabaseAndCommand() throws {
        guard case .inDatabase(let database, let operation) = try RedisCommandParser.parse("DB 3 SET \"k\" \"v\""),
              case .set(let key, let value, _) = operation else {
            Issue.record("Expected a SET run in a named database")
            return
        }
        #expect(database == 3)
        #expect(key == "k")
        #expect(value == Data("v".utf8))

        guard case .inDatabase(let spelled, .del(let keys)) = try RedisCommandParser.parse("db db12 DEL a b") else {
            Issue.record("Expected a DEL run in a named database")
            return
        }
        #expect(spelled == 12)
        #expect(keys == ["a", "b"])
    }

    static let invalid = ["DB", "DB 3", "DB x GET k", "DB -1 GET k", "DB dbx GET k"]

    @Test("A DB with no database or no command is refused", arguments: invalid)
    func rejectsIncomplete(command: String) {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse(command)
        }
    }

    @Test("A command the user queued reports the acknowledgement, and a walk the app built refuses it")
    func queuedAnswerFollowsTheCommand() throws {
        #expect(try RedisCommandParser.parse("DB 2 SET k v").queuedCommandAnswer == .reportQueued)
        #expect(try RedisCommandParser.parse("DB 2 KEYBROWSE LIMIT 10").queuedCommandAnswer == .refuse)
    }
}

struct RedisNamedDatabaseAddressingTests {
    private static let writes = [
        PluginRowWrite(statement: "SET \"k\" \"v\"", rowIndices: [0]),
        PluginRowWrite(statement: "DEL old", rowIndices: [1, 2]),
    ]

    @Test("Without a transaction every write names the database and no SELECT is sent")
    func namesEachWrite() {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 3, from: 0, insideTransaction: false)
        #expect(addressed.map(\.statement) == ["DB 3 SET \"k\" \"v\"", "DB 3 DEL old"])
        #expect(addressed.map(\.rowIndices) == [[0], [1, 2]])
    }

    @Test("Writes for the database the session belongs on are unchanged")
    func homeDatabaseUnchanged() {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 0, from: 0, insideTransaction: false)
        #expect(addressed.map(\.statement) == Self.writes.map(\.statement))
    }

    /// The statements go through the parser a save runs every statement through, so each must
    /// come back as the write it wraps, in the database it names.
    @Test("Every named write parses back to its database and command")
    func namedWritesParse() throws {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 3, from: 0, insideTransaction: false)
        for statement in addressed {
            guard case .inDatabase(let database, _) = try RedisCommandParser.parse(statement.statement) else {
                Issue.record("Expected \(statement.statement) to name its database")
                continue
            }
            #expect(database == 3)
        }
    }

    @Test("A write whose SELECT failed on the session leaves it where it belongs")
    func failedWriteStaysHome() async throws {
        let channel = StubRedisChannel([.status("OK"), .error("NOPERM No permissions to access a key"), .status("OK")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.withDatabase(3) { try await channel.run(["SET", "k", "v"]) }
        }
        #expect(channel.homeDatabase() == 0)
        #expect(channel.currentDatabase() == 0)
        #expect(channel.sentCommands == [["SELECT", "3"], ["SET", "k", "v"], ["SELECT", "0"]])
    }
}
