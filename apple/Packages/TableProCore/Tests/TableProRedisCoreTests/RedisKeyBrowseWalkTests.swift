import Foundation
import TableProRedisCore
import Testing

struct RedisKeyBrowseWalkTests {
    private static let scope = RedisKeyBrowseWalk.Scope(database: 0, pattern: "user:*", type: nil)

    @Test("Each load is sorted on its own, so the rows of a page already shown keep their place")
    func loadsKeepEarlierOrder() {
        var walk = RedisKeyBrowseWalk(scope: Self.scope)
        walk.absorb(keys: ["d", "b"], nextCursor: "17")
        walk.absorb(keys: ["c"], nextCursor: "42")
        walk.finishLoad()
        #expect(walk.page(offset: 0, limit: 2) == ["b", "c"])
        walk.absorb(keys: ["a", "e"], nextCursor: "0")
        walk.finishLoad()
        #expect(walk.keys == ["b", "c", "d", "a", "e"])
        #expect(walk.page(offset: 0, limit: 2) == ["b", "c"])
        #expect(walk.page(offset: 2, limit: 2) == ["d", "a"])
        #expect(walk.isComplete)
    }

    @Test("A key SCAN returns twice is listed once")
    func duplicatesAreDropped() {
        var walk = RedisKeyBrowseWalk(scope: Self.scope)
        walk.absorb(keys: ["a", "b", "a"], nextCursor: "5")
        walk.absorb(keys: ["b", "c"], nextCursor: "0")
        walk.finishLoad()
        #expect(walk.keys == ["a", "b", "c"])
    }

    @Test("The walk asks for more only while the server may hold more and the page is not full")
    func needsKeys() {
        var walk = RedisKeyBrowseWalk(scope: Self.scope)
        #expect(walk.needsKeys(through: 1))
        walk.absorb(keys: ["a", "b"], nextCursor: "9")
        #expect(!walk.needsKeys(through: 2))
        #expect(walk.needsKeys(through: 3))
        #expect(walk.cursor == "9")
        walk.absorb(keys: [], nextCursor: "0")
        #expect(!walk.needsKeys(through: 3))
    }

    @Test("A page past what the walk loaded is empty, never out of range")
    func pagePastTheEnd() {
        var walk = RedisKeyBrowseWalk(scope: Self.scope)
        walk.absorb(keys: ["a"], nextCursor: "0")
        walk.finishLoad()
        #expect(walk.page(offset: 5, limit: 10).isEmpty)
        #expect(walk.page(offset: -1, limit: 10) == ["a"])
        #expect(walk.page(offset: 0, limit: 0).isEmpty)
    }

    @Test("A later or earlier page continues the walk; the first page and the page on screen start over")
    func continuation() {
        var walk = RedisKeyBrowseWalk(scope: Self.scope)
        #expect(!walk.continues(atOffset: 0))
        #expect(walk.continues(atOffset: 50))
        walk.servedOffset = 50
        #expect(!walk.continues(atOffset: 50))
        #expect(walk.continues(atOffset: 100))
        #expect(walk.continues(atOffset: 25))
        #expect(!walk.continues(atOffset: 0))
    }
}
