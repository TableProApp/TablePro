//
//  StubRedisChannel.swift
//  TableProTests
//
//  A Redis command channel that answers from a script, for driving the channel-level logic
//  without hiredis or a server.
//

import Foundation
import TableProPluginKit

/// Driven by one task at a time, so the outcomes are handed out in order with no synchronisation.
final class StubRedisChannel: RedisCommandChannel, @unchecked Sendable {
    private var outcomes: [Result<RedisReply, Error>]
    private(set) var sentCommands: [[String]] = []
    let supportsDatabaseSelection: Bool
    private let database: Int

    convenience init(_ replies: [RedisReply], supportsDatabaseSelection: Bool = true, currentDatabase: Int = 0) {
        self.init(
            outcomes: replies.map { .success($0) },
            supportsDatabaseSelection: supportsDatabaseSelection,
            currentDatabase: currentDatabase
        )
    }

    init(outcomes: [Result<RedisReply, Error>], supportsDatabaseSelection: Bool = true, currentDatabase: Int = 0) {
        self.outcomes = outcomes
        self.supportsDatabaseSelection = supportsDatabaseSelection
        database = currentDatabase
    }

    var isConnected: Bool { true }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {}
    func disconnect() {}
    func cancelCurrentQuery() {}
    func serverVersion() -> String? { "8.10.1" }
    func currentDatabase() -> Int { database }
    func selectDatabase(_ index: Int) async throws {}

    func executeCommand(_ args: [Data]) async throws -> RedisReply {
        sentCommands.append(args.map { String(data: $0, encoding: .utf8) ?? "" })
        guard !outcomes.isEmpty else { return .null }
        return try outcomes.removeFirst().get()
    }

    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply] {
        var replies: [RedisReply] = []
        for command in commands {
            replies.append(try await executeCommand(command))
        }
        return replies
    }
}
