//
//  CSVInspectorTests.swift
//  TableProTests
//
//  Tests for CSVInspectorPlugin (compiled via symlinks from Plugins/CSVInspectorPlugin/).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("CSVDialect.detect")
struct CSVDialectDetectionTests {
    @Test("Detects comma delimiter")
    func commaDelimiter() {
        let csv = "a,b,c\n1,2,3\n".data(using: .utf8)!
        let dialect = CSVDialect.detect(from: csv)
        #expect(dialect.delimiter == 0x2C)
    }

    @Test("Detects tab delimiter")
    func tabDelimiter() {
        let tsv = "a\tb\tc\n1\t2\t3\n".data(using: .utf8)!
        let dialect = CSVDialect.detect(from: tsv)
        #expect(dialect.delimiter == 0x09)
    }

    @Test("Detects semicolon delimiter")
    func semicolonDelimiter() {
        let csv = "a;b;c\n1;2;3\n".data(using: .utf8)!
        let dialect = CSVDialect.detect(from: csv)
        #expect(dialect.delimiter == 0x3B)
    }

    @Test("Detects UTF-8 BOM")
    func utf8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("a,b\n1,2\n".data(using: .utf8)!)
        let dialect = CSVDialect.detect(from: data)
        #expect(dialect.hasBom)
        #expect(dialect.encoding == .utf8)
    }

    @Test("Detects UTF-16 LE BOM")
    func utf16LEBOM() {
        let data = Data([0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00, 0x62, 0x00])
        let dialect = CSVDialect.detect(from: data)
        #expect(dialect.hasBom)
        #expect(dialect.encoding == .utf16LittleEndian)
    }

    @Test("Detects CRLF line ending")
    func crlfLineEnding() {
        let csv = "a,b\r\n1,2\r\n".data(using: .utf8)!
        let dialect = CSVDialect.detect(from: csv)
        #expect(dialect.lineEnding == .crlf)
    }

    @Test("Detects LF line ending")
    func lfLineEnding() {
        let csv = "a,b\n1,2\n".data(using: .utf8)!
        let dialect = CSVDialect.detect(from: csv)
        #expect(dialect.lineEnding == .lf)
    }

    @Test("Quote-aware delimiter detection ignores embedded delimiters")
    func quoteAwareDelimiter() {
        let csv = #""a,b,c";"d,e,f"\n"x";"y"\n"#.replacingOccurrences(of: "\\n", with: "\n").data(using: .utf8)!
        let dialect = CSVDialect.detect(from: csv)
        #expect(dialect.delimiter == 0x3B)
    }

    @Test("Falls back to Windows-1252 on invalid UTF-8")
    func windowsCP1252Fallback() {
        var data = "name,value\n".data(using: .utf8)!
        data.append(Data([0xA3, 0x2C, 0x31, 0x0A]))
        let dialect = CSVDialect.detect(from: data)
        #expect(dialect.encoding == .windowsCP1252)
    }
}

@Suite("CSVStreamingParser")
struct CSVStreamingParserTests {
    private func parse(_ source: String, dialect: CSVDialect = .csv) -> (data: Data, ranges: [Range<Int>], parser: CSVStreamingParser) {
        let data = source.data(using: .utf8)!
        let parser = CSVStreamingParser(dialect: dialect)
        let ranges = data.withUnsafeBytes { raw -> [Range<Int>] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return parser.indexRows(UnsafeBufferPointer(start: base, count: raw.count))
        }
        return (data, ranges, parser)
    }

    private func row(_ data: Data, _ parser: CSVStreamingParser, _ range: Range<Int>) -> [String] {
        data.withUnsafeBytes { raw -> [String] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return parser.parseRow(UnsafeBufferPointer(start: base, count: raw.count), range: range)
        }
    }

    @Test("Indexes simple three-row CSV")
    func simpleThreeRows() {
        let (_, ranges, _) = parse("a,b,c\n1,2,3\n4,5,6\n")
        #expect(ranges.count == 3)
    }

    @Test("Indexes row without trailing newline")
    func noTrailingNewline() {
        let (_, ranges, _) = parse("a,b\n1,2")
        #expect(ranges.count == 2)
    }

