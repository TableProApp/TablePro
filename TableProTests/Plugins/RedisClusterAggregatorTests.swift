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

@Suite("Redis cluster aggregation - keyspace across primaries")
struct RedisClusterAggregatorKeyspaceTests {
    @Test("Each database's key counts add up across the primaries")
    func sumsPerDatabase() {
        #expect(RedisClusterAggregator.keyspace([[0: 2, 3: 1], [3: 4]]) == [0: 2, 3: 5])
    }

    @Test("A primary with no keys adds nothing")
    func emptyPrimaryAddsNothing() {
        #expect(RedisClusterAggregator.keyspace([[0: 2], [:]]) == [0: 2])
    }

    @Test("A primary that declined leaves every count unknown")
    func declinedPrimaryIsUnknown() {
        #expect(RedisClusterAggregator.keyspace([[0: 2], nil]) == nil)
    }
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

/// Measured on a two-master redis-server 8.10.1 cluster: a `~app:*` user's `DEL app:1 other:1`
/// deleted `app:1` on one shard and was refused on the other, and the driver reported one
/// deletion; with `-dbsize` on one master, or that master busy running a script, the sidebar
/// counted only the other master's keys.
@Suite("Redis cluster aggregation - a shard that did not answer")
struct RedisClusterAggregatorShardFailureTests {
    static let loading = "LOADING Redis is loading the dataset in memory"

    static let everyPolicyButOneSucceeded: [RedisResponsePolicy?] = [
        .aggSum, .aggMin, .aggMax, .aggLogicalAnd, .aggLogicalOr, .allSucceeded, .special, nil,
    ]

    @Test("A shard's error is the answer, never counted as zero", arguments: everyPolicyButOneSucceeded)
    func errorWins(policy: RedisResponsePolicy?) {
        let combined = RedisClusterAggregator.combine(
            [.integer(1_000), .error(Self.loading), .integer(1_000)],
            policy: policy
        )
        #expect(combined.errorMessage == Self.loading)
    }

    @Test("A split DEL one shard refused reports the refusal, not the other shard's deletions")
    func partialDeleteReportsRefusal() {
        let combined = RedisClusterAggregator.combine(
            [.integer(1), .error("NOPERM No permissions to access a key")],
            policy: .aggSum
        )
        #expect(combined.errorMessage == "NOPERM No permissions to access a key")
        #expect(intValue(combined) == nil)
    }

    @Test("The first shard to fail, in the order they were asked, is the one reported")
    func firstFailureInAskOrder() {
        let combined = RedisClusterAggregator.combine(
            [.integer(1), .error("NOPERM a"), .error("BUSY b")],
            policy: .aggSum
        )
        #expect(combined.errorMessage == "NOPERM a")
    }

    @Test("An error outranks a queued acknowledgement")
    func errorOutranksQueued() {
        let combined = RedisClusterAggregator.combine([.status("QUEUED"), .error("NOPERM a")], policy: .aggSum)
        #expect(combined.errorMessage == "NOPERM a")
    }

    /// A user's `MULTI` opens a block on one master only, so `DBSIZE` came back as that master's
    /// `+QUEUED` beside the other's count, and summed to the other's count.
    @Test("A shard that queued its part is reported as queued, not counted as zero")
    func queuedShardIsQueued() {
        let combined = RedisClusterAggregator.combine([.integer(4), .status("QUEUED")], policy: .aggSum)
        #expect(combined.isQueued)
    }

    @Test("KEYS with one queued shard is queued, not a key named QUEUED")
    func queuedShardInConcatenation() {
        let combined = RedisClusterAggregator.combine(
            [.array([.string("a"), .string("b")]), .status("QUEUED")],
            policy: nil
        )
        #expect(combined.isQueued)
    }

    @Test("one_succeeded still takes a success over another shard's failure")
    func oneSucceededToleratesFailure() {
        let combined = RedisClusterAggregator.combine([.error("NOSCRIPT"), .integer(1)], policy: .oneSucceeded)
        #expect(intValue(combined) == 1)
    }
}

@Suite("Redis cluster aggregation - replies that are not one number")
struct RedisClusterAggregatorShapeTests {
    private static func integers(_ reply: RedisReply) -> [Int64?]? {
        reply.arrayValue?.map(intValue)
    }

    /// `SCRIPT EXISTS` answers one flag per script from every shard; reading the array as a
    /// number reported `0` for a script every shard had loaded.
    @Test("agg_logical_and over SCRIPT EXISTS folds each script's flag across shards")
    func scriptExistsFoldsPerPosition() {
        let combined = RedisClusterAggregator.combine(
            [
                .array([.integer(1), .integer(0), .integer(1)]),
                .array([.integer(1), .integer(1), .integer(0)]),
            ],
            policy: .aggLogicalAnd
        )
        #expect(Self.integers(combined) == [1, 0, 0])
    }

    @Test("agg_min over WAITAOF takes the smallest local and replica counts")
    func waitAofFoldsPerPosition() {
        let combined = RedisClusterAggregator.combine(
            [.array([.integer(1), .integer(2)]), .array([.integer(0), .integer(3)])],
            policy: .aggMin
        )
        #expect(Self.integers(combined) == [0, 2])
    }

    @Test("Replies the policy cannot count come back whole instead of as a made-up number")
    func uncountableRepliesComeBackWhole() {
        let mixed = RedisClusterAggregator.combine([.integer(1), .null], policy: .aggSum)
        #expect(intValue(mixed) == nil)
        #expect(mixed.arrayValue?.count == 2)

        let ragged = RedisClusterAggregator.combine(
            [.array([.integer(1), .integer(2)]), .array([.integer(1), .integer(2), .integer(3)])],
            policy: .aggSum
        )
        #expect(ragged.arrayValue?.map { $0.arrayValue?.count } == [2, 3])
    }

    @Test("A count sent as a string still sums")
    func numericStringsSum() {
        let combined = RedisClusterAggregator.combine([.integer(2), .string("3")], policy: .aggSum)
        #expect(intValue(combined) == 5)
    }
}
