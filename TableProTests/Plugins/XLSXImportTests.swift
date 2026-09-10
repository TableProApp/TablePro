//
//  XLSXImportTests.swift
//  TableProTests
//

import Compression
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

@Suite("ZIP reading")
struct ZipReaderTests {

    /// Builds a ZIP the way the format specifies, so the reader is exercised against real bytes
    /// rather than a mock. Stored and deflated entries are both produced, because Excel writes
    /// deflate and TablePro's own XLSX export writes stored.
    private func makeArchive(_ files: [(name: String, body: Data, deflate: Bool)]) -> Data {
        var output = Data()
        var directory = Data()
        var offsets: [Int] = []

        for file in files {
            offsets.append(output.count)
            let nameBytes = Data(file.name.utf8)
            let payload = file.deflate ? deflated(file.body) : file.body
            let method: UInt16 = file.deflate ? 8 : 0

            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.append(uint16(20))
            output.append(uint16(0))
            output.append(uint16(method))
            output.append(uint16(0))
            output.append(uint16(0))
            output.append(uint32(crc32(file.body)))
            output.append(uint32(UInt32(payload.count)))
            output.append(uint32(UInt32(file.body.count)))
            output.append(uint16(UInt16(nameBytes.count)))
            output.append(uint16(0))
            output.append(nameBytes)
            output.append(payload)
        }

        for (index, file) in files.enumerated() {
            let nameBytes = Data(file.name.utf8)
            let payload = file.deflate ? deflated(file.body) : file.body
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(uint16(20))
            directory.append(uint16(20))
            directory.append(uint16(0))
            directory.append(uint16(file.deflate ? 8 : 0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(crc32(file.body)))
            directory.append(uint32(UInt32(payload.count)))
            directory.append(uint32(UInt32(file.body.count)))
            directory.append(uint16(UInt16(nameBytes.count)))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(0))
            directory.append(uint32(UInt32(offsets[index])))
            directory.append(nameBytes)
        }

        let directoryOffset = output.count
        output.append(directory)
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.append(uint16(0))
        output.append(uint16(0))
        output.append(uint16(UInt16(files.count)))
        output.append(uint16(UInt16(files.count)))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(UInt32(directoryOffset)))
        output.append(uint16(0))
        return output
    }

    private func deflated(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = max(data.count * 2, 1_024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(written)
    }

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ])
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    @Test("A stored entry reads back byte for byte")
    func storedEntryRoundTrips() throws {
        let body = Data("<xml>stored</xml>".utf8)
        let archive = makeArchive([(name: "a.xml", body: body, deflate: false)])
        #expect(try ZipReader.data(named: "a.xml", in: archive) == body)
    }

    /// Excel deflates every part, so this is the path that matters for a real workbook.
    @Test("A deflated entry is inflated")
    func deflatedEntryInflates() throws {
        let body = Data(String(repeating: "<row>value</row>", count: 500).utf8)
        let archive = makeArchive([(name: "b.xml", body: body, deflate: true)])
        #expect(try ZipReader.data(named: "b.xml", in: archive) == body)
    }

    @Test("Every entry is listed with its own path")
    func entriesAreListed() throws {
        let archive = makeArchive([
            (name: "xl/workbook.xml", body: Data("a".utf8), deflate: false),
            (name: "xl/worksheets/sheet1.xml", body: Data("b".utf8), deflate: true)
        ])
        let entries = try ZipReader.entries(in: archive)
        #expect(Set(entries.keys) == ["xl/workbook.xml", "xl/worksheets/sheet1.xml"])
        #expect(entries["xl/worksheets/sheet1.xml"]?.compressionMethod == 8)
    }

    @Test("A missing entry is named in the error rather than returning nothing")
    func missingEntryThrows() {
        let archive = makeArchive([(name: "a.xml", body: Data("a".utf8), deflate: false)])
        #expect(throws: ZipReader.ZipError.self) {
            _ = try ZipReader.data(named: "xl/sharedStrings.xml", in: archive)
        }
    }

    @Test("A file that is not a ZIP is refused")
    func nonArchiveIsRefused() {
        #expect(throws: ZipReader.ZipError.self) {
            _ = try ZipReader.entries(in: Data("not a zip at all".utf8))
        }
        #expect(throws: ZipReader.ZipError.self) {
            _ = try ZipReader.entries(in: Data())
        }
    }

    /// An empty part is legal and reads as empty rather than as a failure.
    @Test("An empty entry reads as empty")
    func emptyEntry() throws {
        let archive = makeArchive([(name: "empty.xml", body: Data(), deflate: false)])
        #expect(try ZipReader.data(named: "empty.xml", in: archive).isEmpty)
    }
}
