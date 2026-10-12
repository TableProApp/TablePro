//
//  RedisDatabaseListingTests.swift
//  TableProTests
//
//  ElastiCache and Azure remove CONFIG and Memorystore denies it, so `CONFIG GET databases` was
//  answered with an error that the sidebar reported instead of listing the databases (#3036).
//  The replies here are the ones redis-server 8.10.1 sends, measured with `--rename-command
//  CONFIG ''`, an ACL user without `config|get` or `info`, and `--databases 32`.
//

import Foundation
import TableProPluginKit
import Testing

private struct TransportFailure: Error, Equatable {}

struct RedisMetadataReadTests {
    static let declined: [String] = [
        "ERR unknown command 'CONFIG', with args beginning with: 'GET' 'databases' ",
        "NOPERM User app has no permissions to run the 'config|get' command",
        "NOPERM User app has no permissions to run the 'info' command",
        "ERR Can't execute 'config|get': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context",
        "err lowercase class",
    ]

    @Test("Removed, unknown and ACL-denied commands are declined", arguments: declined)
    func declinedClasses(message: String) {
        #expect(RedisMetadataRead.declinedClass(of: .error(message)) != nil)
    }

    static let surfaced: [String] = [
        "BUSY Redis is busy running a script. You can only call SCRIPT KILL or FUNCTION KILL.",
        "NOAUTH Authentication required.",
        "LOADING Redis is loading the dataset in memory",
        "MASTERDOWN Link with MASTER is down and replica-serve-stale-data is set to 'no'.",
        "NOPERMX not the NOPERM class",
        "ERRX not the ERR class",
        "",
    ]

    @Test("Transient states and other classes are not declined", arguments: surfaced)
    func surfacedClasses(message: String) {
        #expect(RedisMetadataRead.declinedClass(of: .error(message)) == nil)
    }

    @Test("A reply that is not an error is never declined")
    func nonErrorsAreNotDeclined() {
        #expect(RedisMetadataRead.declinedClass(of: .status("QUEUED")) == nil)
        #expect(RedisMetadataRead.declinedClass(of: .array([])) == nil)
        #expect(RedisMetadataRead.declinedClass(of: .null) == nil)
    }
}

struct RedisCommandChannelMetadataReadTests {
    @Test("A declined read answers nil instead of throwing")
    func declinedReadIsNil() async throws {
        let channel = StubRedisChannel([.error("ERR unknown command 'CONFIG'")])
        #expect(try await channel.runMetadataRead(["CONFIG", "GET", "databases"]) == nil)
    }

    @Test("A busy server throws, labelled with the command")
    func busyThrows() async throws {
        let channel = StubRedisChannel([.error("BUSY Redis is busy running a script.")])
        do {
            _ = try await channel.runMetadataRead(["CONFIG", "GET", "databases"])
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message == "CONFIG: BUSY Redis is busy running a script.")
        }
    }

    /// Declining a read sent into the user's open block would report a healthy list over a
    /// transaction the read has just joined.
    @Test("A queued acknowledgement throws rather than reading as declined")
    func queuedThrows() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "INFO")) {
            try await channel.runMetadataRead(["INFO", "keyspace"])
        }
    }

    @Test("A transport failure propagates untouched")
    func transportFailurePropagates() async throws {
        let channel = StubRedisChannel(outcomes: [.failure(TransportFailure())])
        await #expect(throws: TransportFailure()) {
            try await channel.runMetadataRead(["CONFIG", "GET", "databases"])
        }
    }

    @Test("An answer passes through unchanged")
    func answerPassesThrough() async throws {
        let channel = StubRedisChannel([.string("# Keyspace\r\ndb0:keys=1\r\n")])
        #expect(try await channel.runMetadataRead(["INFO", "keyspace"])?.stringValue == "# Keyspace\r\ndb0:keys=1\r\n")
    }
}

struct RedisDatabaseCountTests {
    @Test("Reads the count out of CONFIG GET databases")
    func readsReportedCount() {
        #expect(RedisDatabaseCount.reported(by: .array([.string("databases"), .string("16")])) == 16)
        #expect(RedisDatabaseCount.reported(by: .array([.string("databases"), .string("40")])) == 40)
        #expect(RedisDatabaseCount.reported(by: .array([.string("databases"), .string("1")])) == 1)
    }

    static let unusable: [RedisReply] = [
        .array([.string("databases"), .string("0")]),
        .array([.string("databases"), .string("-1")]),
        .array([.string("databases"), .string("many")]),
        .array([.string("databases"), .string("4294967296")]),
        .array([.string("databases")]),
        .array([]),
        .null,
        .string("16"),
    ]

    @Test("A reply that names no usable count reports none", arguments: unusable)
    func unusableReplies(reply: RedisReply) {
        #expect(RedisDatabaseCount.reported(by: reply) == nil)
    }

