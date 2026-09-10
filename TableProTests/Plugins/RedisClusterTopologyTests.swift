//
//  RedisClusterTopologyTests.swift
//  TableProTests
//
//  Reply shapes copied from CLUSTER SHARDS and CLUSTER SLOTS on a live Redis 8.10.1 cluster.
//

import Foundation
import Testing

private func shardsReply() -> RedisReply {
    func node(id: String, port: Int, role: String, health: String = "online") -> RedisReply {
        .array([
            .string("id"), .string(id),
            .string("port"), .integer(Int64(port)),
            .string("ip"), .string("127.0.0.1"),
            .string("endpoint"), .string("127.0.0.1"),
            .string("role"), .string(role),
            .string("health"), .string(health),
        ])
    }
    return .array([
        .array([
            .string("slots"), .array([.integer(0), .integer(5_460)]),
            .string("nodes"), .array([
                node(id: "a1", port: 7_101, role: "master"),
                node(id: "b1", port: 7_104, role: "replica"),
            ]),
        ]),
        .array([
            .string("slots"), .array([.integer(5_461), .integer(16_383)]),
            .string("nodes"), .array([node(id: "a2", port: 7_102, role: "master")]),
        ]),
    ])
}

private func slotsReply() -> RedisReply {
    .array([
        .array([
            .integer(0), .integer(5_460),
            .array([.string("127.0.0.1"), .integer(7_101), .string("a1"), .array([])]),
            .array([.string("127.0.0.1"), .integer(7_104), .string("b1"), .array([])]),
        ]),
        .array([
            .integer(5_461), .integer(16_383),
            .array([.string("127.0.0.1"), .integer(7_102), .string("a2"), .array([])]),
        ]),
    ])
}

@Suite("Redis cluster topology - CLUSTER SHARDS")
struct RedisClusterShardsParsingTests {
    @Test("Reads both shards with their primaries")
    func parsesShards() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        #expect(topology.shards.count == 2)
        #expect(topology.masters.map(\.address.port).sorted() == [7_101, 7_102])
    }

    @Test("Keeps replicas apart from primaries")
    func separatesReplicas() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        #expect(topology.allNodes.count == 3)
        #expect(topology.allNodes.filter(\.isReplica).map(\.address.port) == [7_104])
    }

    @Test("Maps a slot to the primary that serves it")
    func mapsSlots() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        #expect(topology.master(forSlot: 0)?.address.port == 7_101)
        #expect(topology.master(forSlot: 5_460)?.address.port == 7_101)
        #expect(topology.master(forSlot: 5_461)?.address.port == 7_102)
        #expect(topology.master(forSlot: 16_383)?.address.port == 7_102)
    }

    @Test("Full coverage is recognised")
    func recognisesFullCoverage() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        #expect(topology.coversAllSlots)
    }

    @Test("An unhealthy node is marked rather than dropped")
    func marksHealth() throws {
        let reply = RedisReply.array([
            .array([
                .string("slots"), .array([.integer(0), .integer(16_383)]),
                .string("nodes"), .array([
                    .array([
                        .string("id"), .string("a1"), .string("port"), .integer(7_101),
                        .string("endpoint"), .string("127.0.0.1"), .string("role"), .string("master"),
                        .string("health"), .string("failed"),
                    ]),
                ]),
            ]),
        ])
        let topology = try #require(RedisClusterTopologyParser.parseShards(reply, fallbackHost: "seed"))
        #expect(topology.masters.first?.isHealthy == false)
    }

    @Test("An empty endpoint falls back to the node that answered")
    func emptyEndpointFallsBack() throws {
        let reply = RedisReply.array([
            .array([
                .string("slots"), .array([.integer(0), .integer(16_383)]),
                .string("nodes"), .array([
                    .array([
                        .string("id"), .string("a1"), .string("port"), .integer(7_101),
                        .string("endpoint"), .string(""), .string("ip"), .string(""),
                        .string("role"), .string("master"),
                    ]),
                ]),
            ]),
        ])
        let topology = try #require(RedisClusterTopologyParser.parseShards(reply, fallbackHost: "10.0.0.5"))
        #expect(topology.masters.first?.address == RedisNodeAddress(host: "10.0.0.5", port: 7_101))
    }
}

