//
//  RedisDatabaseCountTests.swift
//  TableProTests
//
//  AWS ElastiCache removes CONFIG rather than denying it, so the probe for how many databases to
//  list answers `unknown command` and the run choke point throws. That throw used to escape
//  `fetchTables` and `fetchDatabases`, and the sidebar showed the server's error instead of the
//  keyspace, on every ElastiCache node.
//

import Foundation
import TableProPluginKit
import Testing

/// Driven by one task at a time, so the replies are handed out in order with no synchronisation.
private final class StubRedisChannel: RedisCommandChannel, @unchecked Sendable {
    private var queuedReplies: [RedisReply]
    private let selectable: Bool
    private(set) var sentCommands: [[String]] = []

    init(_ replies: [RedisReply], supportsDatabaseSelection selectable: Bool = true) {
        queuedReplies = replies
        self.selectable = selectable
    }

    var isConnected: Bool { true }
    var supportsDatabaseSelection: Bool { selectable }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {}
    func disconnect() {}
    func cancelCurrentQuery() {}
    func serverVersion() -> String? { "8.10.1" }
    func currentDatabase() -> Int { 0 }
    func selectDatabase(_ index: Int) async throws {}

    func executeCommand(_ args: [Data]) async throws -> RedisReply {
        sentCommands.append(args.map { String(data: $0, encoding: .utf8) ?? "" })
        guard !queuedReplies.isEmpty else { return .null }
        return queuedReplies.removeFirst()
    }

    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply] {
        var replies: [RedisReply] = []
        for command in commands {
            replies.append(try await executeCommand(command))
        }
        return replies
    }
}

@Suite("Redis database count")
struct RedisDatabaseCountTests {
    /// Measured on Redis 8.10.1 started with `--rename-command CONFIG ''`, which is what
    /// ElastiCache does: the server answers with an error naming a command it does not have,
    /// not with `NOPERM`.
    @Test("A server that removes CONFIG still lists the default 16")
    func removedConfigFallsBack() async {
        let channel = StubRedisChannel([
            .error("ERR unknown command 'CONFIG', with args beginning with: 'GET' 'databases'"),
        ])
        #expect(await RedisDatabaseCount.resolve(on: channel) == 16)
    }

    @Test("A server that denies CONFIG through an ACL lists the default 16")
    func deniedConfigFallsBack() async {
        let channel = StubRedisChannel([
            .error("NOPERM User viewer has no permissions to run the 'config|get' command"),
        ])
        #expect(await RedisDatabaseCount.resolve(on: channel) == 16)
    }

    @Test("A server that answers is taken at its word")
    func serverAnswerWins() async {
        let channel = StubRedisChannel([.array([.string("databases"), .string("4")])])
        #expect(await RedisDatabaseCount.resolve(on: channel) == 4)
        #expect(channel.sentCommands == [["CONFIG", "GET", "databases"]])
    }

    static let unusableAnswers: [RedisReply] = [
        .array([.string("databases")]),
        .array([.string("databases"), .string("none")]),
        .array([.string("databases"), .string("0")]),
        .array([.string("databases"), .string("-1")]),
        .array([]),
        .status("OK"),
        .null,
    ]

    @Test("An answer that is not a count falls back", arguments: unusableAnswers)
    func unusableAnswerFallsBack(reply: RedisReply) async {
        #expect(await RedisDatabaseCount.resolve(on: StubRedisChannel([reply])) == 16)
    }

    /// A cluster node has one keyspace and refuses `SELECT` with any other index, so it is never
    /// asked: the probe would cost a round trip to learn a number the topology already fixes.
    @Test("A cluster node is one keyspace and is never probed")
    func clusterIsNotProbed() async {
        let channel = StubRedisChannel([.array([.string("databases"), .string("16")])],
                                       supportsDatabaseSelection: false)
        #expect(await RedisDatabaseCount.resolve(on: channel) == 1)
        #expect(channel.sentCommands.isEmpty)
    }
}
