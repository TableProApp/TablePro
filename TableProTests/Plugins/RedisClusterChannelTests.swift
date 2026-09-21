//
//  RedisClusterChannelTests.swift
//  TableProTests
//
//  The real cluster channel over two scripted primaries: 127.0.0.1:7000 owns slots 0-8191 and
//  127.0.0.1:7001 owns 8192-16383. Key `b` hashes to slot 3300 and `a` to 15495; `forbidden:1`
//  to 5435 and `allowed:1` to 8225, which is how the ACL cases split across the two.
//

import Foundation
import TableProPluginKit
import Testing

private func entry(
    _ name: String,
    flags: [String] = [],
    tips: [String] = [],
    subcommands: [RedisReply] = []
) -> RedisReply {
    .array([
        .string(name), .integer(-1), .array(flags.map { RedisReply.status($0) }),
        .integer(0), .integer(0), .integer(0),
        .array([]), .array(tips.map { RedisReply.string($0) }), .array([]), .array(subcommands),
    ])
}

private let keyRefusal = "NOPERM No permissions to access a key"

@Suite("Redis cluster channel - how far a command goes")
struct RedisClusterDispatchTests {
    @Test("CONFIG SET goes to every node")
    func configSetReachesEveryNode() async throws {
        let cluster = try await StubRedisCluster.connect(
            first: [.success(.status("OK"))],
            second: [.success(.status("OK"))]
        )
        let reply = try await cluster.channel.executeCommand(["CONFIG", "SET", "maxmemory", "0"], scope: .session)
        #expect(reply.stringValue == "OK")
        #expect(cluster.first.sentCommands == [["CONFIG", "SET", "maxmemory", "0"]])
        #expect(cluster.second.sentCommands == [["CONFIG", "SET", "maxmemory", "0"]])
    }

    @Test("DBSIZE goes to every primary and the counts add up")
    func dbsizeSums() async throws {
        let cluster = try await StubRedisCluster.connect(first: [.success(.integer(2))], second: [.success(.integer(3))])
        #expect(try await cluster.channel.executeCommand(["DBSIZE"], scope: .session).intValue == 5)
    }

    /// Before the parser keyed a subcommand by the name Redis reports, `function|load` was filed
    /// as `function|function|load`, so FUNCTION LOAD reached one primary and the library was
    /// missing on the rest.
    @Test("A subcommand the server tips all_shards reaches every primary")
    func serverTippedSubcommandFansOut() async throws {
        let command = RedisReply.array([
            entry("function", subcommands: [
                entry("function|load", flags: ["write", "denyoom", "noscript"],
                      tips: ["request_policy:all_shards", "response_policy:all_succeeded"]),
            ]),
        ])
        let cluster = try await StubRedisCluster.connect(
            command: command,
            first: [.success(.string("lib"))],
            second: [.success(.string("lib"))]
        )
        let reply = try await cluster.channel.executeCommand(["FUNCTION", "LOAD", "#!lua name=lib"], scope: .session)
        #expect(reply.stringValue == "lib")
        #expect(cluster.first.sentCommands == [["FUNCTION", "LOAD", "#!lua name=lib"]])
        #expect(cluster.second.sentCommands == [["FUNCTION", "LOAD", "#!lua name=lib"]])
    }

    @Test("A command tipped all_nodes with a special response goes to one node")
    func specialResponseGoesToOneNode() async throws {
        let command = RedisReply.array([
            entry("latency", subcommands: [
                entry("latency|doctor", flags: ["admin", "noscript", "loading", "stale"],
                      tips: ["nondeterministic_output", "request_policy:all_nodes", "response_policy:special"]),
            ]),
        ])
        let cluster = try await StubRedisCluster.connect(command: command, first: [.success(.string("report"))])
        let reply = try await cluster.channel.executeCommand(["LATENCY", "DOCTOR"], scope: .session)
        #expect(reply.stringValue == "report")
        #expect(cluster.first.sentCommands == [["LATENCY", "DOCTOR"]])
        #expect(cluster.second.sentCommands.isEmpty)
    }

    @Test("A multi-key DEL is split by slot and the counts add up")
    func delSplitsBySlot() async throws {
        let cluster = try await StubRedisCluster.connect(first: [.success(.integer(1))], second: [.success(.integer(1))])
        #expect(try await cluster.channel.executeCommand(["DEL", "a", "b"], scope: .session).intValue == 2)
        #expect(cluster.second.sentCommands == [["DEL", "a"]])
        #expect(cluster.first.sentCommands == [["DEL", "b"]])
    }
}