    @Test("The server's own count wins over the keyspace and the session")
    func reportedWins() {
        #expect(RedisDatabaseCount.resolve(reported: 16, keyspace: [39: 1], currentDatabase: 20) == 16)
    }

    @Test("Without a count or a keyspace the default of 16 stands")
    func assumesSixteen() {
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: nil, currentDatabase: 0) == 16)
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [0: 5, 3: 1], currentDatabase: 0) == 16)
    }

    @Test("A populated database past 15 widens the count to include it")
    func keyspaceWidens() {
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [0: 1, 20: 1], currentDatabase: 0) == 21)
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [16: 1], currentDatabase: 0) == 17)
    }

    @Test("The database the session is on is always listed")
    func currentDatabaseWidens() {
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: nil, currentDatabase: 20) == 21)
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [:], currentDatabase: 40) == 41)
    }

    /// Measured: Valkey 9.1.2 answers `cluster-databases 16` when the setting is 16, Redis 8.10.1
    /// answers an empty list for a setting it does not have.
    @Test("A cluster serves the fewest databases any primary reports")
    func servedByClusterTakesTheFewest() {
        let sixteen = RedisReply.array([.string("cluster-databases"), .string("16")])
        let eight = RedisReply.array([.string("cluster-databases"), .string("8")])
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [sixteen, eight]) == 8)
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [sixteen, sixteen]) == 16)
    }

    @Test("A cluster no primary vouches for serves database 0 alone")
    func servedByClusterDefaultsToOne() {
        let four = RedisReply.array([.string("cluster-databases"), .string("4")])
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [.array([]), .array([])]) == 1)
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [nil, four]) == 4)
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [nil, nil]) == 1)
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: []) == 1)
        let zero = RedisReply.array([.string("cluster-databases"), .string("0")])
        let word = RedisReply.array([.string("cluster-databases"), .string("many")])
        #expect(RedisDatabaseCount.servedByCluster(primaryReplies: [zero, word, four]) == 4)
    }

    @Test("An index past Int32 cannot overflow the count")
    func boundsHugeIndices() {
        let huge = Int(Int32.max)
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [huge: 1, Int.max: 1], currentDatabase: 0) == 16)
        #expect(RedisDatabaseCount.resolve(reported: nil, keyspace: [huge - 1: 1], currentDatabase: 0) == huge)
    }
}

struct RedisDatabaseListingTests {
    private static let removedConfig = RedisReply.error(
        "ERR unknown command 'CONFIG', with args beginning with: 'GET' 'databases' "
    )
    private static let deniedInfo = RedisReply.error("NOPERM User app has no permissions to run the 'info' command")

