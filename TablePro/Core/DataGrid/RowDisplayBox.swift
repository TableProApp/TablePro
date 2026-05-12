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
    private var storage: [RowID: RowDisplayBox] = [:]
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
        storage[id]
    }

    func setBox(_ box: RowDisplayBox, forID id: RowID, cost: Int) {
        if let existing = storage[id] {
            totalCost -= rowCost(existing.values)
        } else {
            insertionOrder.append(id)
        }
        storage[id] = box
        totalCost += cost
        evictIfNeeded()
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        insertionHead = 0
        totalCost = 0
    }

    private func evictIfNeeded() {
        while storage.count > countLimit || totalCost > costLimit {
            guard insertionHead < insertionOrder.count else { break }
            let oldest = insertionOrder[insertionHead]
            insertionHead += 1
            if let removed = storage.removeValue(forKey: oldest) {
                totalCost -= rowCost(removed.values)
            }
        }
        if insertionHead > 10_000 {
            insertionOrder.removeFirst(insertionHead)
            insertionHead = 0
        }
    }

    private func rowCost(_ values: ContiguousArray<String?>) -> Int {
        var total = 0
        for value in values {
            if let s = value { total &+= s.utf8.count }
        }
        return total
    }
}
