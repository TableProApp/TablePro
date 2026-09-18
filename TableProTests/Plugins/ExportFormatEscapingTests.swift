//
//  ExportFormatEscapingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Markdown export escaping")
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

@Suite("HTML export escaping")
struct HTMLExportEscapingTests {

    /// Every value in an export comes from the database, so a value holding markup reaches a file
    /// someone opens in a browser.
    @Test("Markup characters are escaped")
    func markupIsEscaped() {
        #expect(HTMLEscaping.text("<script>alert(1)</script>")
            == "&lt;script&gt;alert(1)&lt;/script&gt;")
    }

    /// The ampersand has to be replaced first, or the escapes written after it are themselves
    /// escaped and the value renders as `&amp;lt;`.
    @Test("An ampersand is escaped once, not twice")
    func ampersandEscapedOnce() {
        #expect(HTMLEscaping.text("&") == "&amp;")
        #expect(HTMLEscaping.text("&lt;") == "&amp;lt;")
        #expect(HTMLEscaping.text("a & b < c") == "a &amp; b &lt; c")
    }

    @Test("Quotes are escaped so a value cannot break out of an attribute")
    func quotesAreEscaped() {
        #expect(HTMLEscaping.text("\"x\"") == "&quot;x&quot;")
        #expect(HTMLEscaping.text("'x'") == "&#39;x&#39;")
    }

    @Test("Ordinary text is unchanged")
    func plainTextUnchanged() {
        #expect(HTMLEscaping.text("Ada Lovelace") == "Ada Lovelace")
        #expect(HTMLEscaping.text("") == "")
    }
}

@Suite("XML export escaping")
struct XMLExportEscapingTests {

    @Test("The five predefined entities are escaped")
    func entitiesAreEscaped() {
        #expect(XMLEscaping.text("<a & b>") == "&lt;a &amp; b&gt;")
        #expect(XMLEscaping.text("\"'") == "&quot;&apos;")
    }

    /// XML 1.0 accepts tab, newline and carriage return and no other control character. A stray
    /// 0x00 out of a binary column would otherwise make the whole document unparseable.
    @Test("Illegal control characters are dropped, legal whitespace is kept")
    func controlCharactersAreDropped() {
        #expect(XMLEscaping.text("a\u{0}b") == "ab")
        #expect(XMLEscaping.text("a\u{1}\u{1F}b") == "ab")
        #expect(XMLEscaping.text("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    /// A column name is not automatically a legal element name: XML forbids a leading digit and
    /// restricts the character set, and a database column has neither limit.
    @Test("A column name becomes a legal element name")
    func elementNamesAreLegal() {
        #expect(XMLEscaping.elementName("name") == "name")
        #expect(XMLEscaping.elementName("first_name") == "first_name")
        #expect(XMLEscaping.elementName("2024_total") == "_2024_total")
        #expect(XMLEscaping.elementName("order total") == "order_total")
        #expect(XMLEscaping.elementName("a-b.c") == "a-b.c")
    }

    /// Names beginning `xml` in any case are reserved by the specification.
    @Test("A reserved xml prefix is renamed")
    func reservedPrefixIsRenamed() {
        #expect(XMLEscaping.elementName("xmlData") == "_xmlData")
        #expect(XMLEscaping.elementName("XMLData") == "_XMLData")
    }

    @Test("A name with nothing legal in it falls back rather than producing invalid XML")
    func emptyNameFallsBack() {
        #expect(XMLEscaping.elementName("") == "column")
    }
}

@Suite("Parquet type mapping")
struct ParquetTypeMapperTests {

    @Test("Integer families map to BIGINT")
    func integerFamilies() {
        for type in ["INT", "int4", "BIGINT", "smallint", "TINYINT", "SERIAL", "MEDIUMINT"] {
            #expect(ParquetTypeMapper.duckDBType(forColumnType: type) == "BIGINT", "\(type)")
        }
    }

    @Test("Decimal families map to DOUBLE")
    func decimalFamilies() {
        for type in ["DECIMAL(10,2)", "numeric", "FLOAT", "double precision", "REAL", "money"] {
            #expect(ParquetTypeMapper.duckDBType(forColumnType: type) == "DOUBLE", "\(type)")
        }
    }

    @Test("Temporal families keep their own types")
    func temporalFamilies() {
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "DATE") == "DATE")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "timestamp with time zone") == "TIMESTAMP")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "datetime") == "TIMESTAMP")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "TIME") == "TIME")
    }

    @Test("Booleans and binaries map to their own types")
    func booleanAndBinary() {
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "BOOLEAN") == "BOOLEAN")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "bytea") == "BLOB")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "VARBINARY(50)") == "BLOB")
    }

    /// An unknown type is written as text rather than guessed at. A wrong guess writes a Parquet
    /// file whose column type disagrees with the data in it.
    @Test("An unknown type falls back to VARCHAR")
    func unknownFallsBack() {
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "geography") == "VARCHAR")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "") == "VARCHAR")
        #expect(ParquetTypeMapper.duckDBType(forColumnType: "hstore") == "VARCHAR")
    }

    /// A type name carries its width in parentheses and sometimes a modifier after a space, and
    /// neither changes which family it belongs to.
    @Test("Width and modifiers are stripped before matching")
    func baseNameStripsArgumentsAndModifiers() {
        #expect(ParquetTypeMapper.baseName("VARCHAR(64)") == "varchar")
        #expect(ParquetTypeMapper.baseName("NUMERIC(10, 2)") == "numeric")
        #expect(ParquetTypeMapper.baseName("INT UNSIGNED") == "int")
        #expect(ParquetTypeMapper.baseName("  TIMESTAMP WITH TIME ZONE ") == "timestamp")
    }

    @Test("Parquet holds one table per file, so a multi-table export numbers its files")
    func perTableFileNaming() {
        let base = URL(fileURLWithPath: "/tmp/dump.parquet")
        #expect(ParquetFileNaming.perTableURL(destination: base, table: "users").lastPathComponent
            == "dump.users.parquet")

        let noExtension = URL(fileURLWithPath: "/tmp/dump")
        #expect(ParquetFileNaming.perTableURL(destination: noExtension, table: "users").lastPathComponent
            == "dump.users")
    }

    /// A schema-qualified name carries a separator that would otherwise create a directory that
    /// does not exist.
    @Test("A table name with a slash cannot escape its directory")
    func slashesAreNeutralised() {
        let base = URL(fileURLWithPath: "/tmp/dump.parquet")
        let url = ParquetFileNaming.perTableURL(destination: base, table: "a/b")
        #expect(url.lastPathComponent == "dump.a_b.parquet")
        #expect(url.deletingLastPathComponent().path == "/tmp")
    }
}

@Suite("Shared row writers")
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