@Suite("Redis cluster channel - a split write only some shards applied")
struct RedisClusterPartialWriteTests {
    @Test("A split DEL one shard refused names the keys the other already deleted")
    func refusedPart() async throws {
        let cluster = try await StubRedisCluster.connect(
            first: [.success(.error(keyRefusal))],
            second: [.success(.integer(1))]
        )
        do {
            _ = try await cluster.channel.executeCommand(["DEL", "allowed:1", "forbidden:1"], scope: .session)
            Issue.record("expected a partial write")
        } catch let partial as RedisPartialClusterWrite {
            #expect(partial.parts == [
                RedisShardPart(node: "127.0.0.1:7001", keys: [Data("allowed:1".utf8)], outcome: .ran),
                RedisShardPart(node: "127.0.0.1:7000", keys: [Data("forbidden:1".utf8)], outcome: .refused(keyRefusal)),
            ])
            #expect(partial.pluginErrorMessage == "DEL: \(keyRefusal)")
        }
    }

    @Test("A split read one shard refused answers with the refusal, since nothing changed")
    func refusedRead() async throws {
        let cluster = try await StubRedisCluster.connect(
            first: [.success(.error(keyRefusal))],
            second: [.success(.integer(1))]
        )
        let reply = try await cluster.channel.executeCommand(["EXISTS", "allowed:1", "forbidden:1"], scope: .session)
        #expect(reply.errorMessage == keyRefusal)
    }

    @Test("A send that fails after one part ran reports the part that ran")
    func interruptedPart() async throws {
        let dropped = RedisTransportFailure(code: -1, message: "No reply from Redis", wasDelivered: true)
        let cluster = try await StubRedisCluster.connect(
            first: [.failure(dropped)],
            second: [.success(.integer(1))]
        )
        do {
            _ = try await cluster.channel.executeCommand(["DEL", "a", "b"], scope: .session)
            Issue.record("expected a partial write")
        } catch let partial as RedisPartialClusterWrite {
            #expect(partial.parts.map(\.outcome) == [.ran, .interrupted("No reply from Redis")])
        }
    }

    @Test("A FLUSHDB one primary refused names the primary that flushed")
    func refusedBroadcast() async throws {
        let cluster = try await StubRedisCluster.connect(
            first: [.success(.error("NOPERM User limited has no permissions to run the 'flushdb' command"))],
            second: [.success(.status("OK"))]
        )
        do {
            _ = try await cluster.channel.executeCommand(["FLUSHDB"], scope: .session)
            Issue.record("expected a partial write")
        } catch let partial as RedisPartialClusterWrite {
            #expect(partial.pluginErrorDetail?.hasSuffix("Nodes it ran on: 127.0.0.1:7001") == true)
        }
    }

    /// The owner of every part is looked up before the first is sent. Looking it up in the loop
    /// deleted `b` and then failed on `a`, with nothing to say that `b` was gone.
    @Test("A slot with no owner stops a split command before any part is sent")
    func missingOwnerSendsNothing() async throws {
        let firstHalfOnly = RedisReply.array([
            .array([.integer(0), .integer(8_191), .array([.string("127.0.0.1"), .integer(7_000), .string("node-a")])]),
        ])
        let cluster = try await StubRedisCluster.connect(slots: firstHalfOnly, first: [.success(.integer(1))])
        await #expect(throws: RedisPluginError.self) {
            try await cluster.channel.executeCommand(["DEL", "b", "a"], scope: .session)
        }
        #expect(cluster.first.sentCommands.isEmpty)
    }
}

@Suite("Redis cluster channel - numbered databases")
struct RedisClusterDatabaseSelectionTests {
    private static let sixteen = (StubRedisCluster.servedDatabases(16), StubRedisCluster.servedDatabases(16))

    @Test("Primaries that serve 16 databases list 16 and allow selecting them")
    func servedDatabasesAreListed() async throws {
        let cluster = try await StubRedisCluster.connect(clusterDatabases: Self.sixteen)
        #expect(cluster.channel.supportsDatabaseSelection)
        let listing = try await cluster.channel.databaseListing(includingKeyCounts: false)
        #expect(listing.databaseCount == 16)
        #expect(cluster.first.sentCommands.isEmpty)
        #expect(cluster.second.sentCommands.isEmpty)
    }