@Suite("Redis cluster topology - CLUSTER SLOTS")
struct RedisClusterSlotsParsingTests {
    @Test("Reads the same picture as CLUSTER SHARDS")
    func matchesShards() throws {
        let fromSlots = try #require(RedisClusterTopologyParser.parseSlots(slotsReply(), fallbackHost: "seed"))
        let fromShards = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        let slotsPorts: [Int] = fromSlots.masters.map(\.address.port).sorted()
        let shardsPorts: [Int] = fromShards.masters.map(\.address.port).sorted()
        #expect(slotsPorts == shardsPorts)
    }

    @Test("The first node of a range is the primary and the rest are replicas")
    func firstNodeIsPrimary() throws {
        let topology = try #require(RedisClusterTopologyParser.parseSlots(slotsReply(), fallbackHost: "seed"))
        #expect(topology.master(forSlot: 100)?.address.port == 7_101)
        #expect(topology.allNodes.filter(\.isReplica).map(\.address.port) == [7_104])
    }

    @Test("A `?` host falls back to the node that answered")
    func unknownHostFallsBack() throws {
        let reply = RedisReply.array([
            .array([
                .integer(0), .integer(16_383),
                .array([.string("?"), .integer(7_101), .string("a1")]),
            ]),
        ])
        let topology = try #require(RedisClusterTopologyParser.parseSlots(reply, fallbackHost: "10.0.0.7"))
        #expect(topology.masters.first?.address.host == "10.0.0.7")
    }

    @Test("An empty reply is not a topology")
    func rejectsEmpty() {
        #expect(RedisClusterTopologyParser.parseSlots(.array([]), fallbackHost: "seed") == nil)
        #expect(RedisClusterTopologyParser.parseShards(.array([]), fallbackHost: "seed") == nil)
    }

    @Test("An error reply is not a topology")
    func rejectsError() {
        let error = RedisReply.error("ERR This instance has cluster support disabled")
        #expect(RedisClusterTopologyParser.parseSlots(error, fallbackHost: "seed") == nil)
        #expect(RedisClusterTopologyParser.parseShards(error, fallbackHost: "seed") == nil)
    }
}

@Suite("Redis cluster topology - slot migration")
struct RedisClusterTopologyMigrationTests {
    @Test("Moving a slot re-points it without a full reload")
    func movesOneSlot() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        let target = RedisNodeAddress(host: "127.0.0.1", port: 7_102)
        let moved = topology.movingSlot(100, to: target)
        #expect(moved.master(forSlot: 100)?.address == target)
    }

    @Test("Its neighbours keep their owner")
    func leavesNeighboursAlone() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        let moved = topology.movingSlot(100, to: RedisNodeAddress(host: "127.0.0.1", port: 7_102))
        #expect(moved.master(forSlot: 99)?.address.port == 7_101)
        #expect(moved.master(forSlot: 101)?.address.port == 7_101)
    }

    @Test("Every slot still has exactly one owner after a move")
    func coverageSurvives() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        let moved = topology.movingSlot(100, to: RedisNodeAddress(host: "127.0.0.1", port: 7_102))
        #expect(moved.coversAllSlots)
    }

    @Test("Moving to an address outside the topology changes nothing")
    func ignoresUnknownTarget() throws {
        let topology = try #require(RedisClusterTopologyParser.parseShards(shardsReply(), fallbackHost: "seed"))
        let moved = topology.movingSlot(100, to: RedisNodeAddress(host: "10.9.9.9", port: 1))
        #expect(moved == topology)
    }
}
