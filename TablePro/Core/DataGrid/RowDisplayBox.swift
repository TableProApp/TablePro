//
//  RowDisplayBox.swift
//  TablePro
//

import Foundation

final class RowDisplayBox {
    private enum CachedValue {
        case text(String)
        case empty
    }

    private var valuesByColumn: [Int: CachedValue] = [:]
    private(set) var cost: Int = 0

    init(_ values: ContiguousArray<String?> = []) {
        valuesByColumn.reserveCapacity(values.count)
        for (column, value) in values.enumerated() {
            setValue(value, at: column)
        }
    }

    var cachedColumnCount: Int {
        valuesByColumn.count
    }

    func containsValue(at column: Int) -> Bool {
        valuesByColumn[column] != nil
    }

    func value(at column: Int) -> String? {
        guard let value = valuesByColumn[column] else { return nil }
        switch value {
        case .text(let text):
            return text
        case .empty:
            return nil
        }
    }

    func setValue(_ value: String?, at column: Int) {
        guard column >= 0 else { return }
        if case .text(let previous)? = valuesByColumn[column] {
            cost -= previous.utf8.count
        }
        if let value {
            valuesByColumn[column] = .text(value)
            cost += value.utf8.count
        } else {
            valuesByColumn[column] = .empty
        }
    }

    func invalidateValue(at column: Int) {
        guard let previous = valuesByColumn.removeValue(forKey: column) else { return }
        if case .text(let previous) = previous {
            cost -= previous.utf8.count
        }
    }

    func removeAllValues() {
        valuesByColumn.removeAll(keepingCapacity: true)
        cost = 0
    }
}

@MainActor
final class RowDisplayCache {
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
        if let existing = storage[id] {
            totalCost -= existing.cost
        } else {
            insertionOrder.append(id)
        }
        storage[id] = Entry(box: box, cost: box.cost)
        totalCost += box.cost
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
        guard let entry = storage[id] else { return }
        totalCost -= entry.cost
        entry.box.removeAllValues()
        storage[id] = Entry(box: entry.box, cost: entry.box.cost)
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
}