    @Test("The fewest databases any primary serves is the count")
    func fewestWins() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: (StubRedisCluster.servedDatabases(16), StubRedisCluster.servedDatabases(8))
        )
        #expect(try await cluster.channel.reportedDatabaseCount() == 8)
    }

    /// Redis OSS answers `CONFIG GET cluster-databases` with an empty list and refuses SELECT with
    /// any other index, measured on Redis 8.10.1.
    @Test("Redis Cluster keeps one database and refuses another with nothing sent")
    func singleDatabaseRefuses() async throws {
        let cluster = try await StubRedisCluster.connect()
        #expect(!cluster.channel.supportsDatabaseSelection)
        do {
            try await cluster.channel.selectDatabase(3, scope: .session)
            Issue.record("expected a refusal")
        } catch let error as RedisPluginError {
            #expect(error.message == "This cluster serves database 0 only, so it cannot switch databases.")
        }
        await #expect(throws: RedisPluginError.self) {
            try await cluster.channel.withDatabase(3) { try await cluster.channel.executeCommand(["DBSIZE"]) }
        }
        try await cluster.channel.selectDatabase(0, scope: .session)
        #expect(cluster.first.sentCommands.isEmpty)
        #expect(cluster.second.sentCommands.isEmpty)
    }

    @Test("SELECT goes to the first primary alone, and every node follows before its next command")
    func selectMovesEveryNode() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.status("OK")), .success(.integer(2))],
            second: [.success(.status("OK")), .success(.integer(5))]
        )
        try await cluster.channel.selectDatabase(3, scope: .session)
        #expect(cluster.first.sentCommands == [["SELECT", "3"]])
        #expect(cluster.first.sentScopes == [.outsideBlock])
        #expect(cluster.second.sentCommands.isEmpty)
        #expect(cluster.channel.homeDatabase() == 3)

        #expect(try await cluster.channel.executeCommand(["DBSIZE"], scope: .session).intValue == 7)
        #expect(cluster.first.sentCommands == [["SELECT", "3"], ["DBSIZE"]])
        #expect(cluster.second.sentCommands == [["SELECT", "3"], ["DBSIZE"]])
    }

    @Test("A refused SELECT leaves the cluster where it was")
    func refusedSelectStays() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.error("ERR DB index is out of range"))]
        )
        await #expect(throws: RedisPluginError.self) {
            try await cluster.channel.selectDatabase(20, scope: .session)
        }
        #expect(cluster.channel.homeDatabase() == 0)
    }

    /// A SELECT queued into the block would move one primary when EXEC runs and none of the
    /// others, so it is held back rather than sent.
    @Test("A SELECT is held back from a block open on the primary")
    func selectHeldBackFromBlock() async throws {
        let cluster = try await StubRedisCluster.connect(clusterDatabases: Self.sixteen)
        cluster.first.observeOpenBlock()
        await #expect(throws: RedisHeldBackCommand(command: "SELECT", held: .openBlock)) {
            try await cluster.channel.selectDatabase(3, scope: .session)
        }
        #expect(cluster.channel.homeDatabase() == 0)
    }

    @Test("A read on another database visits it on every primary and leaves the cluster home")
    func visitReachesEveryPrimary() async throws {
        let emptyPage = RedisReply.array([.string("0"), .array([])])
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.status("OK")), .success(.array([.string("0"), .array([.string("b")])])),
                    .success(.status("OK")), .success(.integer(1))],
            second: [.success(.status("OK")), .success(emptyPage), .success(.status("OK")), .success(.integer(1))]
        )
        let keys = try await cluster.channel.withDatabase(4) {
            var cursor = RedisClusterCursor.start
            var keys: [String] = []
            repeat {
                let page = try await cluster.channel.scanKeyspace(
                    cursor: cursor, pattern: nil, type: nil, count: 10, scope: .outsideBlock
                )
    /// On a cluster the visit is taken per command, so this is the node's own check. Queued, the
    /// write would run on the home database when EXEC runs.
    @Test("A write on another database is refused on a primary holding an open block")
    func visitRefusedInsideBlock() async throws {
        let cluster = try await StubRedisCluster.connect(clusterDatabases: Self.sixteen)
        cluster.second.observeOpenBlock()
        await #expect(throws: RedisHeldBackCommand(command: "HSET", held: .openBlock)) {
            try await cluster.channel.withDatabase(3) {
                try await cluster.channel.executeCommand(["HSET", "a", "f", "v"], scope: .session)
            }
        }
        #expect(cluster.second.sentCommands.isEmpty)
        #expect(cluster.channel.homeDatabase() == 0)
    }

                keys += page.keys
                cursor = page.cursor
            } while cursor != RedisClusterCursor.start
            return keys
        }
        #expect(keys == ["b"])
        #expect(cluster.first.sentCommands == [["SELECT", "4"], ["SCAN", "0", "COUNT", "10"]])
        #expect(cluster.second.sentCommands == [["SELECT", "4"], ["SCAN", "0", "COUNT", "10"]])
        #expect(cluster.channel.homeDatabase() == 0)

        _ = try await cluster.channel.executeCommand(["DBSIZE"], scope: .session)
        #expect(cluster.first.sentCommands.suffix(2) == [["SELECT", "0"], ["DBSIZE"]])
        #expect(cluster.second.sentCommands.suffix(2) == [["SELECT", "0"], ["DBSIZE"]])
    }

    /// ASKING only lasts for the next command, so the visit's SELECT has to go first. Measured on
    /// Valkey 9.1.2: ASKING then SELECT loses the ASKING and the command answers MOVED.
    @Test("An ASK during a visit selects the visited database before ASKING")
    func askDuringVisit() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.status("OK")), .success(.error("ASK 3300 127.0.0.1:7001"))],
            second: [.success(.status("OK")), .success(.status("OK")), .success(.string("v"))]
        )
        let value = try await cluster.channel.withDatabase(4) {
            try await cluster.channel.executeCommand(["GET", "b"], scope: .session).stringValue
        }
        #expect(value == "v")
        #expect(cluster.second.sentCommands == [["SELECT", "4"], ["ASKING"], ["GET", "b"]])
    }

    @Test("Key counts add up each primary's keyspace per database")
    func keyCountsSumPerDatabase() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.string("# Keyspace\r\ndb0:keys=2,expires=0\r\ndb3:keys=1\r\n"))],
            second: [.success(.string("# Keyspace\r\ndb3:keys=4\r\n"))]
        )
        #expect(try await cluster.channel.keyCountsByDatabase() == [0: 2, 3: 5])
        #expect(cluster.first.sentCommands == [["INFO", "keyspace"]])
        #expect(cluster.second.sentCommands == [["INFO", "keyspace"]])
    }

    @Test("A primary that declines its keyspace leaves every count unknown")
    func declinedKeyspaceIsUnknown() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.string("# Keyspace\r\ndb0:keys=2\r\n"))],
            second: [.success(.error("NOPERM User app has no permissions to run the 'info' command"))]
        )
        #expect(try await cluster.channel.keyCountsByDatabase() == nil)
    }

    @Test("A single-database cluster still counts its keys with DBSIZE")
    func singleDatabaseCountsWithDbsize() async throws {
        let cluster = try await StubRedisCluster.connect(first: [.success(.integer(2))], second: [.success(.integer(3))])
        #expect(try await cluster.channel.keyCountsByDatabase() == [0: 5])
        #expect(cluster.first.sentCommands == [["DBSIZE"]])
        #expect(cluster.second.sentCommands == [["DBSIZE"]])
    }

    /// A cluster cannot hold a MULTI across shards, so a grid save names its database on every
    /// write instead of selecting it first. A SELECT sent ahead would have stayed in force when
    /// a write after it failed.
    @Test("A write that names its database and fails leaves the cluster home")
    func namedWriteFailureStaysHome() async throws {
        let cluster = try await StubRedisCluster.connect(
            clusterDatabases: Self.sixteen,
            first: [.success(.status("OK")), .success(.error(keyRefusal)), .success(.status("OK")), .success(.string("v"))]
        )
        await #expect(throws: RedisPluginError.self) {
            try await cluster.channel.withDatabase(3) { try await cluster.channel.run(["SET", "b", "v"]) }
        }
        #expect(cluster.channel.homeDatabase() == 0)
        _ = try await cluster.channel.executeCommand(["GET", "b"], scope: .session)
        #expect(cluster.first.sentCommands == [["SELECT", "3"], ["SET", "b", "v"], ["SELECT", "0"], ["GET", "b"]])
    }
}
