//
//  RedisClusterWriteOutcome.swift
//  RedisDriverPlugin
//
//  What a write a cluster split across several nodes left behind when only some of them ran it.
//
//  Each part of a split write runs on its own node with nothing tying the parts together, and
//  Redis has no way to take back the parts that ran. Measured on a two-master Redis 8.10.1
//  cluster with an ACL user limited to `allowed:*`: `DEL allowed:1 forbidden:1` answered with the
//  refusing shard's `NOPERM` alone, while `allowed:1` was already gone.
//

import Foundation
import TableProPluginKit

enum RedisShardPartOutcome: Equatable, Sendable {
    case ran
    case refused(String)
    case queued
    /// The send threw, so whether this part reached the server is unknown.
    case interrupted(String)
    case notSent

    init(_ reply: RedisReply) {
        if let message = reply.errorMessage {
            self = .refused(message)
        } else if reply.isQueued {
            self = .queued
        } else {
            self = .ran
        }
    }

    fileprivate func failureMessage(for command: String) -> String? {
        switch self {
        case .refused(let message):
            return "\(command): \(message)"
        case .interrupted(let message):
            return message
        case .queued:
            return RedisQueuedCommand(command: command).pluginErrorMessage
        case .ran, .notSent:
            return nil
        }
    }
}

struct RedisShardPart: Equatable, Sendable {
    let node: String
    /// The keys this part carried, or none for a command sent whole to every node.
    let keys: [Data]
    let outcome: RedisShardPartOutcome
}

struct RedisPartialClusterWrite: Error, Equatable {
    static let listedKeyLimit = 20

    let command: String
    let parts: [RedisShardPart]
    private let headline: String

    /// Part `i` answered with `replies[i]`. When `interruption` is set, the part after the last
    /// reply is the one whose send threw, and every later part was never sent. Nil unless the
    /// command writes and the parts disagree: a write every part ran, or none did, is reported by
    /// the reply itself, and a read that one shard refused changed nothing.
    static func assemble(
        command: String,
        isWrite: Bool,
        nodes: [String],
        keys: [[Data]],
        replies: [RedisReply],
        interruption: (any Error)?
    ) -> RedisPartialClusterWrite? {
        guard isWrite else { return nil }
        let parts = nodes.indices.map { index in
            RedisShardPart(
                node: nodes[index],
                keys: index < keys.count ? keys[index] : [],
                outcome: outcome(at: index, replies: replies, interruption: interruption)
            )
        }
        guard parts.contains(where: { $0.outcome == .ran }),
              let headline = parts.lazy.compactMap({ $0.outcome.failureMessage(for: command) }).first else {
            return nil
        }
        return RedisPartialClusterWrite(command: command, parts: parts, headline: headline)
    }

    private static func outcome(
        at index: Int,
        replies: [RedisReply],
        interruption: (any Error)?
    ) -> RedisShardPartOutcome {
        if index < replies.count { return RedisShardPartOutcome(replies[index]) }
        guard index == replies.count, let interruption else { return .notSent }
        let message = (interruption as? PluginDriverError)?.pluginErrorMessage ?? interruption.localizedDescription
        return .interrupted(message)
    }

    var appliedParts: [RedisShardPart] {
        parts.filter { $0.outcome == .ran }
    }

    private var isSplitByKey: Bool {
        parts.allSatisfy { !$0.keys.isEmpty }
    }

    private var appliedKeyList: String {
        let keys = appliedParts.flatMap(\.keys).map { RedisArgumentCodec.quote($0) }
        let listed = keys.prefix(Self.listedKeyLimit).joined(separator: " ")
        guard keys.count > Self.listedKeyLimit else { return listed }
        return String(
            format: String(localized: "%1$@ and %2$lld more"),
            listed,
            Int64(keys.count - Self.listedKeyLimit)
        )
    }

    private var appliedNodeList: String {
        ListFormatter.localizedString(byJoining: appliedParts.map(\.node))
    }
}

extension RedisPartialClusterWrite: PluginDriverError {
    var pluginErrorMessage: String { headline }

    var pluginErrorDetail: String? {
        let applied = Int64(appliedParts.count)
        let total = Int64(parts.count)
        guard isSplitByKey else {
            let template = String(localized: "%1$@ already ran on %2$lld of the %3$lld nodes it was sent to, and Redis cannot undo that. Nodes it ran on: %4$@")
            return String(format: template, command, applied, total, appliedNodeList)
        }
        let template = String(localized: "%1$@ already ran on %2$lld of the %3$lld hash slots it was split across, and Redis cannot undo that. Keys it ran on: %4$@")
        return String(format: template, command, applied, total, appliedKeyList)
    }
}
