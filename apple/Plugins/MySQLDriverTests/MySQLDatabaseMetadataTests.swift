//
//  MySQLDatabaseMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLDatabaseMetadataTests {
    // SHOW TABLE STATUS puts Data_length at column 6 and Index_length at column 8.
    private func statusRow(data: String?, index: String?) -> [PluginCellValue] {
        var cells: [String?] = Array(repeating: nil, count: 18)
        cells[0] = "orders"
        cells[6] = data
        cells[8] = index
        return cells.map(PluginCellValue.fromOptional)
    }

    @Test("A database's size adds every table's data and index lengths")
    func sumsLengths() {
        let rows = [statusRow(data: "16384", index: "32768"), statusRow(data: "100", index: nil)]
        #expect(MySQLPluginDriver.tableStatusSizeBytes(rows) == 49_252)
        #expect(MySQLPluginDriver.tableStatusSizeBytes([]) == 0)
    }

    @Test("Lengths whose total passes Int64 stop at its end instead of crashing")
    func hugeLengthsSaturate() {
        let rows = [statusRow(data: "9223372036854775807", index: "1"), statusRow(data: "5", index: "5")]
        #expect(MySQLPluginDriver.tableStatusSizeBytes(rows) == Int64.max)
    }

    @Test("A table's total size is its data length plus its index length")
    func tableTotalAddsLengths() {
        let metadata = MySQLTableStatusRow.metadata(from: statusRow(data: "16384", index: "32768"), tableName: "orders")
        #expect(metadata.dataSize == 16_384)
        #expect(metadata.indexSize == 32_768)
        #expect(metadata.totalSize == 49_152)
    }

    @Test("A table whose two lengths pass Int64 together reads its total as the end of the range instead of crashing")
    func tableTotalSaturates() {
        let row = statusRow(data: "9223372036854775807", index: "9223372036854775807")
        let metadata = MySQLTableStatusRow.metadata(from: row, tableName: "orders")
        #expect(metadata.dataSize == Int64.max)
        #expect(metadata.indexSize == Int64.max)
        #expect(metadata.totalSize == Int64.max)
    }
}
