//
//  StubRedisChannel.swift
//  TableProTests
//
//  A Redis command channel that answers from a script, for driving the channel-level logic
//  without hiredis or a server. It admits and observes through the same footprint the hiredis
//  connection keeps, so a test sees a held-back command exactly as the app would.
//

import Foundation
import TableProPluginKit

/// Driven by one task at a time, so the outcomes are handed out in order with no synchronisation.
final class StubRedisChannel: RedisCommandChannel, @unchecked Sendable {
    private var outcomes: [Result<RedisReply, Error>]
    private(set) var sentCommands: [[String]] = []
    private(set) var sentScopes: [RedisCommandScope] = []
    private(set) var footprint = RedisSessionFootprint()
    let supportsDatabaseSelection: Bool
    private var database: Int

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
    func databaseForNextCommand() -> Int { footprint.pendingDatabase ?? database }

    func selectDatabase(_ index: Int, scope: RedisCommandScope) async throws {
        let reply = try await executeCommand(["SELECT", String(index)].map { Data($0.utf8) }, scope: scope)
        if case .error(let message) = reply {
            throw RedisPluginError(code: 2, message: "SELECT \(index) failed: \(message)")
        }
        if reply.isQueued {
            footprint.queueDatabase(index)
        } else {
            database = index
        }
    }

    func observeOpenBlock() {
        _ = footprint.observe(command: "MULTI", reply: .status("OK"))
    }

    func observeWatch() {
        _ = footprint.observe(command: "WATCH", reply: .status("OK"))
    }

    func executeCommand(_ args: [Data], scope: RedisCommandScope) async throws -> RedisReply {
        let command = decoded(args)
        try admit(scope, command: command)
        guard let reply = try send(command, scope: scope) else { return .null }
        _ = footprint.observe(command: command.first, reply: reply)
        return reply
    }

    /// Admitted once for the whole pipeline and observed after every reply is in, as the hiredis
    /// connection does, because every command is on the wire before the first reply is read.
    func executePipeline(_ commands: [[Data]], scope: RedisCommandScope) async throws -> [RedisReply] {
        let pipeline = commands.map(decoded)
        try admit(scope, command: pipeline.first ?? [])
        let replies = try pipeline.map { try send($0, scope: scope) }
        for (command, reply) in zip(pipeline, replies) {
            guard let reply else { continue }
            _ = footprint.observe(command: command.first, reply: reply)
        }
        return replies.map { $0 ?? .null }
    }

    private func decoded(_ args: [Data]) -> [String] {
        args.map { String(data: $0, encoding: .utf8) ?? "" }
    }

    private func admit(_ scope: RedisCommandScope, command: [String]) throws {
        guard let held = footprint.heldBack(scope) else { return }
        throw RedisHeldBackCommand(command: command.first ?? "", held: held)
    }

    private func send(_ command: [String], scope: RedisCommandScope) throws -> RedisReply? {
        sentCommands.append(command)
        sentScopes.append(scope)
        guard !outcomes.isEmpty else { return nil }
        return try outcomes.removeFirst().get()
    }
}
