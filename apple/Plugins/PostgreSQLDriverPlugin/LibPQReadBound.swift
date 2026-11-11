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

    static let largestFetch = 1_000

    // How many rows the next cursor FETCH asks for, given what was read so far. Without a byte limit, all the cap still
    // allows. With one, a single row first, then as many as the rows so far say still fit: a FETCH cannot be cancelled
    // where the cursor is used, so a batch the limit stops has the rest of its rows drained.
    func nextFetchCount(rows: Int, bytes: Int) -> Int {
        let remaining = max(rowCap - rows + 1, 1)
        guard let byteLimit else { return remaining }
        guard rows > 0 else { return 1 }
        let average = max(bytes / rows, 1)
        let fitting = max(byteLimit - bytes, 0) / average + 1
        return min(remaining, fitting, Self.largestFetch)
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

// The cursor a bounded read-only read goes through where the server takes no cancel. It lives in the read's own
// read-only transaction, whose ROLLBACK closes it, so the rows after the stop are never produced or sent. A FETCH result
// describes the cursor query's own columns, so the column origins survive.
enum LibPQBoundedCursor {
    static let name = "tablepro_bounded_read"
    // A round trip of its own, so a DECLARE the server refuses is undone and the statement can run the plain way.
    static let savepoint = "SAVEPOINT \(name)"
    static let savepointRollback = "ROLLBACK TO SAVEPOINT \(name)"

    // The body on lines of its own, so a trailing `--` comment in it stays a comment.
    static func declaration(of body: String) -> String {
        "DECLARE \(name) NO SCROLL CURSOR FOR\n\(body)\n"
    }

    static func fetch(_ count: Int) -> String {
        "FETCH FORWARD \(count) FROM \(name)"
    }
}