    @Test("A removed CONFIG lists 16 databases with their key counts")
    func removedConfigFallsBack() async throws {
        let channel = StubRedisChannel([Self.removedConfig, .string("# Keyspace\r\ndb0:keys=3,expires=0\r\n")])
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 16)
        #expect(listing.keyCount(forDatabase: 0) == 3)
        #expect(listing.keyCount(forDatabase: 5) == 0)
        #expect(channel.sentCommands == [["CONFIG", "GET", "databases"], ["INFO", "keyspace"]])
    }

    @Test("A removed CONFIG on a server with keys in db20 lists through db20")
    func removedConfigWidensToKeyspace() async throws {
        let channel = StubRedisChannel([Self.removedConfig, .string("# Keyspace\r\ndb0:keys=1\r\ndb20:keys=1\r\n")])
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 21)
        #expect(listing.keyCount(forDatabase: 20) == 1)
    }

    @Test("An ACL user refused both CONFIG and INFO gets 16 databases with unknown counts")
    func bothDeclined() async throws {
        let channel = StubRedisChannel([
            .error("NOPERM User app has no permissions to run the 'config|get' command"),
            Self.deniedInfo,
        ])
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 16)
        #expect(listing.keyCounts == nil)
        #expect(listing.keyCount(forDatabase: 0) == nil)
    }

    @Test("A refused INFO leaves the reported count and unknown key counts")
    func infoDeclinedKeepsReportedCount() async throws {
        let channel = StubRedisChannel([.array([.string("databases"), .string("40")]), Self.deniedInfo])
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 40)
        #expect(listing.keyCount(forDatabase: 0) == nil)
    }

    @Test("A reported count needs no keyspace when key counts are not wanted")
    func reportedCountSkipsInfo() async throws {
        let channel = StubRedisChannel([.array([.string("databases"), .string("16")])])
        let listing = try await channel.databaseListing(includingKeyCounts: false)
        #expect(listing.databaseCount == 16)
        #expect(listing.keyCounts == nil)
        #expect(channel.sentCommands == [["CONFIG", "GET", "databases"]])
    }

    /// The database list and the sidebar have to agree, so the list reads the keyspace whenever
    /// the count depends on it.
    @Test("A removed CONFIG reads the keyspace for the count even without key counts")
    func removedConfigReadsKeyspaceForTheCount() async throws {
        let channel = StubRedisChannel([Self.removedConfig, .string("# Keyspace\r\ndb31:keys=2\r\n")])
        let listing = try await channel.databaseListing(includingKeyCounts: false)
        #expect(listing.databaseCount == 32)
        #expect(listing.keyCounts == nil)
    }

    @Test("The session's own database is listed when nothing else names it")
    func currentDatabaseIsListed() async throws {
        let channel = StubRedisChannel([Self.removedConfig, Self.deniedInfo], currentDatabase: 24)
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 25)
    }

    @Test("A busy server fails the listing instead of guessing")
    func busyFails() async throws {
        let channel = StubRedisChannel([.error("BUSY Redis is busy running a script.")])
        await #expect(throws: RedisPluginError.self) {
            try await channel.databaseListing(includingKeyCounts: true)
        }
    }

    @Test("An open MULTI block fails the listing with the queued error")
    func queuedFails() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        await #expect(throws: RedisQueuedCommand(command: "CONFIG")) {
            try await channel.databaseListing(includingKeyCounts: true)
        }
    }

    @Test("A dropped connection fails the listing")
    func transportFailureFails() async throws {
        let channel = StubRedisChannel(outcomes: [.success(Self.removedConfig), .failure(TransportFailure())])
        await #expect(throws: TransportFailure()) {
            try await channel.databaseListing(includingKeyCounts: true)
        }
    }

    @Test("A declined keyspace is unknown, an answered one is a map")
    func keyCountsByDatabase() async throws {
        let declined = StubRedisChannel([Self.deniedInfo])
        #expect(try await declined.keyCountsByDatabase() == nil)

        let answered = StubRedisChannel([.string("# Keyspace\r\ndb3:keys=7\r\n")])
        #expect(try await answered.keyCountsByDatabase() == [3: 7])
    }
}

/// A cluster answers `INFO` from one master, so its one keyspace is counted with `DBSIZE`, which
/// every master answers and the channel sums. Measured on a two-master redis-server 8.10.1
/// cluster with `-dbsize` on one master, and with that master busy running a script: both used
/// to report the other master's count as the whole keyspace.
struct RedisClusterDatabaseListingTests {
    @Test("A cluster lists one database and counts its keys with DBSIZE")
    func countsWithDbsize() async throws {
        let channel = StubRedisChannel([.integer(21)], supportsDatabaseSelection: false)
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 1)
        #expect(listing.keyCount(forDatabase: 0) == 21)
        #expect(channel.sentCommands == [["DBSIZE"]])
        #expect(channel.sentScopes == [.outsideBlock])
    }

    @Test("A cluster listing without key counts asks nothing")
    func withoutCountsAsksNothing() async throws {
        let channel = StubRedisChannel([], supportsDatabaseSelection: false)
        let listing = try await channel.databaseListing(includingKeyCounts: false)
        #expect(listing.databaseCount == 1)
        #expect(listing.keyCounts == nil)
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("A master that declines DBSIZE leaves the count unknown rather than short")
    func declinedIsUnknown() async throws {
        let channel = StubRedisChannel(
            [.error("NOPERM User counter has no permissions to run the 'dbsize' command")],
            supportsDatabaseSelection: false
        )
        let listing = try await channel.databaseListing(includingKeyCounts: true)
        #expect(listing.databaseCount == 1)
        #expect(listing.keyCount(forDatabase: 0) == nil)
    }

    @Test("A master still loading fails the listing instead of reporting a short count")
    func loadingThrows() async throws {
        let channel = StubRedisChannel(
            [.error("LOADING Redis is loading the dataset in memory")],
            supportsDatabaseSelection: false
        )
        do {
            _ = try await channel.databaseListing(includingKeyCounts: true)
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message == "DBSIZE: LOADING Redis is loading the dataset in memory")
        }
    }

    @Test("A queued DBSIZE throws instead of counting the acknowledgement")
    func queuedThrows() async throws {
        let channel = StubRedisChannel([.status("QUEUED")], supportsDatabaseSelection: false)
        await #expect(throws: RedisQueuedCommand(command: "DBSIZE")) {
            try await channel.databaseListing(includingKeyCounts: true)
        }
    }

    @Test("The key counts of a cluster are database 0's")
    func keyCountsByDatabase() async throws {
        let channel = StubRedisChannel([.integer(9)], supportsDatabaseSelection: false)
        #expect(try await channel.keyCountsByDatabase() == [0: 9])
        #expect(channel.sentCommands == [["DBSIZE"]])
    }
}
