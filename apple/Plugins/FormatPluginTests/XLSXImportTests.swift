//
//  XLSXImportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private final class RecordingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String? = "people"

    private(set) var rows: [[String: PluginCellValue]] = []

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { rows.append(values) }
    func deleteAllRowsFromTargetTable() async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

// Serialized because `XLSXImportPlugin.settings` persists through plugin storage, so two instances in flight read
// each other's options.
@Suite(.serialized)
struct XLSXImportSheetTests {
    private func read(_ fixture: XLSXImportFixture, hasHeaderRow: Bool = true) throws -> XLSXImportSheet {
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        return try XLSXImportSheet.read(at: url, hasHeaderRow: hasHeaderRow, isCancelled: { false })
    }

    private func values(_ sheet: XLSXImportSheet) -> [[String?]] {
        sheet.rows(0 ..< sheet.rowCount).map(\.values)
    }

    private func number(_ reference: String, _ value: String) -> String {
        "<c r=\"\(reference)\"><v>\(value)</v></c>"
    }

    private func inline(_ reference: String, _ text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }

    // Row 3 holds only cells that store empty text, row 4 only a styled cell with nothing stored.
    private var emptyCells: XLSXImportFixture {
        let rows = """
            <row r="1">\(inline("A1", "id"))\(inline("B1", "note"))\(inline("C1", "code"))</row>\
            <row r="2">\(number("A2", "1"))<c r="B2" t="str"><f>IF(A2="","",A2)</f><v></v></c><c r="C2" t="s"><v>0</v></c></row>\
            <row r="3"><c r="B3" t="str"><f>""</f><v></v></c><c r="C3" t="inlineStr"><is><t/></is></c></row>\
            <row r="4"><c r="A4" s="0"/></row>\
            <row r="5">\(number("A5", "2"))</row>
            """
        return XLSXImportFixture(rows: rows, sharedStrings: ["<si><t/></si>"])
    }

    private func imported(_ fixture: XLSXImportFixture, emptyAsNull: Bool) async throws -> [[String: PluginCellValue]] {
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let plugin = XLSXImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        var options = XLSXImportOptions()
        options.emptyAsNull = emptyAsNull
        plugin.settings = options
        let sink = RecordingSink()
        _ = try await plugin.performImport(
            source: RoundTripImportFile(url),
            sink: sink,
            progress: PluginImportProgress(progress: Progress(totalUnitCount: 1))
        )
        return sink.rows
    }

    @Test("A cell lands in the column its reference names")
    func cellsArePlacedByReference() throws {
        let cells = [("A1", "a"), ("B1", "b"), ("Z1", "z"), ("AA1", "aa"), ("AB1", "ab"), ("BA1", "ba")]
        let sheet = try read(XLSXImportFixture(rows: "<row r=\"1\">\(cells.map { inline($0.0, $0.1) }.joined())</row>"), hasHeaderRow: false)
        let row = try #require(values(sheet).first)
        #expect(row.count == 53)
        #expect([0, 1, 25, 26, 27, 52].map { row[$0] } == ["a", "b", "z", "aa", "ab", "ba"])
        #expect(row.compactMap { $0 }.count == 6)
    }

    @Test("A repeated or blank header gets a name of its own")
    func headerNamesAreUnique() {
        #expect(XLSXImportSheet.headerNames(from: ["Notes", "Notes", nil, "  Id  "]) == ["Notes", "Notes 2", "column3", "Id"])
    }

    @Test("A header spelled out keeps its name over a blank cell's placeholder that comes first")
    func literalHeaderKeepsItsName() {
        let names = XLSXImportSheet.headerNames(from: [nil, "column1", "Code", "Code", "Code 2"])
        #expect(names == ["column1 2", "column1", "Code", "Code 3", "Code 2"])
    }

    @Test("A reference past the last column is dropped instead of widening the row")
    func referencePastTheLastColumnIsDropped() throws {
        let rows = """
            <row r="1">\(inline("A1", "id"))\(inline("B1", "name"))</row>\
            <row r="2">\(number("A2", "1"))\(number("AAAAAAAAAAAAAAA2", "2"))\(number("ZZZZZ2", "3"))\(number("XFE2", "4"))</row>
            """
        let sheet = try read(XLSXImportFixture(rows: rows))
        #expect(sheet.header == ["id", "name"])
        #expect(values(sheet) == [["1", nil]])
    }

