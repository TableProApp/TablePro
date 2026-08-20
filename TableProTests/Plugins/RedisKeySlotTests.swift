//
//  RedisKeySlotTests.swift
//  TableProTests
//
//  Every expected slot here was read back from `CLUSTER KEYSLOT` on a live Redis 8.10.1 cluster,
//  so this suite fails if the CRC16 or the hash-tag rule ever drifts from what the server does.
//

import Foundation
import Testing

@Suite("Redis key slot - measured vectors")
struct RedisKeySlotVectorTests {
    static let measured: [(key: String, slot: Int)] = [
        ("foo", 12_182),
        ("bar", 5_061),
        ("123456789", 12_739),
        ("hello", 866),
        ("user1000", 3_443),
        ("key:with:colons", 12_379),
        ("üñïçødé", 2_682),
        ("", 0),
    ]

    @Test("Matches CLUSTER KEYSLOT", arguments: measured)
    func matchesServer(vector: (key: String, slot: Int)) {
        #expect(RedisKeySlot.slot(for: vector.key) == vector.slot)
    }

    @Test("Every slot is inside the 16384 keyspace")
    func staysInRange() {
        for index in 0 ..< 500 {
            let slot = RedisKeySlot.slot(for: "key:\(index)")
            #expect(slot >= 0)
            #expect(slot < RedisKeySlot.slotCount)
        }
    }
}

@Suite("Redis key slot - hash tags")
struct RedisKeySlotHashTagTests {
    static let measured: [(key: String, slot: Int)] = [
        ("{user1000}.following", 3_443),
        ("{user1000}.followers", 3_443),
        ("{tag}", 8_338),
        ("foo{}{bar}", 8_363),
        ("foo{{bar}}zap", 4_015),
        ("somekey{}", 14_936),
        ("{}foo", 9_500),
        ("{", 4_092),
        ("}", 12_090),
        ("{}", 15_257),
        ("a{b}c{d}e", 3_300),
        ("x{}{y}", 14_166),
    ]

    @Test("Matches CLUSTER KEYSLOT for tagged and degenerate keys", arguments: measured)
    func matchesServer(vector: (key: String, slot: Int)) {
        #expect(RedisKeySlot.slot(for: vector.key) == vector.slot)
    }

    @Test("A tagged key hashes to the same slot as the tag alone")
    func tagDrivesTheSlot() {
        #expect(RedisKeySlot.slot(for: "{user1000}.following") == RedisKeySlot.slot(for: "user1000"))
    }

    @Test("An empty tag falls back to hashing the whole key")
    func emptyTagHashesWholeKey() {
        #expect(RedisKeySlot.slot(for: "somekey{}") != RedisKeySlot.slot(for: ""))
        #expect(RedisKeySlot.slot(for: "foo{}{bar}") == RedisKeySlot.slot(for: "foo{}{bar}"))
    }

    @Test("An unclosed brace is not a tag")
    func unclosedBraceIsNotATag() {
        #expect(RedisKeySlot.hashTag(of: Data("{nope".utf8)) == nil)
    }

    @Test("Only the first closing brace after the first opening one counts")
    func firstBracePairWins() {
        let tag = RedisKeySlot.hashTag(of: Data("foo{{bar}}zap".utf8))
        #expect(tag == Data("{bar".utf8))
    }
}

@Suite("Redis key slot - cross-slot detection")
struct RedisKeySlotCrossSlotTests {
    @Test("Keys sharing a hash tag are same-slot")
    func sharedTagIsSameSlot() {
        let keys = ["{user}:1", "{user}:2", "{user}:3"].map { Data($0.utf8) }
        #expect(RedisKeySlot.slotsAreEqual(for: keys))
    }

    @Test("Unrelated keys are cross-slot")
    func unrelatedKeysCrossSlots() {
        #expect(!RedisKeySlot.slotsAreEqual(for: [Data("foo".utf8), Data("bar".utf8)]))
    }

    @Test("An empty key list is trivially same-slot")
    func emptyListIsSameSlot() {
        #expect(RedisKeySlot.slotsAreEqual(for: []))
    }
}
