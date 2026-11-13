//
//  ResultSnapshotBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProPluginKit
import Testing

struct ResultSnapshotBuilderTests {
    private func cell(_ value: PluginCellValue, _ type: ColumnType) -> OpenAPIValueContainer {
        SnapshotCellEncoder.encode(value, type: type).value
    }

    @Test("A safe integer stays a JSON number")
    func safeIntegerIsNumber() {
        #expect(cell(.text("42"), .integer(rawType: "int")) == OpenAPIValueContainer(integerLiteral: 42))
        #expect(cell(.text("42.0"), .integer(rawType: "int")) == OpenAPIValueContainer(integerLiteral: 42))
        #expect(cell(.text("9007199254740991"), .integer(rawType: "bigint")) == OpenAPIValueContainer(integerLiteral: 9_007_199_254_740_991))
    }

    @Test("An integer past 2^53 is a string, lossless")
    func bigIntegerIsString() {
        #expect(cell(.text("9007199254740993"), .integer(rawType: "bigint")) == OpenAPIValueContainer(stringLiteral: "9007199254740993"))
        #expect(cell(.text("-12345678901234567890"), .integer(rawType: "numeric")) == OpenAPIValueContainer(stringLiteral: "-12345678901234567890"))
    }

    @Test("A decimal that round-trips is a number; high precision is a string")
    func decimalPrecision() {
        #expect(cell(.text("3.14"), .decimal(rawType: "double")) == OpenAPIValueContainer(floatLiteral: 3.14))
        #expect(cell(.text("0.12345678901234567890123"), .decimal(rawType: "numeric")) == OpenAPIValueContainer(stringLiteral: "0.12345678901234567890123"))
    }

    @Test("Booleans normalize, including TINYINT(1) values")
    func booleans() {
        #expect(cell(.text("1"), .boolean(rawType: "bool")) == OpenAPIValueContainer(booleanLiteral: true))
        #expect(cell(.text("false"), .boolean(rawType: "bool")) == OpenAPIValueContainer(booleanLiteral: false))
        #expect(cell(.text("2"), .boolean(rawType: "tinyint")) == OpenAPIValueContainer(integerLiteral: 2))
    }

    @Test("Null, bytes and text")
    func otherTypes() {
        #expect(cell(.null, .text(rawType: nil)) == OpenAPIValueContainer(nilLiteral: ()))
        #expect(cell(.bytes(Data(count: 1_024)), .blob(rawType: "blob")) == OpenAPIValueContainer(stringLiteral: "(binary, 1024 bytes)"))
        #expect(cell(.text("hello"), .text(rawType: "text")) == OpenAPIValueContainer(stringLiteral: "hello"))
        #expect(cell(.text("{\"a\":1}"), .json(rawType: "json")) == OpenAPIValueContainer(stringLiteral: "{\"a\":1}"))
    }

    @Test("A huge text cell is capped")
    func longTextCapped() {
        let huge = String(repeating: "x", count: 200_000)
        let encoded = SnapshotCellEncoder.encode(.text(huge), type: .text(rawType: "text"))
        #expect(encoded.byteCount < huge.utf8.count)
        #expect(encoded.value == OpenAPIValueContainer(stringLiteral: String(huge.prefix(ResultSnapshotBuilder.maxCellBytes / 4)) + "…"))
    }

    private func output(columns: [String], types: [ColumnType], rows: [[PluginCellValue]]) -> DisplayedResultReader.Output {
        DisplayedResultReader.Output(columns: columns, columnTypes: types, rows: rows, skippedDeletedCount: 0)
    }

    @Test("row_count and truncated reflect a result cut short")
    func truncationFlags() {
        let read = output(columns: ["n"], types: [.integer(rawType: "int")], rows: [[.text("1")], [.text("2")]])
        let built = ResultSnapshotBuilder.build(from: read, totalRowCount: 500, moreRowsAvailable: true)
        #expect(built.rowsSent == 2)
        #expect(built.snapshot.rowCount == 500)
        #expect(built.snapshot.truncated == true)
    }

    @Test("A fully loaded result is not truncated and omits row_count")
    func notTruncated() {
        let read = output(columns: ["n"], types: [.integer(rawType: "int")], rows: [[.text("1")], [.text("2")]])
        let built = ResultSnapshotBuilder.build(from: read, totalRowCount: 2, moreRowsAvailable: false)
        #expect(built.snapshot.truncated == false)
        #expect(built.snapshot.rowCount == nil)
    }

    @Test("Rows past the cap are dropped and marked truncated")
    func rowCap() {
        let rows = Array(repeating: [PluginCellValue.text("1")], count: ResultSnapshotBuilder.maxRows + 50)
        let read = output(columns: ["n"], types: [.integer(rawType: "int")], rows: rows)
        let built = ResultSnapshotBuilder.build(from: read, totalRowCount: nil, moreRowsAvailable: false)
        #expect(built.rowsSent == ResultSnapshotBuilder.maxRows)
        #expect(built.snapshot.truncated == true)
    }

    @Test("Columns past the cap are dropped and marked truncated")
    func columnCap() {
        let count = ResultSnapshotBuilder.maxColumns + 5
        let columns = (0 ..< count).map { "c\($0)" }
        let types = Array(repeating: ColumnType.text(rawType: "text"), count: count)
        let row = Array(repeating: PluginCellValue.text("x"), count: count)
        let built = ResultSnapshotBuilder.build(from: output(columns: columns, types: types, rows: [row]), totalRowCount: nil, moreRowsAvailable: false)
        #expect(built.snapshot.columns.count == ResultSnapshotBuilder.maxColumns)
        #expect(built.snapshot.rows.first??.count == ResultSnapshotBuilder.maxColumns)
        #expect(built.snapshot.truncated == true)
    }
}
