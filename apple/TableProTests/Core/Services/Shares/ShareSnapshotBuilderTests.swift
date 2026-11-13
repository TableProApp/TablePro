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
        total: Int?? = .none
    ) -> ShareResultSource {
        ShareResultSource(
            columns: columns,
            columnTypes: types,
            rows: rows,
            totalRowCount: total ?? rows.count,
            sql: "SELECT n FROM t"
        )
    }

    private func snapshot(_ outcome: ShareSnapshotOutcome?) throws -> ShareSnapshot {
        try #require(outcome?.built)
    }

    @Test("Integers go as number tokens with every digit, at any width")
    func integersKeepEveryDigit() {
        #expect(cell(.text("42"), .integer(rawType: "int")) == .number("42"))
        #expect(cell(.text("42.0"), .integer(rawType: "int")) == .number("42"))
        #expect(cell(.text("18446744073709551615"), .integer(rawType: "bigint unsigned")) == .number("18446744073709551615"))
        #expect(cell(.text("-9007199254740993"), .integer(rawType: "bigint")) == .number("-9007199254740993"))
    }

    @Test("Decimals go as number tokens exactly as the database wrote them", arguments: [
        ("3.10", "3.10"), ("12345678901234567890.12345678901234567890", "12345678901234567890.12345678901234567890"),
        ("+5", "5"), (".5", "0.5"), ("1e+20", "1e20")
    ])
    func decimalsKeepEveryDigit(text: String, token: String) {
        #expect(cell(.text(text), .decimal(rawType: "numeric")) == .number(token))
    }

    @Test("A number JSON cannot hold goes as its name", arguments: ["NaN", "Infinity", "-Infinity"])
    func nonFiniteNumbersAreNames(text: String) {
        #expect(cell(.text(text), .decimal(rawType: "float8")) == .string(text))
    }

    @Test("A JSON column goes as its document, key order and digits as written")
    func jsonIsADocument() {
        #expect(cell(.text(" {\"b\": 1, \"a\": [1, 12345678901234567890]} "), .json(rawType: "jsonb"))
            == .document("{\"b\": 1, \"a\": [1, 12345678901234567890]}"))
        #expect(cell(.text("not json"), .json(rawType: "json")) == .string("not json"))
    }

    @Test("A PostgreSQL array goes as an array, each element by the element type")
    func postgresArraysRecurse() {
        let ints = ColumnType.array(rawType: "_int8", element: .integer(rawType: "int8"))
        #expect(cell(.text("{1,NULL,18446744073709551615}"), ints) == .array([.number("1"), .null, .number("18446744073709551615")]))
        let texts = ColumnType.array(rawType: "_text", element: .text(rawType: "text"))
        #expect(cell(.text("{\"a b\",c}"), texts) == .array([.string("a b"), .string("c")]))
    }

    @Test("An array a driver writes as JSON goes as that document")
    func jsonArraysAreDocuments() {
        let type = ColumnType.array(rawType: "Array(Int64)", element: .integer(rawType: "Int64"))
        #expect(cell(.text("[1, 2, 3]"), type) == .document("[1, 2, 3]"))
    }

    @Test("Timestamps are written in ISO 8601 with the offset as +HH:MM", arguments: [
        ("2026-11-13 10:00:00", "2026-11-13T10:00:00"),
        ("2026-11-13 10:00:00.123456", "2026-11-13T10:00:00.123456"),
        ("2026-11-13 10:00:00+07", "2026-11-13T10:00:00+07:00"),
        ("2026-11-13 10:00:00.5 +0530", "2026-11-13T10:00:00.5+05:30"),
        ("2026-11-13T10:00:00Z", "2026-11-13T10:00:00+00:00"),
        ("not a time", "not a time")
    ])
    func timestampsAreISO(text: String, iso: String) {
        #expect(cell(.text(text), .timestamp(rawType: "timestamptz")) == .string(iso))
    }

    @Test("Booleans normalize and a TINYINT(1) value outside 0 and 1 stays a number")
    func booleans() {
        #expect(cell(.text("1"), .boolean(rawType: "tinyint(1)")) == .bool(true))
        #expect(cell(.text("t"), .boolean(rawType: "bool")) == .bool(true))
        #expect(cell(.text("false"), .boolean(rawType: "bool")) == .bool(false))
        #expect(cell(.text("2"), .boolean(rawType: "tinyint(1)")) == .number("2"))
    }

    @Test("Null stays null, bytes say how many, dates and text stay text")
    func otherCells() {
        #expect(cell(.null, .text(rawType: nil)) == .null)
        #expect(cell(.bytes(Data(count: 1_024)), .blob(rawType: "blob")) == .string("(binary, 1024 bytes)"))
        #expect(cell(.text("hello"), .text(rawType: "text")) == .string("hello"))
        #expect(cell(.text("2026-11-13"), .date(rawType: "date")) == .string("2026-11-13"))
    }

    @Test("Rows past max_rows are cut and the true total is kept")
    func rowsAreCappedToTheLimit() throws {
        let rows = (0..<1_500).map { [PluginCellValue.text(String($0))] }
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: rows, total: 48_210), maxRows: 1_000))

        #expect(built.rows.count == 1_000)
        #expect(built.rowCount == 48_210)
        #expect(built.isTruncated)
        #expect(built.rows.last == [.number("999")])
    }

    @Test("A total nobody counted stays unknown, and the snapshot says it is cut")
    func unknownTotal() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: [[.text("1")]], total: .some(nil)), maxRows: 10))
        #expect(built.rowCount == nil)
        #expect(built.isTruncated)
    }

    @Test("A result inside the limit is not truncated")
    func smallResultIsWhole() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(source(rows: [[.text("1")], [.text("2")]]), maxRows: 1_000))

        #expect(built.rows.count == 2)
        #expect(built.rowCount == 2)
        #expect(!built.isTruncated)
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

    @Test("More columns than the server takes sends the first ones, never refuses")
    func tooManyColumns() throws {
        let count = ShareSnapshotBuilder.maxColumns + 1
        let built = try snapshot(ShareSnapshotBuilder.build(source(
            columns: (0..<count).map { "c\($0)" },
            types: Array(repeating: .text(rawType: "text"), count: count),
            rows: [(0..<count).map { .text("v\($0)") }]
        ), maxRows: 10))
        #expect(built.columns.map(\.name) == (0..<ShareSnapshotBuilder.maxColumns).map { "c\($0)" })
        #expect(built.rows == [(0..<ShareSnapshotBuilder.maxColumns).map { .string("v\($0)") }])
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

    @Test("A build whose task was cancelled gives nothing")
    func cancelledBuild() async {
        let rows = (0..<10_000).map { [PluginCellValue.text(String($0))] }
        let task = Task.detached { () -> ShareSnapshotOutcome? in
            withUnsafeCurrentTask { $0?.cancel() }
            return ShareSnapshotBuilder.build(ShareResultSource(
                columns: ["n"], columnTypes: [.integer(rawType: "int")], rows: rows, totalRowCount: 10_000, sql: ""
            ), maxRows: 10_000)
        }
        #expect(await task.value == nil)
    }

    @Test("Rule-masked columns are marked, and their values go as text even in a number column")
    func ruleMasksAreMarked() throws {
        let built = try snapshot(ShareSnapshotBuilder.build(ShareResultSource(
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text")],
            rows: [[.text("123456789012"), .text("j•••@example.com")]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [0: .hash, 1: .email])
        ), maxRows: 10))

        #expect(built.columns.map(\.masked) == [.hash, .email])
        #expect(built.columns.map(\.type) == ["int8", "text"])
        #expect(built.rows == [[.string("123456789012"), .string("j•••@example.com")]])
    }

    @Test("Chosen columns are read in order, masked here when asked, and the rest are left out")
    func sharedColumnsApplyStyles() throws {
        let source = ShareResultSource(
            columns: ["id", "phone", "secret", "note"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text"), .text(rawType: "text"), .text(rawType: "text")],
            rows: [[.text("7"), .text("+1 555 123 4567"), .text("••••"), .null]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [2: .full])
        )
        let shared: [ShareSnapshotBuilder.SharedColumn] = [
            .init(source: 0, applying: nil, masked: nil),
            .init(source: 1, applying: .lastFour, masked: .lastFour),
            .init(source: 2, applying: .null, masked: .null),
            .init(source: 3, applying: .full, masked: .full)
        ]
        let built = try snapshot(ShareSnapshotBuilder.build(source, maxRows: 10, columns: shared))

        #expect(built.columns.map(\.name) == ["id", "phone", "secret", "note"])
        #expect(built.columns.map(\.masked) == [nil, .lastFour, .null, .full])
        #expect(built.rows == [[.number("7"), .string("••••4567"), .null, .null]])

        let fewer = try snapshot(ShareSnapshotBuilder.build(source, maxRows: 10, columns: [shared[1]]))
        #expect(fewer.columns.map(\.name) == ["phone"])
        #expect(fewer.rows == [[.string("••••4567")]])
    }

    @Test("A share with every column removed has nothing to send, and the cap counts only the kept columns")
    func removedColumns() throws {
        let count = ShareSnapshotBuilder.maxColumns + 1
        let source = ShareResultSource(
            columns: (0..<count).map { "c\($0)" },
            columnTypes: Array(repeating: .text(rawType: "text"), count: count),
            rows: [Array(repeating: .text("x"), count: count)],
            totalRowCount: 1,
            sql: ""
        )
        #expect(ShareSnapshotBuilder.build(source, maxRows: 10, columns: []) == .noColumns)
        let kept = (1..<count).map { ShareSnapshotBuilder.SharedColumn(source: $0, applying: nil, masked: nil) }
        let built = try snapshot(ShareSnapshotBuilder.build(source, maxRows: 10, columns: kept))
        #expect(built.columns.map(\.name) == (1..<count).map { "c\($0)" })
    }

    @Test("A cell's JSON size counts its escapes and nested arrays")
    func jsonByteCount() {
        #expect(ShareCellEncoder.jsonByteCount(.string("ab")) == 4)
        #expect(ShareCellEncoder.jsonByteCount(.string("a\"b")) == 6)
        #expect(ShareCellEncoder.jsonByteCount(.string("\u{01}")) == 8)
        #expect(ShareCellEncoder.jsonByteCount(.null) == 4)
        #expect(ShareCellEncoder.jsonByteCount(.number("-12")) == 3)
        #expect(ShareCellEncoder.jsonByteCount(.array([.number("1"), .null])) == 8)
    }
}

private extension ShareSnapshotOutcome {
    var built: ShareSnapshot? {
        guard case .snapshot(let snapshot) = self else { return nil }
        return snapshot
    }
}
