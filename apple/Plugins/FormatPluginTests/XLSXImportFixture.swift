//
//  XLSXImportFixture.swift
//  FormatPluginTests
//

import Foundation
import zlib

struct XLSXImportFixture {
    struct Sheet {
        let name: String
        var isHidden = false
        let rows: String
    }

    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    var sheets: [Sheet]
    var sharedStrings: [String]?
    // The numFmtId of each cell style, in the order a cell's `s` attribute indexes them.
    var cellFormatIDs: [Int]

    init(rows: String, sharedStrings: [String]? = nil, cellFormatIDs: [Int] = []) {
        self.init(sheets: [Sheet(name: "Data", rows: rows)], sharedStrings: sharedStrings, cellFormatIDs: cellFormatIDs)
    }

    init(sheets: [Sheet], sharedStrings: [String]? = nil, cellFormatIDs: [Int] = []) {
        self.sheets = sheets
        self.sharedStrings = sharedStrings
        self.cellFormatIDs = cellFormatIDs
    }

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XLSXImport-\(UUID().uuidString).xlsx")
        try Self.zip(entries()).write(to: url)
        return url
    }

    private func entries() -> [(path: String, body: String)] {
        let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let sheetEntries = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\"\(sheet.isHidden ? " state=\"hidden\"" : "") r:id=\"rId\(index + 1)\"/>"
        }
        var relationships = sheets.indices.map { index in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"\(relationshipType)worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }
        var entries: [(path: String, body: String)] = [
            ("_rels/.rels", "<Relationships><Relationship Id=\"rId1\" Type=\"\(relationshipType)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns=\"\(Self.mainNamespace)\" xmlns:r=\"\(Self.relationshipNamespace)\"><sheets>\(sheetEntries.joined())</sheets></workbook>"),
        ]
        if let sharedStrings {
            relationships.append("<Relationship Id=\"rIdStrings\" Type=\"\(relationshipType)sharedStrings\" Target=\"sharedStrings.xml\"/>")
            entries.append(("xl/sharedStrings.xml", "<sst xmlns=\"\(Self.mainNamespace)\">\(sharedStrings.joined())</sst>"))
        }
        if !cellFormatIDs.isEmpty {
            relationships.append("<Relationship Id=\"rIdStyles\" Type=\"\(relationshipType)styles\" Target=\"styles.xml\"/>")
            let formats = cellFormatIDs.map { "<xf numFmtId=\"\($0)\"/>" }.joined()
            entries.append(("xl/styles.xml", "<styleSheet xmlns=\"\(Self.mainNamespace)\"><cellXfs count=\"\(cellFormatIDs.count)\">\(formats)</cellXfs></styleSheet>"))
        }
        entries.append(("xl/_rels/workbook.xml.rels", "<Relationships>\(relationships.joined())</Relationships>"))
        for (index, sheet) in sheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", "<worksheet xmlns=\"\(Self.mainNamespace)\"><sheetData>\(sheet.rows)</sheetData></worksheet>"))
        }
        return entries
    }

    private static func zip(_ entries: [(path: String, body: String)]) -> Data {
        var output = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let body = Data(entry.body.utf8)
            let checksum = body.withUnsafeBytes { raw in
                UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
            }
            let offset = UInt32(output.count)
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.append(littleEndian: [UInt16(20), 0, 0, 0, 0])
            output.append(littleEndian: [checksum, UInt32(body.count), UInt32(body.count)])
            output.append(littleEndian: [UInt16(name.count), 0])
            output.append(name)
            output.append(body)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(littleEndian: [UInt16(20), 20, 0, 0, 0, 0])
            directory.append(littleEndian: [checksum, UInt32(body.count), UInt32(body.count)])
            directory.append(littleEndian: [UInt16(name.count), 0, 0, 0, 0])
            directory.append(littleEndian: [UInt32(0), offset])
            directory.append(name)
        }
        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.append(littleEndian: [UInt16(0), 0, UInt16(entries.count), UInt16(entries.count)])
        output.append(littleEndian: [UInt32(directory.count), directoryOffset])
        output.append(littleEndian: [UInt16(0)])
        return output
    }
}

private extension Data {
    mutating func append<Value: FixedWidthInteger>(littleEndian values: [Value]) {
        for value in values {
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }
}
