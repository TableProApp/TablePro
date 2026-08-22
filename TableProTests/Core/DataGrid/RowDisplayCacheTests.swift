//
//  RowDisplayCacheTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("RowDisplayCache")
@MainActor
struct RowDisplayCacheTests {
    private func makeBox(_ values: [String?]) -> RowDisplayBox {
        RowDisplayBox(ContiguousArray(values))
    }

    @Test("Empty cache returns nil for any lookup")
    func emptyLookup() {
        let cache = RowDisplayCache()
        #expect(cache.box(forID: .existing(0)) == nil)
        #expect(cache.box(forID: .existing(100)) == nil)
    }

    @Test("Inserted box is retrievable")
    func basicSetGet() {
        let cache = RowDisplayCache()
        let id = RowID.existing(42)
        let box = makeBox(["a", "b", "c"])
        cache.setBox(box, forID: id)

        #expect(cache.box(forID: id) === box)
    }

    @Test("Count limit evicts oldest entries first (FIFO)")
    func countLimitEvictsFIFO() {
        let cache = RowDisplayCache(countLimit: 3, costLimit: 1_000_000)
        for index in 1...3 {
            cache.setBox(makeBox(["row\(index)"]), forID: .existing(index))
        }
        #expect(cache.box(forID: .existing(1)) != nil)

        // Fourth insertion should evict the first.
        cache.setBox(makeBox(["row4"]), forID: .existing(4))
        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
        #expect(cache.box(forID: .existing(3)) != nil)
        #expect(cache.box(forID: .existing(4)) != nil)
    }

    @Test("Cost limit evicts even when count is under limit")
    func costLimitEvicts() {
        let cache = RowDisplayCache(countLimit: 1_000, costLimit: 10)
        // First insert costs 6; under cap.
        cache.setBox(makeBox(["abcdef"]), forID: .existing(1))
        // Second insert costs 6 more; total 12 > 10, evicts first.
        cache.setBox(makeBox(["123456"]), forID: .existing(2))

        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
    }

    @Test("Updating the same mutable box uses its previously recorded cost")
    func mutableBoxCostUpdateEvicts() {
        let cache = RowDisplayCache(countLimit: 1_000, costLimit: 10)
        let firstID = RowID.existing(1)
        let box = makeBox(["a"])
        cache.setBox(box, forID: firstID)

        box.values[0] = "123456789"
        cache.setBox(box, forID: firstID)
        cache.setBox(makeBox(["xy"]), forID: .existing(2))

        #expect(cache.box(forID: firstID) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
    }

    @Test("Replacing an existing key does not consume queue slot")
    func replaceExistingKey() {
        let cache = RowDisplayCache(countLimit: 2, costLimit: 1_000_000)
        cache.setBox(makeBox(["v1"]), forID: .existing(1))
        cache.setBox(makeBox(["v2"]), forID: .existing(2))

        // Replace id=1 without expanding the cache.
        cache.setBox(makeBox(["v1-updated"]), forID: .existing(1))
        #expect(cache.box(forID: .existing(1))?.values.first == "v1-updated")
        #expect(cache.box(forID: .existing(2))?.values.first == "v2")

        // Adding a new entry now evicts the oldest in insertion order (still id=1
        // because replacing did not re-add it to the order).
        cache.setBox(makeBox(["v3"]), forID: .existing(3))
        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
        #expect(cache.box(forID: .existing(3)) != nil)
    }

    @Test("removeAll empties the cache and resets state")
    func removeAllResetsState() {
        let cache = RowDisplayCache()
        for index in 1...10 {
            cache.setBox(makeBox(["x"]), forID: .existing(index))
        }
        cache.removeAll()
        for index in 1...10 {
            #expect(cache.box(forID: .existing(index)) == nil)
        }

        // Cache continues to work after removeAll.
        cache.setBox(makeBox(["fresh"]), forID: .existing(100))
        #expect(cache.box(forID: .existing(100))?.values.first == "fresh")
    }

    @Test("Clearing a row drops its formatted values and keeps the box")
    func clearValuesDropsFormattedText() throws {
        let cache = RowDisplayCache()
        let id = RowID.existing(1)
        let box = makeBox(["old", "VARCHAR(255)", "YES"])
        cache.setBox(box, forID: id)

        cache.clearValues(forID: id)

        let cleared = try #require(cache.box(forID: id))
        #expect(cleared === box)
        #expect(cleared.values.count == 3)
        #expect(cleared.values.allSatisfy { $0 == nil })
    }

    @Test("Clearing one row leaves the others formatted")
    func clearValuesLeavesOtherRows() throws {
        let cache = RowDisplayCache()
        cache.setBox(makeBox(["a"]), forID: .existing(0))
        cache.setBox(makeBox(["b"]), forID: .existing(1))

        cache.clearValues(forID: .existing(1))

        let kept = try #require(cache.box(forID: .existing(0)))
        #expect(kept.values[0] == "a")
        let cleared = try #require(cache.box(forID: .existing(1)))
        #expect(cleared.values[0] == nil)
    }

    @Test("Clearing an uncached row does nothing")
    func clearValuesForUnknownRow() {
        let cache = RowDisplayCache()
        cache.setBox(makeBox(["a"]), forID: .existing(0))

        cache.clearValues(forID: .existing(9))

        #expect(cache.box(forID: .existing(9)) == nil)
        #expect(cache.box(forID: .existing(0))?.values.first == "a")
    }

    @Test("A cleared row accepts fresh values and keeps serving them")
    func clearedRowRefills() {
        let cache = RowDisplayCache()
        let id = RowID.existing(2)
        let box = makeBox(["old"])
        cache.setBox(box, forID: id)
        cache.clearValues(forID: id)

        box.values[0] = "new"
        cache.setBox(box, forID: id)

        #expect(cache.box(forID: id)?.values.first == "new")
    }

    @Test("Refilling a cleared mutable box restores its recorded cost")
    func clearedRowRefillRestoresCost() {
        let cache = RowDisplayCache(countLimit: 1_000, costLimit: 10)
        let firstID = RowID.existing(1)
        let box = makeBox(["123456789"])
        cache.setBox(box, forID: firstID)
        cache.clearValues(forID: firstID)
        cache.setBox(makeBox(["abcdefghij"]), forID: .existing(2))

        box.values[0] = "123456789"
        cache.setBox(box, forID: firstID)

        #expect(cache.box(forID: firstID) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
    }

    @Test("Cost comes from the box, so a grown row is charged what it now holds")
    func costIsDerivedFromTheBox() {
        let cache = RowDisplayCache(countLimit: 1_000, costLimit: 10)
        let grown = makeBox(["a"])
        cache.setBox(grown, forID: .existing(1))

        grown.values[0] = "12345678901234567890"
        cache.setBox(grown, forID: .existing(1))

        #expect(cache.box(forID: .existing(1)) == nil)
    }

    @Test("Inserted row IDs of both kinds round-trip")
    func mixedRowIDKinds() {
        let cache = RowDisplayCache()
        let existingID = RowID.existing(5)
        let insertedID = RowID.inserted(UUID())
        cache.setBox(makeBox(["existing"]), forID: existingID)
        cache.setBox(makeBox(["inserted"]), forID: insertedID)
        #expect(cache.box(forID: existingID)?.values.first == "existing")
        #expect(cache.box(forID: insertedID)?.values.first == "inserted")
    }
}
