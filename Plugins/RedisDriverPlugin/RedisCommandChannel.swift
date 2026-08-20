//
//  RedisCommandChannel.swift
//  RedisDriverPlugin
//
//  Everything the driver needs from "a way to run Redis commands".
//
//  Every command site in the driver already funnels into executeCommand and executePipeline, so
//  making those two a protocol is what lets Sentinel resolution and Cluster slot routing exist
//  without touching the sixty-odd places that build a command.
//

import Foundation
import TableProPluginKit

struct RedisKeyspacePage: Sendable {
    let cursor: String
    let keys: [String]
    /// True when the walk had to restart a node because the topology moved under it, so the
    /// caller cannot claim it saw every key.
    let isIncomplete: Bool

    var isFinished: Bool { cursor == RedisClusterCursor.start }
}

protocol RedisCommandChannel: AnyObject, Sendable {
    var isConnected: Bool { get }
    var supportsDatabaseSelection: Bool { get }
    var supportsTransactions: Bool { get }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws
    func disconnect()
    func cancelCurrentQuery()

    func serverVersion() -> String?
    func currentDatabase() -> Int

    func executeCommand(_ args: [Data]) async throws -> RedisReply
    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply]
    func selectDatabase(_ index: Int) async throws

    func scanKeyspace(cursor: String, pattern: String?, type: String?, count: Int) async throws -> RedisKeyspacePage

    /// Confirms the channel still points at a node that accepts writes, re-pointing it if not.
    /// Sentinel needs this because a demoted primary keeps answering `role:master` and keeps
    /// accepting writes for several seconds after the quorum has moved on.
    func verifyStillPrimary() async throws
}

extension RedisCommandChannel {
    var supportsDatabaseSelection: Bool { true }
    var supportsTransactions: Bool { true }

    func connect() async throws {
        try await connect(reportingStage: { _ in })
    }

    func executeCommand(_ args: [String]) async throws -> RedisReply {
        try await executeCommand(args.map { Data($0.utf8) })
    }

    func executePipeline(_ commands: [[String]]) async throws -> [RedisReply] {
        try await executePipeline(commands.map { $0.map { Data($0.utf8) } })
    }

    func verifyStillPrimary() async throws {}

    /// Runs a command and turns a server error reply into a thrown error.
    ///
    /// hiredis hands `-READONLY`, `-WRONGTYPE`, `-NOPERM` and the rest back as ordinary replies,
    /// so a caller that ignores the reply reports success for a command the server refused. Every
    /// command site goes through here rather than reading the reply straight.
    @discardableResult
    func run(_ args: [String]) async throws -> RedisReply {
        try await executeCommand(args).throwIfError(args.first ?? "")
    }

    @discardableResult
    func run(_ args: [Data]) async throws -> RedisReply {
        let name = args.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return try await executeCommand(args).throwIfError(name)
    }

    /// The single-node walk. A cluster channel replaces this with one that visits every master.
    func scanKeyspace(cursor: String, pattern: String?, type: String?, count: Int) async throws -> RedisKeyspacePage {
        var args = ["SCAN", cursor == RedisClusterCursor.start ? "0" : cursor]
        if let pattern { args += ["MATCH", pattern] }
        args += ["COUNT", String(count)]
        if let type { args += ["TYPE", type] }

        let reply = try await executeCommand(args).throwIfError()
        let page = RedisScanReply.parse(reply)
        return RedisKeyspacePage(cursor: page.cursor, keys: page.keys, isIncomplete: false)
    }
}

enum RedisScanReply {
    /// A SCAN answer is always [cursor, [keys...]]; anything else means the server refused and the
    /// caller should already have thrown.
    static func parse(_ reply: RedisReply) -> (cursor: String, keys: [String]) {
        guard case .array(let parts) = reply, parts.count == 2 else { return ("0", []) }
        let cursor: String
        switch parts[0] {
        case .string(let value), .status(let value): cursor = value
        case .data(let value): cursor = String(data: value, encoding: .utf8) ?? "0"
        case .integer(let value): cursor = String(value)
        default: cursor = "0"
        }
        guard case .array(let keyReplies) = parts[1] else { return (cursor, []) }
        let keys = keyReplies.compactMap { item -> String? in
            switch item {
            case .string(let key), .status(let key): return key
            case .data(let value): return String(data: value, encoding: .utf8)
            default: return nil
            }
        }
        return (cursor, keys)
    }
}
