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

    private func cost(of values: [String?]) -> Int {
        var total = 0
        for v in values {
            if let s = v { total &+= s.utf8.count }
        }
        return total
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
        let values = ["a", "b", "c"]
        let box = makeBox(values)
        cache.setBox(box, forID: id, cost: cost(of: values))

        #expect(cache.box(forID: id) === box)
    }

    @Test("Count limit evicts oldest entries first (FIFO)")
    func countLimitEvictsFIFO() {
        let cache = RowDisplayCache(countLimit: 3, costLimit: 1_000_000)
        for index in 1...3 {
            cache.setBox(makeBox(["row\(index)"]), forID: .existing(index), cost: 4)
        }
        #expect(cache.box(forID: .existing(1)) != nil)

        // Fourth insertion should evict the first.
        cache.setBox(makeBox(["row4"]), forID: .existing(4), cost: 4)
        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
        #expect(cache.box(forID: .existing(3)) != nil)
        #expect(cache.box(forID: .existing(4)) != nil)
    }

    @Test("Cost limit evicts even when count is under limit")
    func costLimitEvicts() {
        let cache = RowDisplayCache(countLimit: 1_000, costLimit: 10)
        // First insert costs 6; under cap.
        cache.setBox(makeBox(["abcdef"]), forID: .existing(1), cost: 6)
        // Second insert costs 6 more; total 12 > 10, evicts first.
        cache.setBox(makeBox(["123456"]), forID: .existing(2), cost: 6)

        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
    }

    @Test("Replacing an existing key does not consume queue slot")
    func replaceExistingKey() {
        let cache = RowDisplayCache(countLimit: 2, costLimit: 1_000_000)
        cache.setBox(makeBox(["v1"]), forID: .existing(1), cost: 2)
        cache.setBox(makeBox(["v2"]), forID: .existing(2), cost: 2)

        // Replace id=1 without expanding the cache.
        cache.setBox(makeBox(["v1-updated"]), forID: .existing(1), cost: 10)
        #expect(cache.box(forID: .existing(1))?.values.first == "v1-updated")
        #expect(cache.box(forID: .existing(2))?.values.first == "v2")

        // Adding a new entry now evicts the oldest in insertion order (still id=1
        // because replacing did not re-add it to the order).
        cache.setBox(makeBox(["v3"]), forID: .existing(3), cost: 2)
        #expect(cache.box(forID: .existing(1)) == nil)
        #expect(cache.box(forID: .existing(2)) != nil)
        #expect(cache.box(forID: .existing(3)) != nil)
    }

    @Test("removeAll empties the cache and resets state")
    func removeAllResetsState() {
        let cache = RowDisplayCache()
        for index in 1...10 {
            cache.setBox(makeBox(["x"]), forID: .existing(index), cost: 1)
        }
        cache.removeAll()
        for index in 1...10 {
            #expect(cache.box(forID: .existing(index)) == nil)
        }

        // Cache continues to work after removeAll.
        cache.setBox(makeBox(["fresh"]), forID: .existing(100), cost: 5)
        #expect(cache.box(forID: .existing(100))?.values.first == "fresh")
    }

    @Test("Inserted row IDs of both kinds round-trip")
    func mixedRowIDKinds() {
        let cache = RowDisplayCache()
        let existingID = RowID.existing(5)
        let insertedID = RowID.inserted(UUID())
        cache.setBox(makeBox(["existing"]), forID: existingID, cost: 8)
        cache.setBox(makeBox(["inserted"]), forID: insertedID, cost: 8)
        #expect(cache.box(forID: existingID)?.values.first == "existing")
        #expect(cache.box(forID: insertedID)?.values.first == "inserted")
    }
}
