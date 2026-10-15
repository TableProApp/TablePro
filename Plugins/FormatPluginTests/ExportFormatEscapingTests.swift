//
//  ExportFormatEscapingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MarkdownExportEscapingTests {
    /// A pipe closes a cell, so a value holding one would end the cell early and shift every
    /// column after it.
    @Test("A pipe in a value is escaped")
    func pipeIsEscaped() {
        #expect(MarkdownTableRenderer.cell("a|b") == "a\\|b")
    }

    /// A backslash has to go first, or escaping the pipe afterwards produces `\\|`, which renders
    /// as a literal backslash followed by a cell break.
    @Test("A backslash is escaped before the pipe")
    func backslashIsEscapedFirst() {
        #expect(MarkdownTableRenderer.cell("a\\b") == "a\\\\b")
        #expect(MarkdownTableRenderer.cell("a\\|b") == "a\\\\\\|b")
    }

    /// No renderer accepts a raw newline inside a table cell, so it becomes a space rather than an
    /// escape that only some renderers read.
    @Test("Line breaks become spaces")
    func lineBreaksBecomeSpaces() {
        #expect(MarkdownTableRenderer.cell("a\nb") == "a b")
        #expect(MarkdownTableRenderer.cell("a\r\nb") == "a b")
        #expect(MarkdownTableRenderer.cell("a\rb") == "a b")
    }

    @Test("A row is delimited by pipes")
    func rowIsDelimited() {
        #expect(MarkdownTableRenderer.row(["a", "b"], widths: nil) == "| a | b |")
    }

    @Test("Aligned rows pad each cell to its column width")
    func alignedRowPads() {
        #expect(MarkdownTableRenderer.row(["a", "bb"], widths: [3, 4]) == "| a   | bb   |")
    }

    /// A cell wider than the measured width still has to be written whole, so the width is a
    /// minimum rather than a truncation.
    @Test("A cell wider than its column is not truncated")
    func wideCellSurvives() {
        #expect(MarkdownTableRenderer.row(["abcdef"], widths: [2]) == "| abcdef |")
    }

    @Test("The separator is at least three dashes per column")
    func separatorMinimumWidth() {
        #expect(MarkdownTableRenderer.separator(columnCount: 2, widths: nil) == "| --- | --- |")
        #expect(MarkdownTableRenderer.separator(columnCount: 1, widths: [6]) == "| ------ |")
        #expect(MarkdownTableRenderer.separator(columnCount: 1, widths: [1]) == "| --- |")
    }

    @Test("Widths come from the header and the sampled rows together")
    func widthsSpanHeaderAndRows() {
        let widths = MarkdownTableRenderer.widths(
            header: ["id", "name"], sample: [["1", "Ada"], ["100", "Grace"]])
        #expect(widths == [3, 5])
    }
}

struct PluginRowWritersTests {
    /// The values in an export come from the database rather than from the person opening the
    /// file, so a value that a spreadsheet would run as a formula is neutralised.
    @Test("Formula leads are neutralised and the value is then quoted")
    func formulaLeadsAreNeutralised() {
        let options = PluginCsvWriteOptions.default
        #expect(PluginRowWriters.csvField("=1+1", options: options) == "\"'=1+1\"")
        #expect(PluginRowWriters.csvField("+1", options: options) == "\"'+1\"")
        #expect(PluginRowWriters.csvField("-1", options: options) == "\"'-1\"")
        #expect(PluginRowWriters.csvField("@SUM", options: options) == "\"'@SUM\"")
    }

    /// Excel strips a leading tab or carriage return before parsing the cell, so `\t=1+1` reaches
    /// the formula engine exactly as `=1+1` would.
    @Test("A leading tab or carriage return counts as a formula lead")
    func whitespaceLeadCountsAsFormula() {
        let options = PluginCsvWriteOptions.default
        #expect(PluginRowWriters.csvField("\t=1+1", options: options).hasPrefix("\"'"))
        #expect(PluginRowWriters.csvField("\r=1+1", options: options).hasPrefix("\"'"))
    }

