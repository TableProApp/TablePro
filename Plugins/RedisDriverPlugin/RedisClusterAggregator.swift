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
    /// A shard that refused its part, or queued it into an open `MULTI` block, wins over every
    /// policy but one_succeeded, whose whole meaning is that some shards may fail. Folding it in
    /// instead counted it as zero: a split `DEL` one shard refused reported the other shard's
    /// deletions as the total, and `DBSIZE` reported part of the keyspace as all of it.
    static func combine(_ replies: [RedisReply], policy: RedisResponsePolicy?) -> RedisReply {
        guard let first = replies.first else { return .array([]) }
        guard replies.count > 1 else { return first }
        if policy != .oneSucceeded, let failure = firstNonAnswer(in: replies) { return failure }

        switch policy {
        case .aggSum:
            return aggregated(replies) { $0.reduce(0, +) }
        case .aggMin:
            return aggregated(replies) { $0.min() ?? 0 }
        case .aggMax:
            return aggregated(replies) { $0.max() ?? 0 }
        case .aggLogicalAnd:
            return aggregated(replies) { $0.allSatisfy { $0 != 0 } ? 1 : 0 }
        case .aggLogicalOr:
            return aggregated(replies) { $0.contains { $0 != 0 } ? 1 : 0 }
        case .oneSucceeded:
            return replies.first { !$0.isError } ?? first
        case .allSucceeded:
            return first
        case .special, .none:
            return concatenated(replies)
        }
    }

    /// The first shard error in the order the shards were asked, else the first `+QUEUED`.
    static func firstNonAnswer(in replies: [RedisReply]) -> RedisReply? {
        replies.first(where: \.isError) ?? replies.first(where: \.isQueued)
    }

    /// A reply the policy cannot count is handed back whole rather than as a number made up for
    /// it, the way a keyed reply the planner cannot scatter is.
    private static func aggregated(_ replies: [RedisReply], _ reduce: ([Int64]) -> Int64) -> RedisReply {
        folded(replies, reduce) ?? .array(replies)
    }

    /// Integers fold to one integer. Arrays of one width fold position by position, which is
    /// what `SCRIPT EXISTS` (one flag per script) and `WAITAOF` (local and replica counts) need.
    private static func folded(_ replies: [RedisReply], _ reduce: ([Int64]) -> Int64) -> RedisReply? {
        let numbers = replies.compactMap(numericValue)
        if numbers.count == replies.count { return .integer(reduce(numbers)) }

        let arrays = replies.compactMap(\.arrayValue)
        guard arrays.count == replies.count, let width = arrays.first?.count,
              arrays.allSatisfy({ $0.count == width }) else { return nil }
        var elements: [RedisReply] = []
        elements.reserveCapacity(width)
        for position in 0 ..< width {
            guard let element = folded(arrays.map { $0[position] }, reduce) else { return nil }
            elements.append(element)
        }
        return .array(elements)
    }

    /// The no-policy default for a keyless fan-out: pack every shard's nested reply into one.
    private static func concatenated(_ replies: [RedisReply]) -> RedisReply {
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

    private static func numericValue(_ reply: RedisReply) -> Int64? {
        switch reply {
        case .integer(let value): return value
        case .string(let text), .status(let text): return Int64(text)
        default: return nil
        }
    }
}
