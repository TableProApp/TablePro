//
//  PluginRowBatcherTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct PluginRowBatcherTests {
    // Feeds rows through a batcher the way a driver's stream loop does and returns the batches it delivered.
    private static func batches(of rows: [PluginRow], batcher: PluginRowBatcher = PluginRowBatcher()) -> [[PluginRow]] {
        var batcher = batcher
        var delivered: [[PluginRow]] = []
        for row in rows where batcher.append(row) {
            delivered.append(batcher.rows)
            batcher.removeAll()
        }
        if !batcher.isEmpty { delivered.append(batcher.rows) }
        return delivered
    }

    private static func ids(_ batches: [[PluginRow]]) -> [String] {
        batches.flatMap { $0.compactMap { $0.first?.asText } }
    }

    @Test("Narrow rows are cut at 5,000 rows, as before")
    func narrowRowsCutByCount() {
        let rows: [PluginRow] = (0..<12_345).map { [.text(String($0)), .text("x")] }
        let delivered = Self.batches(of: rows)
        #expect(delivered.map { $0.count } == [5_000, 5_000, 2_345])
        #expect(Self.ids(delivered) == rows.compactMap { $0.first?.asText })
    }

    @Test("Wide rows are cut at 1 MiB, long before 5,000 rows")
    func wideRowsCutByBytes() {
        let payload = String(repeating: "w", count: 100 * 1_024)
        let rows: [PluginRow] = (0..<40).map { [.text(String($0)), .text(payload)] }
        let delivered = Self.batches(of: rows)
        let perBatch = Int((Double(PluginRowBatcher.defaultByteLimit) / Double(PluginRowBatcher.cost(of: rows[0]))).rounded(.up))
        #expect(delivered.dropLast().allSatisfy { $0.count == perBatch })
        #expect(delivered.allSatisfy { !$0.isEmpty })
        #expect(Self.ids(delivered) == (0..<40).map { String($0) })
    }

    @Test("A row over the byte limit ends its batch whole")
    func oversizedRowAlone() {
        let huge = Data(count: 3 << 20)
        let rows: [PluginRow] = [[.text("a")], [.bytes(huge)], [.text("b")]]
        let delivered = Self.batches(of: rows, batcher: PluginRowBatcher(rowLimit: 100, byteLimit: 1 << 20))
        #expect(delivered.map { $0.count } == [2, 1])
        #expect(delivered[0].last == [.bytes(huge)])
    }

    @Test("A row of NULL columns still costs its slots")
    func nullRowsCount() {
        let row: PluginRow = Array(repeating: .null, count: 500)
        #expect(PluginRowBatcher.cost(of: row) == PluginRowBatcher.rowOverhead + 500 * PluginRowBatcher.cellOverhead)
        let delivered = Self.batches(of: Array(repeating: row, count: 200))
        #expect(delivered.count > 1)
        #expect(delivered.reduce(0) { $0 + $1.count } == 200)
    }

    @Test("Text counts its UTF-8 length and bytes their length")
    func costOfValues() {
        let row: PluginRow = [.text("Hà"), .bytes(Data(count: 10)), .null]
        #expect(PluginRowBatcher.cost(of: row) == PluginRowBatcher.rowOverhead + 3 * PluginRowBatcher.cellOverhead + 3 + 10)
    }

    @Test("Other limits are taken as given, and a limit under one row is one row")
    func otherLimits() {
        let rows: [PluginRow] = (0..<10).map { [.text(String($0))] }
        #expect(Self.batches(of: rows, batcher: PluginRowBatcher(rowLimit: 3)).map { $0.count } == [3, 3, 3, 1])
        #expect(Self.batches(of: rows, batcher: PluginRowBatcher(rowLimit: 0, byteLimit: 0)).map { $0.count }
            == Array(repeating: 1, count: 10))
    }

    @Test("Emptying the batch starts its byte count over")
    func removeAllResetsBytes() {
        var batcher = PluginRowBatcher(rowLimit: 100, byteLimit: 1_000)
        let fullAfterLargeRow = batcher.append([.text(String(repeating: "x", count: 2_000))])
        #expect(fullAfterLargeRow)
        batcher.removeAll()
        #expect(batcher.isEmpty)
        #expect(batcher.byteCount == 0)
        let fullAfterSmallRow = batcher.append([.text("small")])
        #expect(!fullAfterSmallRow)
    }
}
