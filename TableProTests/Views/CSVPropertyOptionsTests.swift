//
//  CSVPropertyOptionsTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import Testing

@Suite("CSVPropertyOptions")
struct CSVPropertyOptionsTests {
    @Test("Indices map back from a dialect's bytes and values")
    func indicesFromDialect() {
        #expect(CSVPropertyOptions.delimiterIndex(for: 0x3B) == 1)
        #expect(CSVPropertyOptions.quoteIndex(for: 0x27) == 1)
        #expect(CSVPropertyOptions.encodingIndex(for: .windowsCP1252) == 4)
        #expect(CSVPropertyOptions.lineEndingIndex(for: .crlf) == 1)
    }

    @Test("An unknown delimiter falls back to the first option")
    func unknownFallsBack() {
        #expect(CSVPropertyOptions.delimiterIndex(for: 0x5E) == 0)
    }

    @Test("Building a dialect from indices sets the four properties and keeps the BOM")
    func dialectRoundTrip() {
        let base = CSVDialect(delimiter: 0x2C, hasBom: true)
        let dialect = CSVPropertyOptions.dialect(
            base: base,
            delimiterIndex: CSVPropertyOptions.delimiterIndex(for: 0x09),
            quoteIndex: CSVPropertyOptions.quoteIndex(for: 0x27),
            encodingIndex: CSVPropertyOptions.encodingIndex(for: .utf16LittleEndian),
            lineEndingIndex: CSVPropertyOptions.lineEndingIndex(for: .cr)
        )
        #expect(dialect.delimiter == 0x09)
        #expect(dialect.quoteChar == 0x27)
        #expect(dialect.encoding == .utf16LittleEndian)
        #expect(dialect.lineEnding == .cr)
        #expect(dialect.hasBom)
    }
}
