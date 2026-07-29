//
//  CsvRowConverterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

@testable import TablePro
import Testing

@Suite("CSV Row Converter")
struct CsvRowConverterTests {
    private func makeConverter(columns: [String], columnTypes: [ColumnType]) -> CsvRowConverter {
        CsvRowConverter(columns: columns, columnTypes: columnTypes)
    }

    @Test("Empty rows produces empty string")
    func emptyRows() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateCsv(rows: [], includeHeaders: false)
        #expect(result == "")
    }

    @Test("Plain values without quoting")
    func plainValues() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateCsv(rows: [["1", "alice"], ["2", "bob"]], includeHeaders: false)
        #expect(result == "1,alice\n2,bob\n")
    }

    @Test("Headers prepended when requested")
    func headers() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateCsv(rows: [["1", "alice"]], includeHeaders: true)
        #expect(result == "id,name\n1,alice\n")
    }

    @Test("NULL becomes empty field")
    func nullEmpty() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateCsv(rows: [["1", nil]], includeHeaders: false)
        #expect(result == "1,\n")
    }

    @Test("Mid-row NULL keeps subsequent columns aligned")
    func nullKeepsAlignment() {
        let converter = makeConverter(
            columns: ["a", "b", "c"],
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 3)
        )
        let result = converter.generateCsv(rows: [["a", nil, "c"]], includeHeaders: false)
        #expect(result == "a,,c\n")
    }

    @Test("Leading and trailing whitespace forces quoting")
    func whitespaceQuoting() {
        let converter = makeConverter(columns: ["name"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateCsv(rows: [[" leading"], ["trailing "]], includeHeaders: false)
        #expect(result == "\" leading\"\n\"trailing \"\n")
    }

    @Test("Values with commas are quoted")
    func commaQuoting() {
        let converter = makeConverter(columns: ["name"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateCsv(rows: [["doe, john"]], includeHeaders: false)
        #expect(result == "\"doe, john\"\n")
    }

    @Test("Embedded quotes are doubled")
    func quoteEscape() {
        let converter = makeConverter(columns: ["quote"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateCsv(rows: [["he said \"hi\""]], includeHeaders: false)
        #expect(result == "\"he said \"\"hi\"\"\"\n")
    }

    @Test("Newlines force quoting")
    func newlineQuoting() {
        let converter = makeConverter(columns: ["note"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateCsv(rows: [["line1\nline2"]], includeHeaders: false)
        #expect(result == "\"line1\nline2\"\n")
    }

    @Test("Header containing comma is quoted")
    func quotedHeader() {
        let converter = makeConverter(
            columns: ["first, last"],
            columnTypes: [.text(rawType: nil)]
        )
        let result = converter.generateCsv(rows: [["alice"]], includeHeaders: true)
        #expect(result == "\"first, last\"\nalice\n")
    }
}