    @Test("Quoted field with embedded delimiter stays in one row")
    func quotedEmbeddedDelimiter() {
        let (data, ranges, parser) = parse(#"a,"hello, world",c"# + "\n")
        #expect(ranges.count == 1)
        let fields = row(data, parser, ranges[0])
        #expect(fields == ["a", "hello, world", "c"])
    }

    @Test("Quoted field with embedded newline stays in one row")
    func quotedEmbeddedNewline() {
        let (data, ranges, parser) = parse("a,\"line1\nline2\",c\nx,y,z\n")
        #expect(ranges.count == 2)
        let fields = row(data, parser, ranges[0])
        #expect(fields == ["a", "line1\nline2", "c"])
    }

    @Test("RFC 4180 doubled-quote escape decodes to single quote")
    func doubledQuoteEscape() {
        let (data, ranges, parser) = parse(#"a,"say ""hi""",c"# + "\n")
        let fields = row(data, parser, ranges[0])
        #expect(fields == ["a", #"say "hi""#, "c"])
    }

    @Test("Empty fields preserved")
    func emptyFields() {
        let (data, ranges, parser) = parse(",,,\n")
        let fields = row(data, parser, ranges[0])
        #expect(fields == ["", "", "", ""])
    }

    @Test("field(at:column:) matches parseRow for ASCII data")
    func fieldMatchesParseRow() {
        let (data, ranges, parser) = parse("alpha,beta,gamma,delta\n")
        let full = row(data, parser, ranges[0])
        for column in 0..<full.count {
            let single = data.withUnsafeBytes { raw -> String in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
                return parser.field(UnsafeBufferPointer(start: base, count: raw.count), range: ranges[0], column: column)
            }
            #expect(single == full[column])
        }
    }

    @Test("field(at:column:) handles quoted fields with embedded delimiter")
    func fieldHandlesQuoted() {
        let (data, ranges, parser) = parse(#"a,"x,y,z",c"# + "\n")
        let middle = data.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
            return parser.field(UnsafeBufferPointer(start: base, count: raw.count), range: ranges[0], column: 1)
        }
        #expect(middle == "x,y,z")
    }

    @Test("field(at:column:) returns empty for out-of-range column")
    func fieldOutOfRange() {
        let (data, ranges, parser) = parse("a,b\n")
        let outOfRange = data.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
            return parser.field(UnsafeBufferPointer(start: base, count: raw.count), range: ranges[0], column: 99)
        }
        #expect(outOfRange == "")
    }
}

@Suite("CSVRowStore")
struct CSVRowStoreTests {
    private func makeStore(_ source: String, dialect: CSVDialect = .csv) -> CSVRowStore {
        CSVRowStore(data: source.data(using: .utf8)!, dialect: dialect)
    }

    @Test("Detects header row from non-numeric first row")
    func detectsHeader() {
        let store = makeStore("name,age,city\nAlice,30,Paris\n")
        #expect(store.columnNames == ["name", "age", "city"])
        #expect(store.rowCount == 1)
    }

    @Test("Synthesizes header when first row is numeric")
    func synthesizesHeader() {
        let store = makeStore("1,2,3\n4,5,6\n")
        #expect(store.columnNames == ["Column 1", "Column 2", "Column 3"])
        #expect(store.rowCount == 2)
    }

    @Test("value(row:column:) returns correct cell")
    func valueReturnsCell() {
        let store = makeStore("a,b,c\n1,2,3\n4,5,6\n")
        #expect(store.value(row: 0, column: 0) == "1")
        #expect(store.value(row: 0, column: 2) == "3")
        #expect(store.value(row: 1, column: 1) == "5")
    }

    @Test("setValue updates cell and round-trips via value()")
    func setValueRoundTrip() {
        let store = makeStore("a,b\n1,2\n3,4\n")
        store.setValue("99", row: 1, column: 0)
        #expect(store.value(row: 1, column: 0) == "99")
    }

    @Test("snapshot.cells(at:) matches store.cells(forRow:)")
    func snapshotCellsMatchStore() {
        let store = makeStore("a,b,c\n1,2,3\nfoo,bar,baz\n")
        let snapshot = store.snapshot()
        #expect(snapshot.rowCount == 2)
        #expect(snapshot.cells(at: 0) == store.cells(forRow: 0))
        #expect(snapshot.cells(at: 1) == store.cells(forRow: 1))
    }

    @Test("snapshot.field(at:column:) matches snapshot.cells(at:)[column]")
    func snapshotFieldMatchesCells() {
        let store = makeStore("a,b,c\nalpha,beta,gamma\nx,y,z\n")
        let snapshot = store.snapshot()
        for row in 0..<snapshot.rowCount {
            let cells = snapshot.cells(at: row)
            for column in 0..<cells.count {
                #expect(snapshot.field(at: row, column: column) == cells[column])
            }
        }
    }

