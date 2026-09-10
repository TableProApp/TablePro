//
//  RedisMultiShardPlanner.swift
//  RedisDriverPlugin
//
//  Splits a multi-key command across the shards that own its keys, and puts the answers back
//  together.
//
//  The spec is explicit that the split follows hash slots, not shards: `DEL {foo} {foo}1 bar`
//  becomes `DEL {foo} {foo}1` and `DEL bar` even when one shard owns both slots. Multiplicity
//  matters too, because EXISTS and TOUCH count every occurrence: `EXISTS a a a` is 3.
//

import Foundation

struct RedisMultiShardGroup: Equatable {
    /// The hash slot every key in this group belongs to.
    let slot: Int
    let arguments: [Data]
    /// Where each of this group's keys sat in the original argument list, so a reply that follows
    /// input order can be scattered back.
    let keyIndices: [Int]
}

enum RedisMultiShardPlanner {
    /// Grouping is by hash slot rather than by node on purpose. Two slots can sit on the same
    /// shard today and be split apart tomorrow, and Redis refuses a multi-key command whose keys
    /// span slots however they are distributed, so grouping by node produces a CROSSSLOT error
    /// whenever one shard happens to own two of the slots involved.
    static func split(
        arguments: [Data],
        spec: RedisCommandSpec,
        slotOf: (Data) -> Int = { RedisKeySlot.slot(for: $0) }
    ) -> [RedisMultiShardGroup]? {
        let keyIndices = spec.keyIndices(forArgumentCount: arguments.count)
        guard keyIndices.count > 1 else { return nil }

        let prefix = Array(arguments[0 ..< spec.firstKey])
        var order: [Int] = []
        var unitsBySlot: [Int: [Data]] = [:]
        var indicesBySlot: [Int: [Int]] = [:]

        for index in keyIndices {
            let slot = slotOf(arguments[index])
            let unitEnd = min(index + spec.step, arguments.count)
            let unit = Array(arguments[index ..< unitEnd])
            if unitsBySlot[slot] == nil {
                order.append(slot)
                unitsBySlot[slot] = []
                indicesBySlot[slot] = []
            }
            unitsBySlot[slot]?.append(contentsOf: unit)
            indicesBySlot[slot]?.append(index)
        }

        guard order.count > 1 else { return nil }
        return order.map { slot in
            RedisMultiShardGroup(
                slot: slot,
                arguments: prefix + (unitsBySlot[slot] ?? []),
                keyIndices: indicesBySlot[slot] ?? []
            )
        }
    }

    /// The no-policy default for a keyed command: the caller expects one element per input key,
    /// in the order it asked for them.
    static func scatterInKeyOrder(
        groups: [RedisMultiShardGroup],
        replies: [RedisReply],
        keyIndices: [Int]
    ) -> RedisReply {
        guard groups.count == replies.count else { return .array(replies) }
        if let failure = replies.first(where: { $0.isError }) { return failure }

        var byOriginalIndex: [Int: RedisReply] = [:]
        for (group, reply) in zip(groups, replies) {
            guard case .array(let items) = reply else { continue }
            for (offset, originalIndex) in group.keyIndices.enumerated() where offset < items.count {
                byOriginalIndex[originalIndex] = items[offset]
            }
        }
        return .array(keyIndices.map { byOriginalIndex[$0] ?? .null })
    }
}
