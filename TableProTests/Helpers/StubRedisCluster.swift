//
//  StubRedisCluster.swift
//  TableProTests
//
//  The real cluster channel over two scripted stub primaries, for driving its routing, fan-out
//  and database logic without hiredis or a server. The first primary owns slots 0-8191 and the
//  second 8192-16383, the way CLUSTER SLOTS reports a two-master cluster.
//

import Foundation
import TableProPluginKit

struct StubRedisCluster {
    static let firstAddress = RedisNodeAddress(host: "127.0.0.1", port: 7_000)
    static let secondAddress = RedisNodeAddress(host: "127.0.0.1", port: 7_001)

    static let bothPrimaries = RedisReply.array([
        .array([.integer(0), .integer(8_191), .array([.string("127.0.0.1"), .integer(7_000), .string("node-a")])]),
        .array([.integer(8_192), .integer(16_383), .array([.string("127.0.0.1"), .integer(7_001), .string("node-b")])]),
    ])

    /// What Redis OSS answers for a setting it does not have.
    static let noSuchSetting = RedisReply.array([])
    static let commandRefused = RedisReply.error("NOPERM User app has no permissions to run the 'command' command")

    static func servedDatabases(_ count: Int) -> RedisReply {
        .array([.string("cluster-databases"), .string(String(count))])
    }

    let channel: RedisClusterChannel
    let first: StubRedisChannel
    let second: StubRedisChannel

    /// Connects through the seed at 7000, which answers CLUSTER SHARDS with an error, CLUSTER SLOTS
    /// with `slots`, COMMAND with `command` and INFO server, and then both primaries answer
    /// CONFIG GET cluster-databases. The replies after those are the ones each test scripts.
    static func connect(
        slots: RedisReply = bothPrimaries,
        command: RedisReply = commandRefused,
        clusterDatabases: (first: RedisReply, second: RedisReply) = (noSuchSetting, noSuchSetting),
        first firstReplies: [Result<RedisReply, Error>] = [],
        second secondReplies: [Result<RedisReply, Error>] = []
    ) async throws -> StubRedisCluster {
        let connectScript: [RedisReply] = [
            .error("ERR unknown subcommand 'SHARDS'"),
            slots,
            command,
            .string("# Server\r\nredis_version:8.10.1\r\nredis_mode:cluster\r\n"),
            clusterDatabases.first,
        ]
        let first = StubRedisChannel(outcomes: connectScript.map { .success($0) } + firstReplies)
        let second = StubRedisChannel(outcomes: [.success(clusterDatabases.second)] + secondReplies)
        let nodes: [String: StubRedisChannel] = [
            firstAddress.identifier: first,
            secondAddress.identifier: second,
        ]
        let channel = RedisClusterChannel(seeds: [firstAddress]) { address in
            nodes[address.identifier] ?? StubRedisChannel([])
        }
        try await channel.connect()
        first.forgetSentCommands()
        second.forgetSentCommands()
        return StubRedisCluster(channel: channel, first: first, second: second)
    }
}
