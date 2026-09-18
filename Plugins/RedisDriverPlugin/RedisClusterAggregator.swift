//
//  RedisClusterAggregator.swift
//  RedisDriverPlugin
//
//  Combines the replies a fanned-out command collects from several shards, following the
//  response_policy tip. Where a command carries no policy, the cluster spec's defaults apply:
//  a keyless command's nested replies are concatenated in no particular order, and a keyed one
//  keeps the order of its input keys.
//

import Foundation

enum RedisClusterAggregator {
    static func combine(_ replies: [RedisReply], policy: RedisResponsePolicy?) -> RedisReply {
        guard let first = replies.first else { return .array([]) }
        guard replies.count > 1 else { return first }

        switch policy {
        case .aggSum:
            return .integer(replies.reduce(Int64(0)) { $0 + numericValue($1) })
        case .aggMin:
            return .integer(replies.map(numericValue).min() ?? 0)
        case .aggMax:
            return .integer(replies.map(numericValue).max() ?? 0)
        case .aggLogicalAnd:
            return .integer(replies.allSatisfy { numericValue($0) != 0 } ? 1 : 0)
        case .aggLogicalOr:
            return .integer(replies.contains { numericValue($0) != 0 } ? 1 : 0)
        case .oneSucceeded:
            return replies.first { !$0.isError } ?? first
        case .allSucceeded:
            if let failure = replies.first(where: { $0.isError }) { return failure }
            return replies.first { !$0.isError } ?? first
        case .special, .none:
            return concatenated(replies)
        }
    }

    /// The no-policy default for a keyless fan-out: pack every shard's nested reply into one.
    /// A shard that answered with an error still wins, because a partial answer read as complete
    /// is worse than a visible failure.
    static func concatenated(_ replies: [RedisReply]) -> RedisReply {
        if let failure = replies.first(where: { $0.isError }) { return failure }
        var merged: [RedisReply] = []
        var sawArray = false
        for reply in replies {
            if case .array(let items) = reply {
                sawArray = true
                merged.append(contentsOf: items)
            } else if case .null = reply {
                continue
            } else {
                merged.append(reply)
            }
        }
        guard sawArray else { return replies.first ?? .array([]) }
        return .array(merged)
    }

    private static func numericValue(_ reply: RedisReply) -> Int64 {
        switch reply {
        case .integer(let value): return value
        case .string(let text), .status(let text): return Int64(text) ?? 0
        default: return 0
        }
    }
}
