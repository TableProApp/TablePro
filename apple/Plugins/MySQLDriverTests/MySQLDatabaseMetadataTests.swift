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

    private func unconnectedDriver() -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "", additionalFields: [:]
        ))
    }

    @Test("The table listing adds each table's engine, create time and update time after its index size")
    func listingCarriesEngineAndTimes() throws {
        let statement = try #require(unconnectedDriver().allTablesMetadataSQL(schema: "shop"))

        let indexSize = try #require(statement.range(of: "as index_size"))
        let engine = try #require(statement.range(of: "ENGINE as engine"))
        let created = try #require(statement.range(of: "CREATE_TIME as create_time"))
        let updated = try #require(statement.range(of: "UPDATE_TIME as update_time"))
        let comment = try #require(statement.range(of: "TABLE_COMMENT as comment"))
        #expect(indexSize.upperBound < engine.lowerBound)
        #expect(engine.upperBound < created.lowerBound)
        #expect(created.upperBound < updated.lowerBound)
        #expect(updated.upperBound < comment.lowerBound)
    }

    // SHOW TABLE STATUS already answers Engine, Create_time and Update_time.
    @Test("A server without the catalog keeps its SHOW TABLE STATUS listing as it was")
    func tableStatusFallbackIsUnchanged() {
        #expect(MySQLPluginDriver.tableStatusStatement(database: "shop") == "SHOW TABLE STATUS FROM `shop`")
        #expect(MySQLPluginDriver.tableStatusStatement(database: "") == "SHOW TABLE STATUS")
    }
}
