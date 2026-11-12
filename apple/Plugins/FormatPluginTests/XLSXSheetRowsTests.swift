//
//  XLSXSheetRowsTests.swift
//  FormatPluginTests
//

import Foundation
import Testing

struct XLSXSheetRowsTests {
    private typealias Chunk = XLSXSheetRows.Chunk

    @Test("One batch past several sheets fills each to the limit, header included")
    func oneBatchFillsSeveralSheets() {
        var sheets = XLSXSheetRows(limit: 5, headerRowCount: 1)

        #expect(sheets.chunks(of: 12) == [
            Chunk(rows: 0..<4, startsNewSheet: false),
            Chunk(rows: 4..<8, startsNewSheet: true),
            Chunk(rows: 8..<12, startsNewSheet: true),
        ])
    }

    @Test("A batch that fills a sheet exactly starts the next sheet only when another row comes")
    func exactFillStartsNoEmptySheet() {
        var sheets = XLSXSheetRows(limit: 5, headerRowCount: 1)

        #expect(sheets.chunks(of: 4) == [Chunk(rows: 0..<4, startsNewSheet: false)])
        #expect(sheets.chunks(of: 0).isEmpty)
        #expect(sheets.chunks(of: 1) == [Chunk(rows: 0..<1, startsNewSheet: true)])
    }

    @Test("Batches add up across calls, and without a header a sheet holds the whole limit")
    func batchesAddUpWithoutHeader() {
        var sheets = XLSXSheetRows(limit: 5, headerRowCount: 0)

        #expect(sheets.chunks(of: 3) == [Chunk(rows: 0..<3, startsNewSheet: false)])
        #expect(sheets.chunks(of: 9) == [
            Chunk(rows: 0..<2, startsNewSheet: false),
            Chunk(rows: 2..<7, startsNewSheet: true),
            Chunk(rows: 7..<9, startsNewSheet: true),
        ])
    }
}