    @Test("removeRows(at:) removes specified rows and returns captures")
    func bulkRemoveRows() {
        let store = makeStore("a,b\n1,1\n2,2\n3,3\n4,4\n5,5\n")
        let removed = store.removeRows(at: IndexSet([0, 2, 4]))
        #expect(removed.count == 3)
        #expect(removed.map(\.index) == [0, 2, 4])
        #expect(removed.map(\.cells) == [["1", "1"], ["3", "3"], ["5", "5"]])
        #expect(store.rowCount == 2)
        #expect(store.cells(forRow: 0) == ["2", "2"])
        #expect(store.cells(forRow: 1) == ["4", "4"])
    }

    @Test("removeRows with empty index set is a no-op")
    func bulkRemoveEmpty() {
        let store = makeStore("a,b\n1,1\n2,2\n")
        let removed = store.removeRows(at: IndexSet())
        #expect(removed.isEmpty)
        #expect(store.rowCount == 2)
    }

    @Test("removeRows capture supports undo round-trip via ascending reinsert")
    func bulkRemoveUndoRoundTrip() {
        let store = makeStore("a,b\n1,1\n2,2\n3,3\n4,4\n5,5\n")
        let removed = store.removeRows(at: IndexSet([0, 2, 4]))
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            store.insertRow(entry.cells, at: entry.index)
        }
        #expect(store.rowCount == 5)
        #expect(store.cells(forRow: 0) == ["1", "1"])
        #expect(store.cells(forRow: 1) == ["2", "2"])
        #expect(store.cells(forRow: 2) == ["3", "3"])
        #expect(store.cells(forRow: 3) == ["4", "4"])
        #expect(store.cells(forRow: 4) == ["5", "5"])
    }

    @Test("renameColumn updates columnNames in place")
    func renameColumnInPlace() {
        let store = makeStore("a,b,c\n1,2,3\n")
        store.renameColumn(at: 1, to: "bb")
        #expect(store.columnNames == ["a", "bb", "c"])
    }

    @Test("appendColumn adds column at end")
    func appendColumn() {
        let store = makeStore("a,b\n1,2\n3,4\n")
        store.appendColumn(name: "c")
        #expect(store.columnNames == ["a", "b", "c"])
    }

    @Test("removeColumn drops column and shifts subsequent values")
    func removeColumn() {
        let store = makeStore("a,b,c\n1,2,3\n4,5,6\n")
        _ = store.removeColumn(at: 1)
        #expect(store.columnNames == ["a", "c"])
        #expect(store.cells(forRow: 0) == ["1", "3"])
    }
}

@Suite("CSVWriter round-trip")
struct CSVWriterRoundTripTests {
    private func tempURL(extension ext: String = "csv") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    @Test("Round-trip preserves byte-for-byte for unmodified rows")
    func roundTripUnmodified() throws {
        let source = "name,age,city\nAlice,30,Paris\nBob,25,London\nCarol,40,Tokyo\n"
        let url = tempURL()
        try source.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let dialect = CSVDialect.detect(from: data)
        let store = CSVRowStore(data: data, dialect: dialect)

        let outURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        try CSVWriter(dialect: dialect).write(store, to: outURL)
        let written = try Data(contentsOf: outURL)
        #expect(written == data)
    }

    @Test("Round-trip after edit preserves untouched rows")
    func roundTripAfterEdit() throws {
        let source = "a,b\n1,2\n3,4\n5,6\n"
        let url = tempURL()
        try source.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let dialect = CSVDialect.detect(from: data)
        let store = CSVRowStore(data: data, dialect: dialect)
        store.setValue("99", row: 1, column: 0)

        let outURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        try CSVWriter(dialect: dialect).write(store, to: outURL)

        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "a,b\n1,2\n99,4\n5,6\n")
    }

    @Test("Round-trip preserves BOM when present")
    func roundTripBOM() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        source.append("a,b\n1,2\n".data(using: .utf8)!)
        let url = tempURL()
        try source.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let dialect = CSVDialect.detect(from: data)
        let store = CSVRowStore(data: data, dialect: dialect)

        let outURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        try CSVWriter(dialect: dialect).write(store, to: outURL)

        let written = try Data(contentsOf: outURL)
        #expect(written.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    }
}
