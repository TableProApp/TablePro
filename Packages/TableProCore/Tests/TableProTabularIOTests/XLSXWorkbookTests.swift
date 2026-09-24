import Foundation
@testable import TableProTabularIO
import XCTest

final class XLSXWorkbookTests: XCTestCase {
    private let emptySheet = TestWorkbook.worksheet(rows: "")

    func testSheetsFollowWorkbookOrderWithNamesHiddenStateAndParts() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [
            TestWorkbook.Sheet(name: "Summary", partName: "sheet3.xml", body: emptySheet),
            TestWorkbook.Sheet(name: "R&amp;D", state: "hidden", partName: "sheet1.xml", body: emptySheet),
            TestWorkbook.Sheet(name: "Secret", state: "veryHidden", partName: "sheet2.xml", body: emptySheet)
        ]
        let workbook = try fixture.workbook()
        XCTAssertEqual(workbook.sheets.map(\.name), ["Summary", "R&D", "Secret"])
        XCTAssertEqual(workbook.sheets.map(\.visibility), [.visible, .hidden, .veryHidden])
        XCTAssertEqual(workbook.sheets.map(\.partPath), ["xl/worksheets/sheet3.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"])
        XCTAssertEqual(workbook.sheets.map(\.index), [0, 1, 2])
        XCTAssertEqual(workbook.visibleSheets.map(\.name), ["Summary"])
        XCTAssertTrue(workbook.sheets[1].isHidden)
    }

    func testChartsheetsAreNotListedAsTables() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: emptySheet)]
        var builder = fixture.zipBuilder()
        let workbookXML = """
            <workbook xmlns="\(TestWorkbook.mainNamespace)" xmlns:r="\(TestWorkbook.relationshipNamespace)"><sheets>\
            <sheet name="Chart" sheetId="2" r:id="rIdChart"/><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
            """
        let relationships = """
            <Relationships>\
            <Relationship Id="rId1" Type="\(TestWorkbook.relationshipTypeBase)worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rIdChart" Type="\(TestWorkbook.relationshipTypeBase)chartsheet" Target="chartsheets/sheet1.xml"/>\
            </Relationships>
            """
        builder.add("xl/workbook.xml", workbookXML)
        builder.add("xl/_rels/workbook.xml.rels", relationships)
        builder.add("xl/chartsheets/sheet1.xml", "<chartsheet/>")
        let archive = try ZipArchive(bytes: builder.build())
        let workbook = try XLSXWorkbook(archive: archive)
        XCTAssertEqual(workbook.sheets.map(\.name), ["Data"])
    }

    func testRelationshipTargetsResolveRelativeAndAbsolute() {
        XCTAssertEqual(XLSXPackage.resolvePath("worksheets/sheet1.xml", relativeTo: "xl/workbook.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XLSXPackage.resolvePath("/xl/worksheets/sheet1.xml", relativeTo: "xl/workbook.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XLSXPackage.resolvePath("../xl/./sharedStrings.xml", relativeTo: "xl/workbook.xml"), "xl/sharedStrings.xml")
        XCTAssertEqual(XLSXPackage.relationshipsPath(ofPart: "xl/workbook.xml"), "xl/_rels/workbook.xml.rels")
    }

    func testDateSystemIsReadFromWorkbookProperties() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: emptySheet)]
        XCTAssertEqual(try fixture.workbook().dateSystem, .base1900)
        fixture.usesDate1904 = true
        XCTAssertEqual(try fixture.workbook().dateSystem, .base1904)
    }

    func testSharedStringsJoinRichTextRunsAndSkipPhoneticGuides() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: emptySheet)]
        fixture.sharedStrings = [
            "<si><t>Ada</t></si>",
            "<si><r><rPr><b/><sz val=\"11\"/></rPr><t xml:space=\"preserve\">Grace </t></r><r><t>Hopper</t></r></si>",
            "<si><t>東京</t><rPh sb=\"0\" eb=\"2\"><t>トウキョウ</t></rPh><phoneticPr fontId=\"1\"/></si>",
            "<si><t>Tom &amp; Jerry &lt;3 &#x1F600; &#65;</t></si>",
            "<si><t>line_x000D_break _x005F_x0041_</t></si>",
            "<si><t/></si>",
            "<si/>",
            "<si><t><![CDATA[<raw>]]></t></si>"
        ]
        let strings = try fixture.workbook().sharedStrings
        XCTAssertEqual(strings.count, 8)
        XCTAssertEqual((0..<strings.count).compactMap { strings.string(at: $0) }, [
            "Ada", "Grace Hopper", "東京", "Tom & Jerry <3 😀 A", "line\rbreak _x0041_", "", "", "<raw>"
        ])
        XCTAssertNil(strings.string(at: 8))
    }

    func testSharedStringsSurviveAnyChunkBoundary() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: emptySheet)]
        let expected = (0..<300).map { "value \($0) & more" }
        fixture.sharedStrings = expected.map { "<si><r><t>\($0.replacingOccurrences(of: "&", with: "&amp;"))</t></r></si>" }
        for chunkSize in [1, 7, 64, 4_096] {
            let strings = try fixture.workbook(chunkSize: chunkSize).sharedStrings
            XCTAssertEqual((0..<strings.count).compactMap { strings.string(at: $0) }, expected, "chunk \(chunkSize)")
        }
    }

    func testMissingWorkbookPartIsNamed() throws {
        var builder = TestZipBuilder()
        builder.add("docProps/app.xml", "<Properties/>")
        let archive = try ZipArchive(bytes: builder.build())
        XCTAssertThrowsError(try XLSXWorkbook(archive: archive)) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .entryNotFound("xl/workbook.xml"))
        }
    }

    func testWorkbookWithoutRelationshipsFallsBackToConventionalParts() throws {
        var builder = TestZipBuilder()
        builder.add(
            "xl/workbook.xml",
            "<workbook xmlns:r=\"\(TestWorkbook.relationshipNamespace)\"><sheets><sheet name=\"Only\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        )
        builder.add("xl/sharedStrings.xml", "<sst><si><t>hello</t></si></sst>")
        builder.add("xl/worksheets/sheet1.xml", TestWorkbook.worksheet(rows: "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>"))
        let workbook = try XLSXWorkbook(archive: ZipArchive(bytes: builder.build()))
        XCTAssertEqual(workbook.sheets.map(\.partPath), ["xl/worksheets/sheet1.xml"])
        let source = try workbook.source(for: workbook.sheets[0])
        XCTAssertEqual(source.cell(row: 0, column: 0), TabularCell(kind: .text, text: "hello"))
    }

    func testCancellingWhileReadingSharedStringsThrows() throws {
        var fixture = TestWorkbook()
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: emptySheet)]
        fixture.sharedStrings = ["<si><t>a</t></si>"]
        let archive = try fixture.archive()
        XCTAssertThrowsError(try XLSXWorkbook(archive: archive, isCancelled: { true })) { error in
            XCTAssertTrue(error is TabularCancellation)
        }
    }

    func testStoredWorkbookPartsReadLikeDeflatedOnes() throws {
        var fixture = TestWorkbook()
        fixture.method = .stored
        fixture.sharedStrings = ["<si><t>stored</t></si>"]
        fixture.sheets = [TestWorkbook.Sheet(name: "Data", body: TestWorkbook.worksheet(rows: "<row><c t=\"s\"><v>0</v></c></row>"))]
        XCTAssertEqual(try fixture.source().cell(row: 0, column: 0).text, "stored")
    }
}
