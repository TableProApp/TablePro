//
//  RedisDatabaseTargetTests.swift
//  TableProTests
//
//  A Redis connection reads whichever database its session last selected, and the app names each
//  database as a table. Row counts, statistics and the DDL preview read the session's database
//  whatever row they were asked about, and a tab whose SELECT the server refused went on to show
//  the session's keys under another database's name once it was refreshed.
//

import Foundation
import TableProPluginKit
import Testing

private struct Refused: Error, Equatable {}

@Suite("Redis KEYBROWSE - the database it reads")
struct RedisKeyBrowseDatabaseTests {
    private func database(of command: String) throws -> Int? {
        guard case .keyBrowse(_, _, _, _, let database) = try RedisCommandParser.parse(command) else {
            Issue.record("Expected a keyBrowse operation for \(command)")
            return nil
        }
        return database
    }

    @Test("DB names the database, as an index or as the sidebar spells it")
    func parsesDatabase() throws {
        #expect(try database(of: "KEYBROWSE DB 3 LIMIT 10 OFFSET 0") == 3)
        #expect(try database(of: "KEYBROWSE MATCH a* DB db12") == 12)
        #expect(try database(of: "KEYBROWSE LIMIT 10 OFFSET 0") == nil)
    }

    static let invalid = ["KEYBROWSE DB", "KEYBROWSE DB x", "KEYBROWSE DB -1", "KEYBROWSE DB dbx"]

    @Test("A DB that names no database is refused rather than read as the current one", arguments: invalid)
    func rejectsInvalidDatabase(command: String) {
        #expect(throws: RedisParseError.self) {
            try RedisCommandParser.parse(command)
        }
    }

    @Test("A table's browse and filter queries carry its database through a round trip")
    func builtQueriesRoundTrip() throws {
        let builder = RedisQueryBuilder()
        #expect(try database(of: builder.buildBaseQuery(namespace: "", database: 5)) == 5)
        let filtered = builder.buildFilteredQuery(
            namespace: "", database: 7, filters: [(column: "Key", op: "MATCH", value: "user:*")]
        )
        #expect(try database(of: filtered) == 7)
        guard case .keyBrowse(let pattern, _, _, _, _) = try RedisCommandParser.parse(filtered) else {
            Issue.record("Expected a keyBrowse operation")
            return
        }
        #expect(pattern == "user:*")
        #expect(try database(of: builder.buildBaseQuery(namespace: "")) == nil)
    }

    @Test("An export reads the whole database the row names")
    func exportQuery() {
        let builder = RedisQueryBuilder()
        #expect(builder.buildExportQuery(database: 3) == "KEYBROWSE DB 3")
        #expect(builder.buildExportQuery(database: nil) == "KEYBROWSE")
    }
}

@Suite("Redis command channel - moving to a database")
struct RedisMoveToDatabaseTests {
    /// A read-only ACL user is refused SELECT even for the database it is already on, which made
    /// the first sidebar click on a Redis connection fail for that user.
    @Test("A move to the database the session is on sends nothing")
    func sameDatabaseSendsNothing() async throws {
        let channel = StubRedisChannel([], currentDatabase: 3)
        try await channel.moveToDatabase(3)
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("A move to another database sends SELECT as the app's own command")
    func otherDatabaseSelects() async throws {
        let channel = StubRedisChannel([.status("OK")])
        try await channel.moveToDatabase(4)
        #expect(channel.sentCommands == [["SELECT", "4"]])
        #expect(channel.sentScopes == [.outsideBlock])
        #expect(channel.currentDatabase() == 4)
    }

    /// A SELECT typed into an open block is queued like any other command, so the block's `EXEC`
    /// reply pairs with it, and it moves nothing until `EXEC` runs it.
    @Test("A SELECT queued in a block answers queued and moves nothing yet")
    func queuedSelectMovesNothing() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        channel.observeOpenBlock()
        await #expect(throws: RedisQueuedCommand(command: "SELECT")) {
            try await channel.selectDatabase(6)
        }
        #expect(channel.databaseForNextCommand() == 6)
        #expect(channel.currentDatabase() == 0)
        #expect(channel.homeDatabase() == 0)
    }

    @Test("A move sets where the session belongs, not only where it is")
    func moveSetsHome() async throws {
        let channel = StubRedisChannel([.status("OK")])
        try await channel.moveToDatabase(4)
        #expect(channel.homeDatabase() == 4)
    }

    @Test("A refused SELECT is reported")
    func refusalPropagates() async throws {
        let channel = StubRedisChannel([.error("ERR DB index is out of range")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.moveToDatabase(9)
        }
        #expect(channel.currentDatabase() == 0)
    }
}