    @Test("Sanitizing off leaves the value alone")
    func sanitizingCanBeTurnedOff() {
        let options = PluginCsvWriteOptions(sanitizesFormulas: false)
        #expect(PluginRowWriters.csvField("=1+1", options: options) == "=1+1")
    }

    @Test("A value holding the delimiter or a quote is quoted and its quotes doubled")
    func quotingRules() {
        let options = PluginCsvWriteOptions.default
        #expect(PluginRowWriters.csvField("a,b", options: options) == "\"a,b\"")
        #expect(PluginRowWriters.csvField("say \"hi\"", options: options) == "\"say \"\"hi\"\"\"")
        #expect(PluginRowWriters.csvField("plain", options: options) == "plain")
    }

    @Test("Quote handling always and never are honoured")
    func quoteHandlingModes() {
        #expect(PluginRowWriters.csvField("plain", options: PluginCsvWriteOptions(quoteHandling: .always))
            == "\"plain\"")
        #expect(PluginRowWriters.csvField("a,b", options: PluginCsvWriteOptions(quoteHandling: .never))
            == "a,b")
    }

    @Test("A line break is kept and quoted, or flattened when asked")
    func lineBreakHandling() {
        #expect(PluginRowWriters.csvField("a\nb", options: PluginCsvWriteOptions()) == "\"a\nb\"")
        #expect(PluginRowWriters.csvField("a\nb", options: PluginCsvWriteOptions(flattensLineBreaks: true))
            == "a b")
    }

    @Test("A line joins its fields with the configured delimiter")
    func lineJoining() {
        let tabbed = PluginCsvWriteOptions(delimiter: "\t")
        #expect(PluginRowWriters.csvLine(["a", "b"], options: tabbed) == "a\tb")
    }

    @Test("A null is JSON null and bytes are base64")
    func jsonNullAndBytes() {
        #expect(PluginRowWriters.jsonValue(.null) == "null")
        #expect(PluginRowWriters.jsonValue(.bytes(Data([0x41, 0x42]))) == "\"QUI=\"")
    }

    /// A numeric-looking identifier stays a string unless its column is numeric, or a postcode
    /// loses its leading zero.
    @Test("Text is written unquoted only when its column is numeric")
    func numericOnlyWhenColumnSaysSo() {
        #expect(PluginRowWriters.jsonValue(.text("01234"), columnTypeName: "VARCHAR") == "\"01234\"")
        #expect(PluginRowWriters.jsonValue(.text("42"), columnTypeName: "INT") == "42")
        #expect(PluginRowWriters.jsonValue(.text("42"), columnTypeName: "") == "\"42\"")
        #expect(PluginRowWriters.jsonValue(.text("abc"), columnTypeName: "INT") == "\"abc\"")
    }

    @Test("Preserving strings quotes even a numeric column")
    func preserveAsStringWins() {
        #expect(PluginRowWriters.jsonValue(.text("42"), columnTypeName: "INT", preserveAsString: true)
            == "\"42\"")
    }

    @Test("A JSON object pairs columns with values and can drop nulls")
    func jsonObjectShape() {
        #expect(PluginRowWriters.jsonObject(columns: ["a", "b"], values: ["1", "null"])
            == "{\"a\": 1, \"b\": null}")
        #expect(PluginRowWriters.jsonObject(columns: ["a", "b"], values: ["1", "null"], includesNulls: false)
            == "{\"a\": 1}")
    }

    @Test("An insert names its columns and ends in a semicolon")
    func insertShape() {
        #expect(PluginRowWriters.sqlInsert(table: "\"t\"", columns: ["\"a\""], values: ["1"])
            == "INSERT INTO \"t\" (\"a\") VALUES (1);")
        #expect(PluginRowWriters.sqlInsert(table: "\"t\"", columns: [], values: []) == nil)
    }
}
