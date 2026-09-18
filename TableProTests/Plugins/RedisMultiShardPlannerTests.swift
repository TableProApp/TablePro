//
//  RedisMultiShardPlannerTests.swift
//  TableProTests
//

import Foundation
import Testing

private func args(_ tokens: String...) -> [Data] { tokens.map { Data($0.utf8) } }

private func spec(first: Int, last: Int, step: Int, response: RedisResponsePolicy? = nil) -> RedisCommandSpec {
    RedisCommandSpec(
        name: "test", firstKey: first, lastKey: last, step: step,
        isReadOnly: false, hasMovableKeys: false, requestPolicy: .multiShard, responsePolicy: response
    )
}

/// Slot stand-in: keys beginning with "a" share one slot, the rest share another.
private func slotOf(_ key: Data) -> Int {
    (String(data: key, encoding: .utf8)?.hasPrefix("a") ?? false) ? 100 : 200
}

@Suite("Redis multi-shard planner - splitting")
struct RedisMultiShardPlannerSplitTests {
    @Test("Keys are grouped by the slot they hash to")
    func groupsBySlot() throws {
        let groups = try #require(
            RedisMultiShardPlanner.split(
                arguments: args("DEL", "a1", "b1", "a2"),
                spec: spec(first: 1, last: -1, step: 1),
                slotOf: slotOf
            )
        )
        #expect(groups.count == 2)
        #expect(groups[0].slot == 100)
        #expect(groups[0].arguments.compactMap { String(data: $0, encoding: .utf8) } == ["DEL", "a1", "a2"])
        #expect(groups[1].arguments.compactMap { String(data: $0, encoding: .utf8) } == ["DEL", "b1"])
    }

    @Test("A stepped command keeps each key with its value")
    func keepsValueWithKey() throws {
        let groups = try #require(
            RedisMultiShardPlanner.split(
                arguments: args("MSET", "a1", "1", "b1", "2", "a2", "3"),
                spec: spec(first: 1, last: -1, step: 2),
                slotOf: slotOf
            )
        )
        #expect(groups[0].arguments.compactMap { String(data: $0, encoding: .utf8) } == ["MSET", "a1", "1", "a2", "3"])
        #expect(groups[1].arguments.compactMap { String(data: $0, encoding: .utf8) } == ["MSET", "b1", "2"])
    }

    @Test("Repeated keys stay repeated, because EXISTS counts every one")
    func keepsDuplicates() throws {
        let groups = try #require(
            RedisMultiShardPlanner.split(
                arguments: args("EXISTS", "a1", "a1", "b1"),
                spec: spec(first: 1, last: -1, step: 1),
                slotOf: slotOf
            )
        )
        #expect(groups[0].arguments.compactMap { String(data: $0, encoding: .utf8) } == ["EXISTS", "a1", "a1"])
    }

    @Test("Keys that all live in one slot need no split")
    func singleSlotNeedsNoSplit() {
        let groups = RedisMultiShardPlanner.split(
            arguments: args("DEL", "a1", "a2"),
            spec: spec(first: 1, last: -1, step: 1),
            slotOf: slotOf
        )
        #expect(groups == nil)
    }

    @Test("A single key needs no split")
    func singleKeyNeedsNoSplit() {
        let groups = RedisMultiShardPlanner.split(
            arguments: args("DEL", "a1"),
            spec: spec(first: 1, last: -1, step: 1),
            slotOf: slotOf
        )
        #expect(groups == nil)
    }

    /// Two slots can sit on the same shard, and Redis still refuses a command spanning them, so
    /// the split follows slots rather than nodes. Grouping by node shipped as a CROSSSLOT error on
    /// a three-shard cluster.
    @Test("Real keys are grouped by their actual hash slot")
    func usesRealSlots() throws {
        let groups = try #require(
            RedisMultiShardPlanner.split(
                arguments: args("MGET", "foo", "bar", "hello"),
                spec: spec(first: 1, last: -1, step: 1)
            )
        )
        #expect(groups.count == 3)
        #expect(Set(groups.map(\.slot)) == [12_182, 5_061, 866])
    }

    @Test("Keys sharing a hash tag stay in one group")
    func sharedTagStaysTogether() {
        let groups = RedisMultiShardPlanner.split(
            arguments: args("MGET", "{user}:1", "{user}:2"),
            spec: spec(first: 1, last: -1, step: 1)
        )
        #expect(groups == nil)
    }
}

@Suite("Redis multi-shard planner - reassembly")
struct RedisMultiShardPlannerScatterTests {
    @Test("MGET comes back in the order the caller asked for its keys")
    func preservesKeyOrder() throws {
        let arguments = args("MGET", "a1", "b1", "a2")
        let commandSpec = spec(first: 1, last: -1, step: 1)
        let groups = try #require(
            RedisMultiShardPlanner.split(arguments: arguments, spec: commandSpec, slotOf: slotOf)
        )
        let replies: [RedisReply] = [
            .array([.string("valueA1"), .string("valueA2")]),
            .array([.string("valueB1")]),
        ]
        let combined = RedisMultiShardPlanner.scatterInKeyOrder(
            groups: groups,
            replies: replies,
            keyIndices: commandSpec.keyIndices(forArgumentCount: arguments.count)
        )
        #expect(combined.stringArrayValue == ["valueA1", "valueB1", "valueA2"])
    }

    @Test("A missing key stays nil in its own position")
    func keepsNilsInPlace() throws {
        let arguments = args("MGET", "a1", "b1")
        let commandSpec = spec(first: 1, last: -1, step: 1)
        let groups = try #require(
            RedisMultiShardPlanner.split(arguments: arguments, spec: commandSpec, slotOf: slotOf)
        )
        let combined = RedisMultiShardPlanner.scatterInKeyOrder(
            groups: groups,
            replies: [.array([.null]), .array([.string("valueB1")])],
            keyIndices: commandSpec.keyIndices(forArgumentCount: arguments.count)
        )
        guard case .array(let items) = combined else {
            Issue.record("expected an array")
            return
        }
        #expect(items.count == 2)
        #expect(items[1].stringValue == "valueB1")
    }

    @Test("A shard that failed is reported instead of a partial answer")
    func surfacesShardFailure() throws {
        let arguments = args("MGET", "a1", "b1")
        let commandSpec = spec(first: 1, last: -1, step: 1)
        let groups = try #require(
            RedisMultiShardPlanner.split(arguments: arguments, spec: commandSpec, slotOf: slotOf)
        )
        let combined = RedisMultiShardPlanner.scatterInKeyOrder(
            groups: groups,
            replies: [.array([.string("valueA1")]), .error("NOPERM")],
            keyIndices: commandSpec.keyIndices(forArgumentCount: arguments.count)
        )
        #expect(combined.errorMessage == "NOPERM")
    }
}