    @Test("A cell at the last column and many empty rows import as one row")
    func emptyRowsBelowAFarCellAreNotMaterialised() throws {
        let empty = (2...100_001).map { "<row r=\"\($0)\"/>" }.joined()
        let rows = "<row r=\"1\">\(inline("A1", "id"))\(inline("XFD1", "far"))</row>\(empty)<row r=\"100002\">\(number("A100002", "7"))</row>"
        let sheet = try read(XLSXImportFixture(rows: rows))
        let header = try #require(sheet.header)
        #expect(header.count == 16_384)
        #expect(header.first == "id")
        #expect(header[1] == "column2")
        #expect(header.last == "far")
        #expect(sheet.rowCount == 1)
        let row = try #require(sheet.rows(0 ..< 1).first)
        #expect(row.line == 100_002)
        #expect(row.values.first == "7")
        #expect(row.values.dropFirst().allSatisfy { $0 == nil })
    }

    @Test("The first visible sheet is read, in workbook order")
    func firstVisibleSheetIsRead() throws {
        let fixture = XLSXImportFixture(sheets: [
            .init(name: "Archive", isHidden: true, rows: "<row r=\"1\">\(inline("A1", "old"))</row>"),
            .init(name: "Data", rows: "<row r=\"1\">\(inline("A1", "current"))</row>"),
        ])
        #expect(try read(fixture).header == ["current"])
    }

