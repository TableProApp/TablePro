import Foundation
import TableProMemcachedCore
import Testing

struct MemcachedKeyListingTests {
    @Test("A metadump line gives the decoded key, its expiry and flags")
    func metadump() {
        let entry = MemcachedKeyListing.metadumpEntry(
            "key=a%3A1 exp=1793500167 la=1793499867 cas=2 fetch=yes cls=1 size=71 flags=5 "
        )
        #expect(entry == MemcachedKeyEntry(key: "a:1", expiresAt: 1_793_500_167, flags: 5))
        #expect(entry?.secondsLeft(at: 1_793_499_867) == 300)
    }

    @Test("exp=-1 means the item never expires")
    func metadumpNeverExpires() {
        let entry = MemcachedKeyListing.metadumpEntry("key=%22sp%22 exp=-1 la=1 cas=4 fetch=no cls=1 size=64 flags=0")
        #expect(entry == MemcachedKeyEntry(key: "\"sp\"", expiresAt: nil, flags: 0))
        #expect(entry?.isExpired(at: .max) == false)
    }

    @Test("A cachedump line gives the key and expiry; 0 means never")
    func cachedump() {
        #expect(MemcachedKeyListing.cachedumpEntry("ITEM k1 [2 b; 0 s]") == MemcachedKeyEntry(
            key: "k1", expiresAt: nil, flags: nil
        ))
        #expect(MemcachedKeyListing.cachedumpEntry("ITEM user:42 [5 b; 1793500167 s]") == MemcachedKeyEntry(
            key: "user:42", expiresAt: 1_793_500_167, flags: nil
        ))
        #expect(MemcachedKeyListing.cachedumpEntry("STAT pid 1") == nil)
    }

    @Test("Slab classes come from the item counts in stats items")
    func slabClasses() {
        let lines = [
            "STAT items:1:number 3", "STAT items:1:age 10", "STAT items:12:number 1", "STAT items:5:number 0",
        ]
        #expect(MemcachedKeyListing.slabClasses(fromItemStats: lines) == [1, 12])
    }

    @Test("Stat pairs keep a value with spaces whole")
    func statPairs() {
        let pairs = MemcachedKeyListing.statPairs(["STAT version 1.6.45", "STAT slab_reassign_last_busy_status none x"])
        #expect(pairs.map(\.name) == ["version", "slab_reassign_last_busy_status"])
        #expect(pairs.last?.value == "none x")
    }
}

struct MemcachedBrowseSpecTests {
    private let keys = ["user:2", "user:10", "session:a", "User:3"].map {
        MemcachedKeyEntry(key: $0, expiresAt: nil, flags: nil)
    }

    @Test("A spec survives its tagged statement")
    func roundTrip() throws {
        let condition = try MemcachedBrowseSpec.condition(column: "Key", op: "starts with", value: "user:", isCaseSensitive: true)
        let spec = MemcachedBrowseSpec(limit: 50, offset: 100, ascending: false, conditions: [condition])
        #expect(MemcachedBrowseSpec.parse(spec.statement) == spec)
        #expect(MemcachedBrowseSpec.parse("get a") == nil)
    }

    @Test("A page is filtered, sorted by key, then cut")
    func page() throws {
        let condition = try MemcachedBrowseSpec.condition(column: "Key", op: "STARTS WITH", value: "user:", isCaseSensitive: false)
        let spec = MemcachedBrowseSpec(limit: 2, offset: 1, ascending: true, conditions: [condition])
        #expect(try spec.page(of: keys).map(\.key) == ["user:10", "user:2"])
        #expect(try MemcachedBrowseSpec(limit: 10, offset: 9, ascending: true).page(of: keys).isEmpty)
    }

    @Test("Key comparisons", arguments: [
        ("=", "user:2", ["user:2"]),
        ("!=", "user:2", ["User:3", "session:a", "user:10"]),
        ("CONTAINS", "sion", ["session:a"]),
        ("ENDS WITH", ":a", ["session:a"]),
        ("IN", "user:2, session:a", ["session:a", "user:2"]),
        ("NOT IN", "user:2,session:a", ["User:3", "user:10"]),
        ("REGEX", "^user:[0-9]$", ["user:2"]),
    ])
    func comparisons(op: String, value: String, expected: [String]) throws {
        let condition = try MemcachedBrowseSpec.condition(column: "Key", op: op, value: value, isCaseSensitive: true)
        let spec = MemcachedBrowseSpec(limit: 100, offset: 0, ascending: true, conditions: [condition])
        #expect(try spec.page(of: keys).map(\.key) == expected)
    }

    @Test("OR keeps a key any condition matches")
    func orLogic() throws {
        let first = try MemcachedBrowseSpec.condition(column: "Key", op: "=", value: "user:2", isCaseSensitive: true)
        let second = try MemcachedBrowseSpec.condition(column: "Key", op: "=", value: "User:3", isCaseSensitive: true)
        let spec = MemcachedBrowseSpec(limit: 100, offset: 0, ascending: true, conditions: [first, second], matchesAll: false)
        #expect(try spec.page(of: keys).map(\.key) == ["User:3", "user:2"])
    }

    @Test("Only Key filters, and a bad operator or pattern is refused")
    func refusals() {
        #expect(throws: MemcachedFilterRefusal.notKeyColumn("Value")) {
            try MemcachedBrowseSpec.condition(column: "Value", op: "=", value: "x", isCaseSensitive: true)
        }
        #expect(throws: MemcachedFilterRefusal.unsupportedOperator(">")) {
            try MemcachedBrowseSpec.condition(column: "Key", op: ">", value: "x", isCaseSensitive: true)
        }
        #expect(throws: MemcachedFilterRefusal.invalidPattern("[")) {
            try MemcachedBrowseSpec.condition(column: "Key", op: "REGEX", value: "[", isCaseSensitive: true)
        }
        #expect(throws: MemcachedFilterRefusal.emptyList("IN")) {
            try MemcachedBrowseSpec.condition(column: "Key", op: "IN", value: " , ", isCaseSensitive: true)
        }
    }

    @Test("A refusal statement carries its message")
    func refusalStatement() {
        let statement = MemcachedBrowseSpec.refusalStatement("Memcached can only filter by Key.")
        #expect(MemcachedBrowseSpec.refusalMessage(statement) == "Memcached can only filter by Key.")
    }
}
