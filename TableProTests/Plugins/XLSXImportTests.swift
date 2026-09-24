//
//  XLSXImportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("XLSX sheet parsing")
struct XLSXSheetParserTests {
    /// `A` is 0 and `AA` is 26, so the letters are base-26 with no zero digit. Getting this wrong
    /// puts every column past Z in the wrong place.
    @Test("A cell reference resolves to its column index")
    func columnIndexFromReference() {
        #expect(XLSXSheetParser.columnIndex(fromReference: "A1") == 0)
        #expect(XLSXSheetParser.columnIndex(fromReference: "B2") == 1)
        #expect(XLSXSheetParser.columnIndex(fromReference: "Z9") == 25)
        #expect(XLSXSheetParser.columnIndex(fromReference: "AA1") == 26)
        #expect(XLSXSheetParser.columnIndex(fromReference: "AB1") == 27)
        #expect(XLSXSheetParser.columnIndex(fromReference: "BA10") == 52)
    }

    @Test("A reference with no letters is refused")
    func invalidReference() {
        #expect(XLSXSheetParser.columnIndex(fromReference: "1") == nil)
        #expect(XLSXSheetParser.columnIndex(fromReference: "") == nil)
    }

    /// Part names vary between writers, so the first worksheet is found rather than assumed to be
    /// `sheet1.xml`.
    @Test("The first worksheet is found by path, not assumed")
    func firstWorksheetIsFound() {
        let paths = ["xl/workbook.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet1.xml", "[Content_Types].xml"]
        #expect(XLSXSheetParser.firstWorksheetPath(in: paths) == "xl/worksheets/sheet1.xml")
        #expect(XLSXSheetParser.firstWorksheetPath(in: ["xl/workbook.xml"]) == nil)
    }

    /// A string split across formatting runs is one value, not several. A styled word mid-cell
    /// would otherwise truncate it.
    @Test("Shared strings concatenate their runs")
    func sharedStringRuns() {
        let xml = """
            <?xml version="1.0"?>
            <sst><si><t>Ada</t></si><si><r><t>Grace </t></r><r><t>Hopper</t></r></si></sst>
            """
        let strings = XLSXSheetParser.sharedStrings(from: Data(xml.utf8))
        #expect(strings == ["Ada", "Grace Hopper"])
    }

    /// A cell typed `s` holds an index into the shared string table rather than the text.
    @Test("A shared-string cell resolves through the table")
    func sharedStringCellResolves() {
        let sheet = """
            <?xml version="1.0"?>
            <worksheet><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            </sheetData></worksheet>
            """
        let rows = XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: ["id", "name"])
        #expect(rows == [["id", "name"]])
    }

    /// A row omits the cells it has no value for, so position comes from each cell's own reference.
    /// Counting cells instead shifts every value after a gap into the wrong column.
    @Test("A gap in a row is filled from the cell references")
    func gapsArePlacedByReference() {
        let sheet = """
            <?xml version="1.0"?>
            <worksheet><sheetData>
            <row r="1"><c r="A1"><v>1</v></c><c r="C1"><v>3</v></c></row>
            </sheetData></worksheet>
            """
        let rows = XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: [])
        #expect(rows == [["1", nil, "3"]])
    }

    @Test("An inline string is read from the cell itself")
    func inlineStringsAreRead() {
        let sheet = """
            <?xml version="1.0"?>
            <worksheet><sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>Ada</t></is></c></row>
            </sheetData></worksheet>
            """
        let rows = XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: [])
        #expect(rows == [["Ada"]])
    }

    /// A damaged workbook still imports something the user can see is wrong, rather than dropping
    /// the value silently.
    @Test("A shared-string index the table lacks keeps the raw value")
    func outOfRangeIndexKeepsRawValue() {
        let sheet = """
            <?xml version="1.0"?>
            <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>99</v></c></row></sheetData></worksheet>
            """
        let rows = XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: ["only"])
        #expect(rows == [["99"]])
    }

    @Test("Rows are padded to the widest row")
    func rowsArePadded() {
        let sheet = """
            <?xml version="1.0"?>
            <worksheet><sheetData>
            <row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c></row>
            <row r="2"><c r="A2"><v>3</v></c></row>
            </sheetData></worksheet>
            """
        let rows = XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: [])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.count == 2 })
        #expect(rows[1] == ["3", nil])
    }

    @Test("An empty sheet reads as no rows rather than failing")
    func emptySheet() {
        let sheet = "<?xml version=\"1.0\"?><worksheet><sheetData/></worksheet>"
        #expect(XLSXSheetParser.rows(from: Data(sheet.utf8), sharedStrings: []).isEmpty)
    }
}