    @Test("Shared strings concatenate their runs and resolve by index")
    func sharedStringsResolve() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c></row>"
        let strings = ["<si><t>Ada</t></si>", "<si><r><t>Grace </t></r><r><t>Hopper</t></r></si>"]
        #expect(try read(XLSXImportFixture(rows: rows, sharedStrings: strings)).header == ["Ada", "Grace Hopper"])
    }

    @Test("A shared-string index the table lacks keeps the raw value")
    func outOfRangeIndexKeepsRawValue() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>99</v></c></row>"
        #expect(values(try read(XLSXImportFixture(rows: rows, sharedStrings: ["<si><t>only</t></si>"]), hasHeaderRow: false)) == [["99"]])
    }

    @Test("A gap in a row is filled from the cell references")
    func gapsArePlacedByReference() throws {
        let rows = "<row r=\"1\">\(number("A1", "1"))\(number("C1", "3"))</row>"
        #expect(values(try read(XLSXImportFixture(rows: rows), hasHeaderRow: false)) == [["1", nil, "3"]])
    }

    @Test("Rows are padded to the widest row")
    func rowsArePadded() throws {
        let rows = "<row r=\"1\">\(number("A1", "1"))\(number("B1", "2"))</row><row r=\"2\">\(number("A2", "3"))</row>"
        #expect(values(try read(XLSXImportFixture(rows: rows), hasHeaderRow: false)) == [["1", "2"], ["3", nil]])
    }

    @Test("Numbers keep their text and booleans read as 1 and 0")
    func valuesKeepTheirStoredText() throws {
        let rows = "<row r=\"1\">\(number("A1", "12.50"))\(number("B1", "007"))<c r=\"C1\" t=\"b\"><v>1</v></c><c r=\"D1\" t=\"b\"><v>0</v></c></row>"
        #expect(values(try read(XLSXImportFixture(rows: rows), hasHeaderRow: false)) == [["12.50", "007", "1", "0"]])
    }

    @Test("A number of nineteen digits reads as its text")
    func nineteenDigitNumberIsRead() throws {
        let rows = "<row r=\"1\">\(number("A1", "9999999999999999999"))\(number("B1", "-9223372036854775808"))</row>"
        #expect(values(try read(XLSXImportFixture(rows: rows), hasHeaderRow: false)) == [["9999999999999999999", "-9223372036854775808"]])
    }

    @Test("A row's line is its row number in the sheet")
    func linesFollowTheSheet() throws {
        let rows = "<row r=\"3\">\(inline("A3", "id"))</row><row r=\"5\">\(number("A5", "1"))</row>"
        let sheet = try read(XLSXImportFixture(rows: rows))
        #expect(sheet.rows(0 ..< sheet.rowCount).map(\.line) == [5])
    }

    @Test("An empty sheet reads as no rows rather than failing")
    func emptySheet() throws {
        let headed = try read(XLSXImportFixture(rows: ""))
        #expect(headed.header == nil)
        #expect(headed.rowCount == 0)
        let plain = try read(XLSXImportFixture(rows: ""), hasHeaderRow: false)
        #expect(plain.header?.isEmpty == true)
        #expect(plain.rowCount == 0)
    }

    @Test("A stored cell with empty text reads as empty text, a cell with nothing stored as nil")
    func emptyTextIsNotAMissingCell() throws {
        let sheet = try read(emptyCells)
        #expect(sheet.header == ["id", "note", "code"])
        #expect(values(sheet) == [["1", "", ""], [nil, "", ""], ["2", nil, nil]])
        #expect(sheet.rows(0 ..< sheet.rowCount).map(\.line) == [2, 3, 5])
    }

    @Test("With Empty as NULL off, a cell that stores empty text imports as empty text")
    func emptyTextImportsAsEmptyText() async throws {
        let rows = try await imported(emptyCells, emptyAsNull: false)
        #expect(rows == [
            ["id": .text("1"), "note": .text(""), "code": .text("")],
            ["id": .null, "note": .text(""), "code": .text("")],
            ["id": .text("2"), "note": .null, "code": .null],
        ])
    }

    @Test("With Empty as NULL on, a cell that stores empty text imports as NULL")
    func emptyTextImportsAsNull() async throws {
        let rows = try await imported(emptyCells, emptyAsNull: true)
        #expect(rows == [
            ["id": .text("1"), "note": .null, "code": .null],
            ["id": .null, "note": .null, "code": .null],
            ["id": .text("2"), "note": .null, "code": .null],
        ])
    }

    @Test("Date, time and duration cells read as ISO dates and elapsed time, not their serial number")
    func temporalCellsReadAsText() throws {
        let rows = """
            <row r="1"><c r="A1" s="1"><v>45292</v></c><c r="B1" s="2"><v>45292.5</v></c>\
            <c r="C1" s="3"><v>0.5</v></c><c r="D1" s="4"><v>1.5</v></c>\(number("E1", "45292"))</row>
            """
        let fixture = XLSXImportFixture(rows: rows, cellFormatIDs: [0, 14, 22, 20, 46])
        #expect(values(try read(fixture, hasHeaderRow: false)) == [["2024-01-01", "2024-01-01 12:00:00", "12:00:00", "36:00:00", "45292"]])
    }

    @Test("Field detection types a date column as text")
    func detectsADateColumnAsText() throws {
        let rows = """
            <row r="1">\(inline("A1", "day"))</row>\
            <row r="2"><c r="A2" s="1"><v>45292</v></c></row><row r="3"><c r="A3" s="1"><v>45293</v></c></row>
            """
        let url = try XLSXImportFixture(rows: rows, cellFormatIDs: [0, 14]).write()
        defer { try? FileManager.default.removeItem(at: url) }
        let plugin = XLSXImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        plugin.settings = XLSXImportOptions()
        let fields = try plugin.detectSourceFields(at: url, targetTable: nil)
        #expect(fields.map(\.sampleValue) == ["2024-01-01"])
        #expect(fields.map(\.inferredType) == [.text])
    }

    @Test("Field detection names the header and infers from the rows below it")
    func detectsFieldsFromTheHeaderRow() throws {
        let rows = """
            <row r="1">\(inline("A1", "id"))\(inline("B1", "name"))</row>\
            <row r="2">\(number("A2", "1"))\(inline("B2", "Ada"))</row><row r="3">\(number("A3", "2"))</row>
            """
        let url = try XLSXImportFixture(rows: rows).write()
        defer { try? FileManager.default.removeItem(at: url) }
        let plugin = XLSXImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        plugin.settings = XLSXImportOptions()
        let fields = try plugin.detectSourceFields(at: url, targetTable: nil)
        #expect(fields.map(\.name) == ["id", "name"])
        #expect(fields.map(\.sampleValue) == ["1", "Ada"])
        #expect(fields.map(\.inferredType) == [.integer, .text])
    }
}
