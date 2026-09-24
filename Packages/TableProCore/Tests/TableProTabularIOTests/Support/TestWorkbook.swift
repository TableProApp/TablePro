import Foundation
@testable import TableProTabularIO

struct TestWorkbook {
    struct Sheet {
        let name: String
        let state: String?
        let body: String
        let partName: String

        init(name: String, state: String? = nil, partName: String? = nil, body: String) {
            self.name = name
            self.state = state
            self.body = body
            self.partName = partName ?? ""
        }
    }

    static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let relationshipTypeBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    var sheets: [Sheet] = []
    var sharedStrings: [String]?
    var numberFormats: [(id: Int, code: String)] = []
    var cellFormatIDs: [Int] = [0]
    var usesDate1904 = false
    var conditionalFormatID = 200
    var method = TestZipBuilder.Method.deflate
    var extraRelationships: [(id: String, type: String, target: String)] = []

    static func worksheet(rows: String, trailer: String = "") -> String {
        "<worksheet xmlns=\"\(mainNamespace)\"><sheetData>\(rows)</sheetData>\(trailer)</worksheet>"
    }

    func zipBuilder() -> TestZipBuilder {
        var builder = TestZipBuilder()
        builder.add("[Content_Types].xml", "<Types/>", method: method)
        builder.add(
            "_rels/.rels",
            "<Relationships><Relationship Id=\"rId1\" Type=\"\(Self.relationshipTypeBase)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            method: method
        )
        builder.add("xl/workbook.xml", workbookXML(), method: method)
        builder.add("xl/_rels/workbook.xml.rels", relationshipsXML(), method: method)
        builder.add("xl/styles.xml", stylesXML(), method: method)
        if let sharedStrings {
            builder.add("xl/sharedStrings.xml", sharedStringsXML(sharedStrings), method: method)
        }
        for (index, sheet) in sheets.enumerated() {
            builder.add("xl/worksheets/\(partName(of: sheet, at: index))", sheet.body, method: method)
        }
        return builder
    }

    func archive() throws -> ZipArchive {
        try ZipArchive(bytes: zipBuilder().build())
    }

    func workbook(chunkSize: Int = XLSXStreamingParse.defaultChunkSize) throws -> XLSXWorkbook {
        try XLSXWorkbook(archive: archive(), chunkSize: chunkSize, progress: nil, isCancelled: { false })
    }

    func source(sheet index: Int = 0, chunkSize: Int = XLSXStreamingParse.defaultChunkSize) throws -> XLSXSheetSource {
        let workbook = try workbook(chunkSize: chunkSize)
        return try workbook.source(for: workbook.sheets[index], chunkSize: chunkSize, progress: nil, isCancelled: { false })
    }

    private func partName(of sheet: Sheet, at index: Int) -> String {
        sheet.partName.isEmpty ? "sheet\(index + 1).xml" : sheet.partName
    }

    private func workbookXML() -> String {
        let properties = usesDate1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>"
        let entries = sheets.enumerated().map { index, sheet in
            let state = sheet.state.map { " state=\"\($0)\"" } ?? ""
            return "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\"\(state) r:id=\"rId\(index + 1)\"/>"
        }
        return "<workbook xmlns=\"\(Self.mainNamespace)\" xmlns:r=\"\(Self.relationshipNamespace)\">\(properties)<sheets>\(entries.joined())</sheets></workbook>"
    }

    private func relationshipsXML() -> String {
        var entries = sheets.enumerated().map { index, sheet in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"\(Self.relationshipTypeBase)worksheet\" Target=\"worksheets/\(partName(of: sheet, at: index))\"/>"
        }
        entries.append("<Relationship Id=\"rIdStyles\" Type=\"\(Self.relationshipTypeBase)styles\" Target=\"styles.xml\"/>")
        if sharedStrings != nil {
            entries.append("<Relationship Id=\"rIdStrings\" Type=\"\(Self.relationshipTypeBase)sharedStrings\" Target=\"/xl/sharedStrings.xml\"/>")
        }
        for extra in extraRelationships {
            entries.append("<Relationship Id=\"\(extra.id)\" Type=\"\(Self.relationshipTypeBase)\(extra.type)\" Target=\"\(extra.target)\"/>")
        }
        return "<Relationships>\(entries.joined())</Relationships>"
    }

    private func stylesXML() -> String {
        let formats = numberFormats.map { "<numFmt numFmtId=\"\($0.id)\" formatCode=\"\($0.code)\"/>" }.joined()
        let cellFormats = cellFormatIDs.map { "<xf numFmtId=\"\($0)\" fontId=\"0\"/>" }.joined()
        return """
            <styleSheet xmlns="\(Self.mainNamespace)"><numFmts count="\(numberFormats.count)">\(formats)</numFmts>\
            <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>\
            <cellXfs count="\(cellFormatIDs.count)">\(cellFormats)</cellXfs>\
            <dxfs count="1"><dxf><numFmt numFmtId="\(conditionalFormatID)" formatCode="yyyy"/></dxf></dxfs></styleSheet>
            """
    }

    private func sharedStringsXML(_ items: [String]) -> String {
        "<sst xmlns=\"\(Self.mainNamespace)\" count=\"\(items.count)\" uniqueCount=\"\(items.count)\">\(items.joined())</sst>"
    }
}