@Suite("Redis command channel - a read on another database")
struct RedisWithDatabaseTests {
    @Test("On the session's own database only the read runs")
    func sameDatabaseRunsBodyOnly() async throws {
        let channel = StubRedisChannel([.integer(4)], currentDatabase: 2)
        let count = try await channel.withDatabase(2) { try await channel.executeCommand(["DBSIZE"]).intValue }
        #expect(count == 4)
        #expect(channel.sentCommands == [["DBSIZE"]])
    }

    @Test("No database named reads the session's own")
    func noDatabaseRunsBodyOnly() async throws {
        let channel = StubRedisChannel([.integer(1)])
        _ = try await channel.withDatabase(nil) { try await channel.executeCommand(["DBSIZE"]) }
        #expect(channel.sentCommands == [["DBSIZE"]])
    }

    @Test("Another database is selected for the read and the session is put back")
    func otherDatabaseRoundTrips() async throws {
        let channel = StubRedisChannel([.status("OK"), .integer(9), .status("OK")], currentDatabase: 1)
        let count = try await channel.withDatabase(5) { try await channel.executeCommand(["DBSIZE"]).intValue }
        #expect(count == 9)
        #expect(channel.sentCommands == [["SELECT", "5"], ["DBSIZE"], ["SELECT", "1"]])
        #expect(channel.currentDatabase() == 1)
    }

    @Test("A read that fails still puts the session back")
    func failedReadRestores() async throws {
        let channel = StubRedisChannel(outcomes: [.success(.status("OK")), .failure(Refused()), .success(.status("OK"))])
        await #expect(throws: Refused()) {
            try await channel.withDatabase(5) { try await channel.executeCommand(["DBSIZE"]) }
        }
        #expect(channel.sentCommands.last == ["SELECT", "0"])
        #expect(channel.currentDatabase() == 0)
    }

    @Test("A database the server refuses stops the read before it runs")
    func refusedSelectRunsNothing() async throws {
        let channel = StubRedisChannel([.error("ERR DB index is out of range")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.withDatabase(20) { try await channel.executeCommand(["DBSIZE"]) }
        }
        #expect(channel.sentCommands == [["SELECT", "20"]])
    }
}

@Suite("Redis command channel - one database's key count")
struct RedisKeyCountTests {
    @Test("The session's own database is counted exactly")
    func currentDatabaseUsesDbsize() async throws {
        let channel = StubRedisChannel([.integer(42)], currentDatabase: 3)
        #expect(try await channel.keyCount(inDatabase: 3) == 42)
        #expect(channel.sentCommands == [["DBSIZE"]])
    }

    @Test("Another database is read from INFO keyspace without moving the session")
    func otherDatabaseUsesKeyspace() async throws {
        let channel = StubRedisChannel([.string("# Keyspace\r\ndb0:keys=5\r\ndb3:keys=12\r\n")])
        #expect(try await channel.keyCount(inDatabase: 3) == 12)
        #expect(channel.sentCommands == [["INFO", "keyspace"]])
    }

    @Test("A database the keyspace does not list holds no keys")
    func unlistedDatabaseIsEmpty() async throws {
        let channel = StubRedisChannel([.string("# Keyspace\r\ndb0:keys=5\r\n")])
        #expect(try await channel.keyCount(inDatabase: 8) == 0)
    }

    @Test("A declined count is unknown rather than zero")
    func declinedIsUnknown() async throws {
        let info = StubRedisChannel([.error("NOPERM User u has no permissions to run the 'info' command")])
        #expect(try await info.keyCount(inDatabase: 3) == nil)

        let dbsize = StubRedisChannel([.error("NOPERM User u has no permissions to run the 'dbsize' command")])
        #expect(try await dbsize.keyCount(inDatabase: 0) == nil)
    }

