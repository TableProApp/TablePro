//
//  LibPQReadBound.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

// Where a read-only read stops: past `rowCap` rows, the extra one telling "exactly" from "more", or at the first row that
// takes the decoded rows past `byteLimit`. That row is kept, so the host sees its own limit was reached.
struct LibPQReadBound: Equatable, Sendable {
    let rowCap: Int
    let byteLimit: Int?

    init(rowCap: Int, byteLimit: Int?) {
        self.rowCap = max(rowCap, 1)
        self.byteLimit = byteLimit.map { max($0, 0) }
    }

    // Nil when neither bound is set, and the caller reads the result whole as it always has.
    static func ifSet(rowCap: Int?, byteLimit: Int?) -> LibPQReadBound? {
        let cap = rowCap.flatMap { $0 > 0 ? $0 : nil }
        guard cap != nil || byteLimit != nil else { return nil }
        return LibPQReadBound(rowCap: cap ?? PluginRowLimits.emergencyMax, byteLimit: byteLimit)
    }

    func isReached(rows: Int, bytes: Int) -> Bool {
        if rows > rowCap { return true }
        guard let byteLimit else { return false }
        return bytes > byteLimit
    }

    // The row that only told "more" goes; a row that crossed the byte limit within the cap stays.
    func kept(_ rows: [[PluginCellValue]]) -> [[PluginCellValue]] {
        rows.count > rowCap ? Array(rows.prefix(rowCap)) : rows
    }

    // The decoded size, at most what the host counts for the same row, so the read never stops before the host's own
    // budget is full.
    static func byteCount(of row: [PluginCellValue]) -> Int {
        row.reduce(0) { total, cell in
            switch cell {
            case .null: total
            case .text(let text): total + text.utf8.count
            case .bytes(let data): total + data.count
            }
        }
    }
}
