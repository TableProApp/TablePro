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
    private(set) var sessionDatabase: RedisSessionDatabase

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
        sessionDatabase = RedisSessionDatabase(currentDatabase)
    }

    var isConnected: Bool { true }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {}
    func disconnect() {}
    func cancelCurrentQuery() {}
    func serverVersion() -> String? { "8.10.1" }
    func currentDatabase() -> Int { sessionDatabase.current }
    func databaseForNextCommand() -> Int { footprint.pendingDatabase ?? sessionDatabase.current }
    func homeDatabase() -> Int { sessionDatabase.home }

    func selectDatabase(_ index: Int, scope: RedisCommandScope) async throws {
        try moveSession(to: index, scope: scope) { $0.selected(index) }
    }

    func visitDatabase(_ index: Int) async throws {
        try moveSession(to: index, scope: .outsideBlock) { $0.visited(index) }
    }

    /// Mirrors the hiredis connection: a SELECT queued in an open block moves nothing yet and
    /// answers queued, and a move records itself only once the server accepted it.
    private func moveSession(
        to index: Int,
        scope: RedisCommandScope,
        recording move: (inout RedisSessionDatabase) -> Void
    ) throws {
        let command = ["SELECT", String(index)]
        try admit(scope, command: command)
        let reply = try send(command, scope: scope) ?? .status("OK")
        _ = footprint.observe(command: "SELECT", reply: reply)
        if case .error(let message) = reply {
            throw RedisPluginError(code: 2, message: "SELECT \(index) failed: \(message)")
        }
        if reply.isQueued {
            footprint.queueDatabase(index)
            throw RedisQueuedCommand(command: "SELECT")
        }
        move(&sessionDatabase)
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
        try returnHomeIfAway()
        guard let reply = try send(command, scope: scope) else { return .null }
        observe(command: command.first, reply: reply)
        return reply
    }

    /// Admitted once for the whole pipeline and observed after every reply is in, as the hiredis
    /// connection does, because every command is on the wire before the first reply is read.
    func executePipeline(_ commands: [[Data]], scope: RedisCommandScope) async throws -> [RedisReply] {
        let pipeline = commands.map(decoded)
        try admit(scope, command: pipeline.first ?? [])
        try returnHomeIfAway()
        let replies = try pipeline.map { try send($0, scope: scope) }
        for (command, reply) in zip(pipeline, replies) {
            guard let reply else { continue }
            observe(command: command.first, reply: reply)
        }
        return replies.map { $0 ?? .null }
    }

    private func returnHomeIfAway() throws {
        guard RedisDatabaseVisit.database == nil, !footprint.hasOpenBlock,
              let home = sessionDatabase.awayFromHome else { return }
        try moveSession(to: home, scope: .outsideBlock) { $0.visited(home) }
    }

    private func observe(command: String?, reply: RedisReply) {
        guard let moved = footprint.observe(command: command, reply: reply) else { return }
        sessionDatabase.selected(moved)
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
