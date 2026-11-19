//
//  RowPositions.swift
//  TablePro
//

import Foundation

// Where each row id sits. A result's rows arrive as `.existing(n)` in order, so that run is two integers; only the
// rows outside it are hashed.
struct RowPositions: Sendable {
    private var runStart = 0
    private var runCount = 0
    private var others: [RowID: Int] = [:]

    init() {}

    init(of rows: ContiguousArray<Row>) {
        for (position, row) in rows.enumerated() {
            append(row.id, at: position)
        }
    }

    // The rows a lookup has to hash, which is none for a result read in order.
    var hashedCount: Int { others.count }

    // A repeated id resolves to its last position: every position after the run is in `others`.
    subscript(id: RowID) -> Int? {
        if let position = others[id] { return position }
        guard case .existing(let key) = id else { return nil }
        let (position, overflow) = key.subtractingReportingOverflow(runStart)
        guard !overflow, position >= 0, position < runCount else { return nil }
        return position
    }

    mutating func append(_ id: RowID, at position: Int) {
        if others.isEmpty, position == runCount, case .existing(let key) = id,
           runCount == 0 || key == runStart &+ runCount {
            if runCount == 0 { runStart = key }
            runCount += 1
        } else {
            others[id] = position
        }
    }

    // For rows inserted, removed or moved at `position` or after it.
    mutating func reindex(from position: Int, in rows: ContiguousArray<Row>) {
        let start = max(position, 0)
        runCount = min(runCount, start)
        if !others.isEmpty {
            others = others.filter { $0.value < start }
        }
        for index in stride(from: start, to: rows.count, by: 1) {
            append(rows[index].id, at: index)
        }
    }
}