    @Test("A busy server fails the count")
    func busyFails() async throws {
        let channel = StubRedisChannel([.error("BUSY Redis is busy running a script.")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.keyCount(inDatabase: 3)
        }
    }

    @Test("A cluster counts its one database and knows no other")
    func cluster() async throws {
        let only = StubRedisChannel([.integer(7)], supportsDatabaseSelection: false)
        #expect(try await only.keyCount(inDatabase: 0) == 7)

        let other = StubRedisChannel([], supportsDatabaseSelection: false)
        #expect(try await other.keyCount(inDatabase: 3) == nil)
        #expect(other.sentCommands.isEmpty)
    }
}

@Suite("Redis session database - where the session is and where it belongs")
struct RedisSessionDatabaseTests {
    @Test("A selection moves both, a visit moves only where the session is")
    func selectedAndVisited() {
        var database = RedisSessionDatabase(0)
        database.visited(7)
        #expect(database.current == 7)
        #expect(database.home == 0)
        #expect(database.awayFromHome == 0)

        database.selected(3)
        #expect(database.current == 3)
        #expect(database.home == 3)
        #expect(database.awayFromHome == nil)
    }
}

@Suite("Redis command channel - a visit the app abandoned")
struct RedisAbandonedVisitTests {
    /// A cancelled stream lets go of the driver before its return SELECT reaches the server, so
    /// the next command could have run on the database the stream was reading.
    @Test("A command outside a visit goes home before it runs")
    func returnsHomeFirst() async throws {
        let channel = StubRedisChannel([.status("OK"), .status("OK"), .string("v")])
        try await channel.visitDatabase(7)
        let reply = try await channel.executeCommand(["GET", "k"])
        #expect(reply.stringValue == "v")
        #expect(channel.sentCommands == [["SELECT", "7"], ["SELECT", "0"], ["GET", "k"]])
        #expect(channel.currentDatabase() == 0)
    }

    @Test("A command that is part of the visit stays on the visited database")
    func visitStaysAway() async throws {
        let channel = StubRedisChannel([.status("OK"), .integer(3)])
        try await channel.visitDatabase(7)
        let count = try await RedisDatabaseVisit.$database.withValue(7) {
            try await channel.executeCommand(["DBSIZE"]).intValue
        }
        #expect(count == 3)
        #expect(channel.sentCommands == [["SELECT", "7"], ["DBSIZE"]])
    }

    @Test("A read on the database a stale visit left the session on sends no SELECT")
    func staleVisitMatchingIndex() async throws {
        let channel = StubRedisChannel([.status("OK"), .integer(5)])
        try await channel.visitDatabase(7)
        let count = try await channel.withDatabase(7) { try await channel.executeCommand(["DBSIZE"]).intValue }
        #expect(count == 5)
        #expect(channel.sentCommands == [["SELECT", "7"], ["DBSIZE"]])
    }

    @Test("A count for the database the session belongs on is exact even after a stale visit")
    func keyCountAtHome() async throws {
        let channel = StubRedisChannel([.status("OK"), .status("OK"), .integer(11)])
        try await channel.visitDatabase(7)
        #expect(try await channel.keyCount(inDatabase: 0) == 11)
        #expect(channel.sentCommands == [["SELECT", "7"], ["SELECT", "0"], ["DBSIZE"]])
    }
}

@Suite("Redis grid writes - the database they belong to")
struct RedisWriteAddressingTests {
    private static let writes: [RedisDatabaseTarget.Statement] = [
        (statement: "SET \"k\" \"v\"", parameters: []),
        (statement: "DEL \"old\"", parameters: []),
    ]

    @Test("Writes for the database the session belongs on are unchanged")
    func sameDatabase() {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 3, from: 3)
        #expect(addressed.map(\.statement) == Self.writes.map(\.statement))
    }

    @Test("Writes for another database select it first and return afterwards")
    func otherDatabase() {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 3, from: 5)
        #expect(addressed.map(\.statement) == ["SELECT 3", "SET \"k\" \"v\"", "DEL \"old\"", "SELECT 5"])
    }

    @Test("A table that names no database, or no writes, is left alone")
    func nothingToAddress() {
        #expect(RedisDatabaseTarget.addressing(Self.writes, toDatabase: nil, from: 5).count == 2)
        #expect(RedisDatabaseTarget.addressing([], toDatabase: 3, from: 5).isEmpty)
    }

    /// The SELECTs go through the parser a save runs every statement through.
    @Test("Every addressing statement parses as a SELECT")
    func selectsParse() throws {
        let addressed = RedisDatabaseTarget.addressing(Self.writes, toDatabase: 3, from: 5)
        guard case .select(let first) = try RedisCommandParser.parse(addressed[0].statement),
              case .select(let last) = try RedisCommandParser.parse(addressed[3].statement) else {
            Issue.record("Expected SELECT operations")
            return
        }
        #expect(first == 3)
        #expect(last == 5)
    }
}
