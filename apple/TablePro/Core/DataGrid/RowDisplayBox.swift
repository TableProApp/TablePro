//
//  RowDisplayBox.swift
//  TablePro
//

import Foundation

final class RowDisplayBox {
    var values: ContiguousArray<String?>
    // A bit per column whose display format produced its text, so the draw reads it without formatting again.
    private var formattedBits: ContiguousArray<UInt64> = []

    init(_ values: ContiguousArray<String?>) {
        self.values = values
    }

    func setText(_ text: String?, at index: Int, isFormatted: Bool) {
        values[index] = text
        let word = index >> 6
        let bit = UInt64(1) << UInt64(index & 63)
        if isFormatted {
            if word >= formattedBits.count {
                formattedBits.append(contentsOf: repeatElement(0, count: word + 1 - formattedBits.count))
            }
            formattedBits[word] |= bit
        } else if word < formattedBits.count {
            formattedBits[word] &= ~bit
        }
    }

    func isFormatted(at index: Int) -> Bool {
        let word = index >> 6
        return index >= 0 && word < formattedBits.count && formattedBits[word] & (UInt64(1) << UInt64(index & 63)) != 0
    }

    func clearText(at index: Int) {
        guard index >= 0, index < values.count else { return }
        setText(nil, at: index, isFormatted: false)
    }

    func clearAllText() {
        for index in values.indices {
            values[index] = nil
        }
        formattedBits.removeAll()
    }
}

@MainActor
final class RowDisplayCache {
    // Callers mutate a box in place, so only the cost recorded at insertion matches what was added to `totalCost`.
    private struct Entry {
        let box: RowDisplayBox
        let cost: Int
    }

    private var storage: [RowID: Entry] = [:]
    private var highlights: [RowID: RowHighlight] = [:]
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

    func highlight(forID id: RowID) -> RowHighlight? {
        highlights[id]
    }

    func setHighlight(_ highlight: RowHighlight, forID id: RowID) {
        if highlights.count >= countLimit {
            highlights.removeAll(keepingCapacity: true)
        }
        highlights[id] = highlight
    }

    func clearHighlight(forID id: RowID) {
        highlights.removeValue(forKey: id)
    }

    func clearHighlights() {
        highlights.removeAll(keepingCapacity: true)
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: true)
        highlights.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        insertionHead = 0
        totalCost = 0
    }

    // Row ids are positional: a row edited in place keeps its id and would otherwise be served its pre-edit text.
    func clearValues(forID id: RowID) {
        highlights.removeValue(forKey: id)
        guard let existing = storage[id] else { return }
        totalCost -= existing.cost
        existing.box.clearAllText()
        storage[id] = Entry(box: existing.box, cost: 0)
    }

    // For a display format change: every other column's text is still right.
    func clearValues(forDataIndexes dataIndexes: Set<Int>) {
        guard !dataIndexes.isEmpty else { return }
        highlights.removeAll(keepingCapacity: true)
        storage = storage.mapValues { entry in
            for index in dataIndexes {
                entry.box.clearText(at: index)
            }
            let cost = Self.rowCost(entry.box.values)
            totalCost += cost - entry.cost
            return Entry(box: entry.box, cost: cost)
        }
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
