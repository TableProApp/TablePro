//
//  PluginRowBatcher.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Collects a stream's rows into batches cut at a row count or a byte size, whichever comes first. A bounded
// stream buffers a fixed number of batches, so a batch cut by rows alone let one export of wide rows hold the
// table: 300 rows of 1 MiB were one batch. The cost sizes batches only; a read bound counts the payload alone.
nonisolated struct PluginRowBatcher {
    static let defaultRowLimit = 5_000
    static let defaultByteLimit = 1 << 20

    // A cell's slot and a row's array header, so a row of many NULL columns counts too.
    static let cellOverhead = 24
    static let rowOverhead = 32

    let rowLimit: Int
    let byteLimit: Int
    private(set) var rows: [PluginRow] = []
    private(set) var byteCount = 0

    init(rowLimit: Int = defaultRowLimit, byteLimit: Int = defaultByteLimit) {
        self.rowLimit = max(1, rowLimit)
        self.byteLimit = max(1, byteLimit)
        rows.reserveCapacity(min(self.rowLimit, 1_024))
    }

    var isEmpty: Bool { rows.isEmpty }

    var isFull: Bool { rows.count >= rowLimit || byteCount >= byteLimit }

    // True once the batch is full and should be delivered. A row is never split: one over the byte limit ends its batch.
    mutating func append(_ row: PluginRow) -> Bool {
        byteCount += Self.cost(of: row)
        rows.append(row)
        return isFull
    }

    mutating func removeAll() {
        rows.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    // `utf8.count` of a native string is its stored length, so a row costs one step per column.
    static func cost(of row: PluginRow) -> Int {
        var cost = rowOverhead
        for cell in row {
            switch cell {
            case .null: cost += cellOverhead
            case .text(let text): cost += cellOverhead + text.utf8.count
            case .bytes(let data): cost += cellOverhead + data.count
            }
        }
        return cost
    }
}
