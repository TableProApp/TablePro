import Foundation
@testable import TableProTabularIO
import XCTest

final class XLSXSheetSourceTests: XCTestCase {
    private func source(
        rows: String,
        trailer: String = "",
        sharedStrings: [String]? = nil,
        configure: (inout TestWorkbook) -> Void = { _ in }
    ) throws -> XLSXSheetSource {
        var fixture = TestWorkbook()
        fixture.sharedStrings = sharedStrings
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: TestWorkbook.worksheet(rows: rows, trailer: trailer))]
        configure(&fixture)
        return try fixture.source()
    }

    private func grid(_ source: XLSXSheetSource) -> [[String]] {
        (0..<source.rowCount).map { row in source.cells(row: row).map(\.text) }
    }

    private func scanned(_ source: XLSXSheetSource, rows: [Int]) -> [[TabularCell]] {
        var result: [[TabularCell]] = []
        source.scan(columns: Array(0..<source.columnCount), rows: rows) { _, cells in
            result.append((0..<cells.count).map { TabularCell(kind: cells.kinds[$0], text: cells.string(at: $0)) })
            return true
        }
        return result
    }

    func testEveryCellTypeReadsWithItsKindAndText() throws {
        let rows = """
            <row r="1">\
            <c r="A1" t="s"><v>0</v></c>\
            <c r="B1" t="inlineStr"><is><r><t>inline </t></r><r><t>rich</t></r></is></c>\
            <c r="C1" t="str"><f>A1&amp;"!"</f><v>shared &amp; formula</v></c>\
            <c r="D1" t="b"><v>1</v></c>\
            <c r="E1" t="b"><v>0</v></c>\
            <c r="F1" t="e"><v>#DIV/0!</v></c>\
            <c r="G1" t="n"><v>42</v></c>\
            <c r="H1"><v>-3.250</v></c>\
            <c r="I1" t="d"><v>2024-01-15T10:00:00Z</v></c>\
            </row>
            """
        let source = try source(rows: rows, sharedStrings: ["<si><t>shared</t></si>"])
        XCTAssertEqual(source.cells(row: 0), [
            TabularCell(kind: .text, text: "shared"),
            TabularCell(kind: .text, text: "inline rich"),
            TabularCell(kind: .text, text: "shared & formula"),
            TabularCell(kind: .boolean, text: "TRUE"),
            TabularCell(kind: .boolean, text: "FALSE"),
            TabularCell(kind: .error, text: "#DIV/0!"),
            TabularCell(kind: .number, text: "42"),
            TabularCell(kind: .number, text: "-3.250"),
            TabularCell(kind: .date, text: "2024-01-15T10:00:00Z")
        ])
        XCTAssertEqual(scanned(source, rows: [0]), [source.cells(row: 0)])
    }

    func testNumbersKeepTheTextOfTheirValueExactly() throws {
        let values = [
            "0", "7", "-12", "1.5", "0.05", "12.50", "3.0000000000000004", "1E-3", "1.23E+20",
            "123456789012345678901234", "007", "-0", ".5", "999999999999999999", "-0.000001"
        ]
        let cells = values.enumerated().map { "<c r=\"A\($0.offset + 1)\"><v>\($0.element)</v></c>" }
        let rows = cells.enumerated().map { "<row r=\"\($0.offset + 1)\">\($0.element)</row>" }.joined()
        let source = try source(rows: rows)
        XCTAssertEqual((0..<source.rowCount).map { source.cell(row: $0, column: 0).text }, values)
        XCTAssertTrue((0..<source.rowCount).allSatisfy { source.cell(row: $0, column: 0).kind == .number })
        XCTAssertEqual(scanned(source, rows: Array(0..<source.rowCount)).map { $0[0].text }, values)
    }

    func testBuiltInAndCustomDateFormatsBecomeISODates() throws {
        let rows = """
            <row r="1">\
            <c r="A1" s="1"><v>45306</v></c>\
            <c r="B1" s="2"><v>45306.5208333333</v></c>\
            <c r="C1" s="3"><v>45306.75</v></c>\
            <c r="D1" s="4"><v>0.75</v></c>\
            <c r="E1" s="5"><v>45306</v></c>\
            <c r="F1" s="6"><v>45306</v></c>\
            <c r="G1" s="7"><v>1.5</v></c>\
            <c r="H1" s="8"><v>45306.000011574</v></c>\
            <c r="I1" s="1"><v>-1</v></c>\
            <c r="J1" s="9"><v>45306</v></c>\
            <c r="K1" s="10"><v>0.5</v></c>\
            </row>
            """
        let source = try source(rows: rows) { fixture in
            fixture.numberFormats = [
                (164, "yyyy\\-mm\\-dd hh:mm:ss"),
                (165, "0.00&quot; days&quot;"),
                (166, "[Red]#,##0"),
                (167, "[h]:mm:ss"),
                (168, "[$-409]mmmm d, yyyy;@")
            ]
            fixture.cellFormatIDs = [0, 14, 22, 164, 20, 165, 166, 167, 22, 168, 46]
            fixture.conditionalFormatID = 165
        }
        XCTAssertEqual(source.cells(row: 0), [
            TabularCell(kind: .date, text: "2024-01-15"),
            TabularCell(kind: .date, text: "2024-01-15 12:30:00"),
            TabularCell(kind: .date, text: "2024-01-15 18:00:00"),
            TabularCell(kind: .date, text: "18:00:00"),
            TabularCell(kind: .number, text: "45306"),
            TabularCell(kind: .number, text: "45306"),
            TabularCell(kind: .date, text: "36:00:00"),
            TabularCell(kind: .date, text: "2024-01-15 00:00:01"),
            TabularCell(kind: .number, text: "-1"),
            TabularCell(kind: .date, text: "2024-01-15"),
            TabularCell(kind: .date, text: "12:00:00")
        ])
        XCTAssertEqual(scanned(source, rows: [0]), [source.cells(row: 0)])
    }

    func testTheNineteenHundredLeapYearBugIsKept() throws {
        let rows = """
            <row r="1"><c r="A1" s="1"><v>1</v></c><c r="B1" s="1"><v>59</v></c>\
            <c r="C1" s="1"><v>60</v></c><c r="D1" s="1"><v>61</v></c><c r="E1" s="1"><v>2958465</v></c></row>
            """
        let source = try source(rows: rows) { $0.cellFormatIDs = [0, 14] }
        XCTAssertEqual(source.cells(row: 0).map(\.text), ["1900-01-01", "1900-02-28", "1900-02-29", "1900-03-01", "9999-12-31"])
    }

    func testTheNineteenOhFourDateSystemShiftsSerials() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c><c r=\"B1\" s=\"1\"><v>43844</v></c><c r=\"C1\" s=\"2\"><v>43844.25</v></c></row>"
        let source = try source(rows: rows) { fixture in
            fixture.usesDate1904 = true
            fixture.cellFormatIDs = [0, 14, 22]
        }
        XCTAssertEqual(source.dateSystem, .base1904)
        XCTAssertEqual(source.cells(row: 0).map(\.text), ["1904-01-01", "2024-01-15", "2024-01-15 06:00:00"])
    }

    func testFormulasReadTheirCachedValue() throws {
        let rows = """
            <row r="1"><c r="A1"><f>1+2</f><v>3</v></c><c r="B1"><f t="shared" ref="B1:B2" si="0">A1*2</f><v>6</v></c>\
            <c r="C1" t="str"><f>""</f><v></v></c><c r="D1"><f>NOW()</f></c></row>
            """
        let source = try source(rows: rows)
        XCTAssertEqual(source.cells(row: 0), [
            TabularCell(kind: .number, text: "3"),
            TabularCell(kind: .number, text: "6"),
            TabularCell(kind: .text, text: "")
        ])
        XCTAssertEqual(source.columnCount, 3)
    }

    func testSparseRowsAndColumnsComeFromCellReferencesWithoutADimension() throws {
        let rows = """
            <row r="2"><c r="B2"><v>1</v></c><c r="C2" s="0"/></row>\
            <row r="5"><c r="D5"><v>2</v></c></row>\
            <row r="6" spans="1:9"><c r="F6" s="3"/></row>
            """
        let source = try source(rows: rows)
        XCTAssertEqual(source.rowCount, 4)
        XCTAssertEqual(source.columnCount, 3)
        XCTAssertEqual(source.firstRowIndex, 1)
        XCTAssertEqual(source.firstColumnIndex, 1)
        XCTAssertEqual(source.sheetReference(row: 3, column: 2).text, "D5")
        XCTAssertEqual(grid(source), [["1", "", ""], ["", "", ""], ["", "", ""], ["", "", "2"]])
        XCTAssertEqual(source.cell(row: 1, column: 0), source.absentCell)
        XCTAssertEqual(source.cell(row: 99, column: 0), source.absentCell)
    }

    func testRowsAndCellsWithoutReferencesAreCounted() throws {
        let rows = "<row><c><v>1</v></c><c><v>2</v></c></row><row><c/><c><v>4</v></c></row><row r=\"5\"><c r=\"B5\"><v>5</v></c><c><v>6</v></c></row>"
        let source = try source(rows: rows)
        XCTAssertEqual(grid(source), [["1", "2", ""], ["", "4", ""], ["", "", ""], ["", "", ""], ["", "5", "6"]])
    }

    func testMergedCellsShowTheirValueInTheTopLeftCellOnly() throws {
        let rows = """
            <row r="1"><c r="A1" t="inlineStr"><is><t>Title</t></is></c><c r="B1"><v>9</v></c><c r="C1"><v>3</v></c></row>\
            <row r="2"><c r="A2"><v>8</v></c><c r="B2"><v>7</v></c><c r="C2"><v>4</v></c></row>
            """
        let source = try source(rows: rows, trailer: "<mergeCells count=\"1\"><mergeCell ref=\"A1:B2\"/></mergeCells>")
        XCTAssertEqual(grid(source), [["Title", "", "3"], ["", "", "4"]])
        XCTAssertEqual(source.mergedRanges, [XLSXCellRange(start: XLSXCellReference(row: 0, column: 0), end: XLSXCellReference(row: 1, column: 1))])
    }

    func testLargeGapsAndOutOfOrderCellsStayAddressable() throws {
        let rows = """
            <row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>10</v></c></row>\
            <row r="2"><c r="A2"><v>2</v></c></row>\
            <row r="5000"><c r="A5000"><v>3</v></c></row>\
            <row r="3"><c r="B3"><v>30</v></c><c r="B3"><v>31</v></c></row>\
            <row r="4"><c r="A4"><v>4</v></c></row>
            """
        let source = try source(rows: rows)
        XCTAssertEqual(source.rowCount, 5_000)
        XCTAssertEqual(source.cell(row: 0, column: 0).text, "1")
        XCTAssertEqual(source.cell(row: 1, column: 0).text, "2")
        XCTAssertEqual(source.cell(row: 3, column: 0).text, "4")
        XCTAssertEqual(source.cell(row: 4_999, column: 0).text, "3")
        XCTAssertEqual(source.cell(row: 2, column: 1).text, "31")
        XCTAssertEqual(source.cell(row: 2, column: 0), source.absentCell)
        XCTAssertEqual(scanned(source, rows: [4_999, 0, 3]).map { $0.map(\.text) }, [["3", ""], ["1", "10"], ["4", ""]])
    }

    func testPrefixedElementsAndCommentsAreUnderstood() throws {
        var fixture = TestWorkbook()
        let body = """
            <?xml version="1.0" encoding="UTF-8"?><!-- generated --><x:worksheet xmlns:x="\(TestWorkbook.mainNamespace)">\
            <x:dimension ref="A1"/><x:sheetData><x:row r="1"><x:c r="A1" t="inlineStr"><x:is><x:t>prefixed</x:t></x:is></x:c>\
            <x:c r="B1"><!-- note --><x:v>5</x:v></x:c></x:row></x:sheetData></x:worksheet>
            """
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: body)]
        XCTAssertEqual(try fixture.source().cells(row: 0).map(\.text), ["prefixed", "5"])
    }

    func testEveryChunkSizeReadsTheSameSheet() throws {
        let strings = (0..<50).map { "<si><t>name \($0) &amp; co</t></si>" }
        let rows = (1...400).map { row in
            "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"s\"><v>\(row % 50)</v></c><c r=\"B\(row)\"><v>\(row).25</v></c>"
                + "<c r=\"C\(row)\" t=\"inlineStr\"><is><t>row &lt;\(row)&gt;</t></is></c><c r=\"D\(row)\" s=\"1\"><v>\(45_000 + row)</v></c></row>"
        }.joined()
        var fixture = TestWorkbook()
        fixture.sharedStrings = strings
        fixture.cellFormatIDs = [0, 14]
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: TestWorkbook.worksheet(rows: rows))]
        let reference = grid(try fixture.source())
        XCTAssertEqual(reference.count, 400)
        XCTAssertEqual(reference[9], ["name 10 & co", "10.25", "row <10>", "2023-03-25"])
        for chunkSize in [1, 5, 33, 512] {
            XCTAssertEqual(grid(try fixture.source(chunkSize: chunkSize)), reference, "chunk \(chunkSize)")
        }
    }

    func testScanStopsWhenTheBodyAsks() throws {
        let rows = (1...10).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let source = try source(rows: rows)
        var visited: [Int] = []
        source.scan(columns: [0], rows: 0..<10) { row, _ in
            visited.append(row)
            return row < 2
        }
        XCTAssertEqual(visited, [0, 1, 2])
    }

    private func inline(_ reference: String, _ text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }

    private func number(_ reference: String, _ value: String) -> String {
        "<c r=\"\(reference)\"><v>\(value)</v></c>"
    }

    func testFirstRowHeaderHeuristic() throws {
        let labelled = try source(rows: """
            <row r="1">\(inline("A1", "id"))\(inline("B1", "name"))</row>\
            <row r="2">\(number("A2", "1"))\(inline("B2", "Ada"))</row>
            """)
        XCTAssertTrue(labelled.firstRowLooksLikeHeader)
        let numeric = try source(rows: "<row r=\"1\">\(number("A1", "1"))\(number("B1", "2"))</row>")
        XCTAssertFalse(numeric.firstRowLooksLikeHeader)
        let title = try source(rows: """
            <row r="1">\(inline("A1", "Report"))</row>\
            <row r="2">\(number("A2", "1"))\(number("B2", "2"))\(number("C2", "3"))</row>
            """)
        XCTAssertFalse(title.firstRowLooksLikeHeader)
        let numericText = try source(rows: "<row r=\"1\">\(inline("A1", "2024"))<c r=\"B1\" t=\"b\"><v>1</v></c></row>")
        XCTAssertFalse(numericText.firstRowLooksLikeHeader)
        let empty = try source(rows: "")
        XCTAssertEqual(empty.rowCount, 0)
        XCTAssertEqual(empty.columnCount, 0)
        XCTAssertFalse(empty.firstRowLooksLikeHeader)
    }

    func testCancellationStopsTheSheetParse() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: TestWorkbook.worksheet(rows: "<row><c><v>1</v></c></row>"))]
        let workbook = try fixture.workbook()
        XCTAssertThrowsError(try workbook.source(for: workbook.sheets[0], isCancelled: { true })) { error in
            XCTAssertTrue(error is TabularCancellation)
        }
    }

    func testProgressIsReportedUpToCompletion() throws {
        let rows = (1...2_000).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: TestWorkbook.worksheet(rows: rows))]
        let workbook = try fixture.workbook()
        var reported: [Double] = []
        _ = try workbook.source(for: workbook.sheets[0], chunkSize: 1_024, progress: { reported.append($0) }, isCancelled: { false })
        XCTAssertGreaterThan(reported.count, 2)
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertEqual(reported.last, 1)
    }

    func testCellReferencesParseAndPrint() {
        XCTAssertEqual(XLSXCellReference("A1"), XLSXCellReference(row: 0, column: 0))
        XCTAssertEqual(XLSXCellReference("$AB$12"), XLSXCellReference(row: 11, column: 27))
        XCTAssertEqual(XLSXCellReference("XFD1048576"), XLSXCellReference(row: 1_048_575, column: 16_383))
        XCTAssertNil(XLSXCellReference("XFE1"))
        XCTAssertNil(XLSXCellReference("A0"))
        XCTAssertNil(XLSXCellReference("A1048577"))
        XCTAssertNil(XLSXCellReference("1"))
        XCTAssertEqual(XLSXCellReference.columnName(0), "A")
        XCTAssertEqual(XLSXCellReference.columnName(25), "Z")
        XCTAssertEqual(XLSXCellReference.columnName(26), "AA")
        XCTAssertEqual(XLSXCellReference.columnName(16_383), "XFD")
        XCTAssertEqual(XLSXCellRange("C3:A1")?.rows, 0...2)
        XCTAssertEqual(XLSXCellRange("B2")?.columns, 1...1)
    }
}
