//
//  XLSXSheetRows.swift
//  XLSXExportPlugin
//

import Foundation

// Splits incoming rows across sheets of at most `limit` rows, the header included. A batch can be a whole in-memory
// result, so one overflow can need several new sheets.
struct XLSXSheetRows {
    struct Chunk: Equatable {
        let rows: Range<Int>
        let startsNewSheet: Bool
    }

    let limit: Int
    let headerRowCount: Int
    private(set) var rowsInSheet: Int

    init(limit: Int, headerRowCount: Int) {
        self.limit = limit
        self.headerRowCount = headerRowCount
        self.rowsInSheet = headerRowCount
    }

    // A new sheet starts only when a row needs it, so a batch that fills a sheet exactly leaves no empty one.
    mutating func chunks(of count: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var start = 0
        while start < count {
            var startsNewSheet = false
            if rowsInSheet >= limit {
                rowsInSheet = headerRowCount
                startsNewSheet = true
            }
            let end = min(count, start + max(1, limit - rowsInSheet))
            chunks.append(Chunk(rows: start..<end, startsNewSheet: startsNewSheet))
            rowsInSheet += end - start
            start = end
        }
        return chunks
    }
}
