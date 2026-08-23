//
//  RedisClusterAggregatorTests.swift
//  TableProTests
//
//  The policies and their meanings come from the Redis command tips reference.
//

import Foundation
import Testing

private func intValue(_ reply: RedisReply) -> Int64? {
    guard case .integer(let value) = reply else { return nil }
    return value
}

@Suite("Redis cluster aggregation - numeric policies")
struct RedisClusterAggregatorNumericTests {
    @Test("agg_sum adds every shard's count, which is what DBSIZE needs")
    func sums() {
        let combined = RedisClusterAggregator.combine([.integer(100), .integer(101), .integer(100)], policy: .aggSum)
        #expect(intValue(combined) == 301)
    }

    @Test("agg_sum over a multi-shard DEL reports the total deleted, not one row per shard")
    func sumsDeletions() {
        let combined = RedisClusterAggregator.combine([.integer(1), .integer(1), .integer(1)], policy: .aggSum)
        #expect(intValue(combined) == 3)
    }

    @Test("agg_min takes the smallest")
    func takesMin() {
        #expect(intValue(RedisClusterAggregator.combine([.integer(3), .integer(1)], policy: .aggMin)) == 1)
    }

    @Test("agg_max takes the largest")
    func takesMax() {
        #expect(intValue(RedisClusterAggregator.combine([.integer(3), .integer(9)], policy: .aggMax)) == 9)
    }

    @Test("agg_logical_and is 1 only when every shard says 1")
    func logicalAnd() {
        #expect(intValue(RedisClusterAggregator.combine([.integer(1), .integer(1)], policy: .aggLogicalAnd)) == 1)
        #expect(intValue(RedisClusterAggregator.combine([.integer(1), .integer(0)], policy: .aggLogicalAnd)) == 0)
    }

    @Test("agg_logical_or is 1 when any shard says 1")
    func logicalOr() {
        #expect(intValue(RedisClusterAggregator.combine([.integer(0), .integer(1)], policy: .aggLogicalOr)) == 1)
        #expect(intValue(RedisClusterAggregator.combine([.integer(0), .integer(0)], policy: .aggLogicalOr)) == 0)
    }
}

@Suite("Redis cluster aggregation - success policies")
struct RedisClusterAggregatorSuccessTests {
    @Test("all_succeeded surfaces the first error, so a half-applied FLUSHDB is not reported as OK")
    func allSucceededSurfacesError() {
        let combined = RedisClusterAggregator.combine(
            [.status("OK"), .error("NOPERM"), .status("OK")],
            policy: .allSucceeded
        )
        #expect(combined.errorMessage == "NOPERM")
    }

    @Test("all_succeeded returns a success when every shard agreed")
    func allSucceededPasses() {
        let combined = RedisClusterAggregator.combine([.status("OK"), .status("OK")], policy: .allSucceeded)
        #expect(combined.stringValue == "OK")
    }

    @Test("one_succeeded takes the first non-error")
    func oneSucceeded() {
        let combined = RedisClusterAggregator.combine(
            [.error("NOSCRIPT"), .status("OK")],
            policy: .oneSucceeded
        )
        #expect(combined.stringValue == "OK")
    }

    @Test("one_succeeded still reports a failure when every shard failed")
    func oneSucceededAllFailed() {
        let combined = RedisClusterAggregator.combine([.error("a"), .error("b")], policy: .oneSucceeded)
        #expect(combined.isError)
    }
}

@Suite("Redis cluster aggregation - defaults")
struct RedisClusterAggregatorDefaultTests {
    @Test("With no policy, arrays concatenate, which is what KEYS needs")
    func concatenatesArrays() {
        let combined = RedisClusterAggregator.combine(
            [.array([.string("a"), .string("b")]), .array([.string("c")])],
            policy: nil
        )
        #expect(combined.stringArrayValue == ["a", "b", "c"])
    }

    @Test("A shard that failed is reported rather than dropped from the merge")
    func failurePreventsPartialAnswer() {
        let combined = RedisClusterAggregator.combine(
            [.array([.string("a")]), .error("NOPERM")],
            policy: nil
        )
        #expect(combined.errorMessage == "NOPERM")
    }

    @Test("One shard's reply comes back unchanged")
    func singleReplyPassesThrough() {
        #expect(RedisClusterAggregator.combine([.integer(7)], policy: .aggSum).intValue == 7)
    }

    @Test("No replies at all is an empty array, not a crash")
    func emptyIsEmpty() {
        #expect(RedisClusterAggregator.combine([], policy: .aggSum).arrayValue?.isEmpty == true)
    }
}
