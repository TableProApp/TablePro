//
//  ShareSnapshotBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ShareSnapshotBuilderTests {
    private func cell(_ value: PluginCellValue, _ type: ColumnType) -> ShareCell {
        ShareCellEncoder.encode(value, type: type)
    }

    private func source(
        columns: [String] = ["n"],
        types: [ColumnType] = [.integer(rawType: "int")],
        rows: [[PluginCellValue]],
        total: Int? = nil
    ) -> ShareResultSource {
        ShareResultSource(columns: columns, columnTypes: types, rows: rows, totalRowCount: total ?? rows.count)
    }

    private func snapshot(_ outcome: ShareSnapshotOutcome) throws -> ShareSnapshot {
        try #require(outcome.built)
    }

    @Test("Integers inside the JavaScript safe range stay numbers")
    func safeIntegersAreNumbers() {
        #expect(cell(.text("42"), .integer(rawType: "int")) == .integer(42))
        #expect(cell(.text("42.0"), .integer(rawType: "int")) == .integer(42))
        #expect(cell(.text("9007199254740991"), .integer(rawType: "bigint")) == .integer(9_007_199_254_740_991))
        #expect(cell(.text("-9007199254740991"), .integer(rawType: "bigint")) == .integer(-9_007_199_254_740_991))
    }

    @Test("Integers past 2^53 - 1 travel as strings with every digit")
    func wideIntegersAreStrings() {
        #expect(cell(.text("9007199254740992"), .integer(rawType: "bigint")) == .string("9007199254740992"))
        #expect(cell(.text("-9007199254740993"), .integer(rawType: "bigint")) == .string("-9007199254740993"))
        #expect(cell(.text("123456789012345678901234567890"), .integer(rawType: "numeric")) == .string("123456789012345678901234567890"))
    }

    @Test("A decimal a browser prints the same way is a number", arguments: ["3.14", "19.99", "0.5", "-2.25", "5", "100"])
    func roundTrippingDecimalsAreNumbers(text: String) {
        guard case .double(let value) = cell(.text(text), .decimal(rawType: "double")) else {
            Issue.record("\(text) should stay a number")
            return
        }
        #expect(ShareCellEncoder.javaScriptText(of: value) == JsonNumberNormalizer.numberLiteral(from: text))
    }

    @Test("A decimal a browser would print differently travels as a string", arguments: [
        ("0.12345678901234567890123", "0.12345678901234567890123"),
        ("3.10", "3.10"),
        ("12345678901234567.5", "12345678901234567.5"),
        ("1e5", "1e5")
    ])
    func lossyDecimalsAreStrings(text: String, expected: String) {
        #expect(cell(.text(text), .decimal(rawType: "numeric")) == .string(expected))
    }

    @Test("JavaScript number text matches ECMAScript Number::toString", arguments: [
        (0.1, "0.1"), (5.0, "5"), (100_000.0, "100000"), (1e21, "1e+21"), (1e-7, "1e-7"),
        (1.5e-7, "1.5e-7"), (0.000001, "0.000001"), (123.456, "123.456"), (-2.5, "-2.5"), (1e16, "10000000000000000")
    ])
    func javaScriptText(value: Double, expected: String) {
        #expect(ShareCellEncoder.javaScriptText(of: value) == expected)
    }

    @Test("Booleans normalize and a TINYINT(1) value outside 0 and 1 stays an integer")
    func booleans() {
        #expect(cell(.text("1"), .boolean(rawType: "tinyint(1)")) == .bool(true))
        #expect(cell(.text("t"), .boolean(rawType: "bool")) == .bool(true))
        #expect(cell(.text("false"), .boolean(rawType: "bool")) == .bool(false))
        #expect(cell(.text("2"), .boolean(rawType: "tinyint(1)")) == .integer(2))
    }

    @Test("Null stays null, bytes say how many, text and JSON stay text")
    func otherCells() {
        #expect(cell(.null, .text(rawType: nil)) == .null)
        #expect(cell(.bytes(Data(count: 1_024)), .blob(rawType: "blob")) == .string("(binary, 1024 bytes)"))
        #expect(cell(.text("hello"), .text(rawType: "text")) == .string("hello"))
        #expect(cell(.text("{\"a\":1}"), .json(rawType: "jsonb")) == .string("{\"a\":1}"))
        #expect(cell(.text("2026-11-13 10:00:00"), .timestamp(rawType: "timestamp")) == .string("2026-11-13 10:00:00"))
    }

    @Test("Rows past max_rows are cut and the true total is kept")
    func rowsAreCappedToTheLimit() throws {
        let rows = (0..<1_500).map { [PluginCellValue.text(String($0))] }
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: rows, total: 48_210), maxRows: 1_000))

        #expect(built.rows.count == 1_000)
        #expect(built.rowCount == 48_210)
        #expect(built.isTruncated)
        #expect(built.rows.last == [.integer(999)])
    }

    @Test("A result inside the limit is not truncated")
    func smallResultIsWhole() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: [[.text("1")], [.text("2")]]), maxRows: 1_000))

        #expect(built.rows.count == 2)
        #expect(built.rowCount == 2)
        #expect(!built.isTruncated)
    }

    @Test("The reported total is never less than the rows sent")
    func totalCoversTheRows() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: [[.text("1")], [.text("2")]], total: 0), maxRows: 10))
        #expect(built.rowCount == 2)
    }

    @Test("Columns carry their raw type, or the type's name when the driver gave none")
    func columnTypes() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(source(
            columns: ["id", "price"],
            types: [.integer(rawType: "bigint"), .decimal(rawType: nil)],
            rows: [[.text("1"), .text("2.5")]]
        ), maxRows: 10))

        #expect(built.columns == [
            ShareSnapshot.Column(name: "id", type: "bigint"),
            ShareSnapshot.Column(name: "price", type: "decimal")
        ])
    }

    @Test("More columns than the server takes is too large to share")
    func tooManyColumns() {
        let count = ShareSnapshotBuilder.maxColumns + 1
        let built = ShareSnapshotBuilder.build(source(
            columns: (0..<count).map { "c\($0)" },
            types: Array(repeating: .text(rawType: "text"), count: count),
            rows: [Array(repeating: .text("x"), count: count)]
        ), maxRows: 10)
        #expect(built == .tooLarge)
    }

    @Test("A cell past the server's cell cap is too large to share")
    func oversizedCell() {
        let huge = String(repeating: "x", count: ShareSnapshotBuilder.maxCellBytes)
        let built = ShareSnapshotBuilder.build(source(
            columns: ["body"], types: [.text(rawType: "text")], rows: [[.text(huge)]]
        ), maxRows: 10)
        #expect(built == .tooLarge)
    }

    @Test("Rows stop where the body budget runs out, and the total says how many there were")
    func bodyBudgetCutsRows() throws {
        let wide = String(repeating: "y", count: 200_000)
        let rows = Array(repeating: [PluginCellValue.text(wide)], count: 40)
        let built = try snapshot(ShareSnapshotBuilder.build(source(
            columns: ["body"], types: [.text(rawType: "text")], rows: rows
        ), maxRows: 1_000))

        #expect(built.rows.count < 40)
        #expect(built.rows.count >= 20)
        #expect(built.rowCount == 40)
        #expect(built.isTruncated)
    }

    @Test("A string's JSON size counts its escapes")
    func jsonByteCount() {
        #expect(ShareCellEncoder.jsonByteCount(.string("ab")) == 4)
        #expect(ShareCellEncoder.jsonByteCount(.string("a\"b")) == 6)
        #expect(ShareCellEncoder.jsonByteCount(.string("\u{01}")) == 8)
        #expect(ShareCellEncoder.jsonByteCount(.null) == 4)
        #expect(ShareCellEncoder.jsonByteCount(.integer(-12)) == 3)
    }
}

private extension ShareSnapshotOutcome {
    var built: ShareSnapshot? {
        guard case .snapshot(let snapshot) = self else { return nil }
        return snapshot
    }
}
