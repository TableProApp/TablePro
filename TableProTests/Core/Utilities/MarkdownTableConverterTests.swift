//
//  MarkdownTableConverterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

@testable import TablePro
import Testing

@Suite("Markdown Table Converter")
struct MarkdownTableConverterTests {
    private func makeConverter(columns: [String], columnTypes: [ColumnType]) -> MarkdownTableConverter {
        MarkdownTableConverter(columns: columns, columnTypes: columnTypes)
    }

    @Test("Header and alignment rows always emitted")
    func headerAlignment() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateMarkdown(rows: [["1", "alice"]])
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "| id | name |")
        #expect(lines[1] == "| --- | --- |")
        #expect(lines[2] == "| 1 | alice |")
    }

    @Test("NULL renders as NULL literal")
    func nullLiteral() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateMarkdown(rows: [["1", nil]])
        #expect(result.contains("| 1 | NULL |"))
    }

    @Test("Pipe characters in cells are escaped")
    func pipeEscape() {
        let converter = makeConverter(columns: ["expr"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateMarkdown(rows: [["a | b"]])
        #expect(result.contains("| a \\| b |"))
    }

    @Test("Newlines in cells become <br>")
    func newlineToBr() {
        let converter = makeConverter(columns: ["note"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateMarkdown(rows: [["line1\nline2"]])
        #expect(result.contains("line1<br>line2"))
    }

    @Test("Empty columns yields empty string")
    func emptyColumns() {
        let converter = makeConverter(columns: [], columnTypes: [])
        let result = converter.generateMarkdown(rows: [["x"]])
        #expect(result == "")
    }
}
