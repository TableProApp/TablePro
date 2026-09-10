//
//  RowDisplayBox.swift
//  TablePro
//

import Foundation

final class RowDisplayBox {
    var values: ContiguousArray<String?>

    init(_ values: ContiguousArray<String?>) {
        self.values = values
    }
}

@MainActor
final class RowDisplayCache {
    /// A box is a reference and callers mutate one in place before handing it back, so the cost
    /// recorded at insertion is the only number that still describes what was added. Recomputing it
    /// from the box on removal subtracts a different figure than was added and drifts `totalCost`
    /// away from the budget it is there to enforce.
    private struct Entry {
        let box: RowDisplayBox
        let cost: Int
    }

    private var storage: [RowID: Entry] = [:]
    private var insertionOrder: [RowID] = []
    private var insertionHead: Int = 0
    private var totalCost: Int = 0
    private let countLimit: Int
    private let costLimit: Int

    init(countLimit: Int = 50_000, costLimit: Int = 64 * 1_024 * 1_024) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    func box(forID id: RowID) -> RowDisplayBox? {
        storage[id]?.box
    }

    func setBox(_ box: RowDisplayBox, forID id: RowID) {
        let cost = Self.rowCost(box.values)
        if let existing = storage[id] {
            totalCost -= existing.cost
        } else {
            insertionOrder.append(id)
        }
        storage[id] = Entry(box: box, cost: cost)
        totalCost += cost
        evictIfNeeded()
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        insertionHead = 0
        totalCost = 0
    }

    /// Drops one row's formatted values while keeping its box, so the next read
    /// reformats from the current cell values. Row ids are positional, so a row
    /// whose content changed in place keeps its id and would otherwise be served
    /// its pre-edit text.
    func clearValues(forID id: RowID) {
        guard let existing = storage[id] else { return }
        totalCost -= existing.cost
        for index in existing.box.values.indices {
            existing.box.values[index] = nil
        }
        storage[id] = Entry(box: existing.box, cost: 0)
    }

    private func evictIfNeeded() {
        while storage.count > countLimit || totalCost > costLimit {
            guard insertionHead < insertionOrder.count else { break }
            let oldest = insertionOrder[insertionHead]
            insertionHead += 1
            if let removed = storage.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
        if insertionHead > 10_000 {
            insertionOrder.removeFirst(insertionHead)
            insertionHead = 0
        }
    }

    private static func rowCost(_ values: ContiguousArray<String?>) -> Int {
        var total = 0
        for value in values {
            if let value { total &+= value.utf8.count }
        }
        return total
    }
}
