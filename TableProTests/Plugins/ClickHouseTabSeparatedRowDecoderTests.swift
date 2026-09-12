//
//  ClickHouseTabSeparatedRowDecoderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ClickHouse Tab Separated Row Decoder")
struct ClickHouseTabSeparatedRowDecoderTests {
    private struct Decoded {
        let header: ClickHouseTabSeparatedRowDecoder.Header?
        let rows: [[PluginCellValue]]
    }

    private static let header = Data("id\tlabel\tpayload\nUInt32\tString\tString\n".utf8)

    private func decodeAll(_ chunks: [Data]) -> Decoded {
        var decoder = ClickHouseTabSeparatedRowDecoder()
        var rows: [[PluginCellValue]] = []
        for chunk in chunks {
            rows.append(contentsOf: decoder.consume(chunk))
        }
        rows.append(contentsOf: decoder.finish())
        return Decoded(header: decoder.header, rows: rows)
    }

    private func decodeAll(_ body: Data) -> Decoded {
        decodeAll([body])
    }

    private func bytewise(_ body: Data) -> [[PluginCellValue]] {
        decodeAll(body.map { Data([$0]) }).rows
    }

    // MARK: - Header

    @Test("The first two lines are the column names and the column types")
    func readsNamesAndTypes() {
        let outcome = decodeAll(Self.header)
        #expect(outcome.header?.columns == ["id", "label", "payload"])
        #expect(outcome.header?.columnTypeNames == ["UInt32", "String", "String"])
        #expect(outcome.rows.isEmpty)
    }

    @Test("A body holding nothing reports no header")
    func emptyBodyHasNoHeader() {
        let outcome = decodeAll(Data())
        #expect(outcome.header == nil)
        #expect(outcome.rows.isEmpty)
    }

    @Test("A name that is not valid UTF-8 keeps the column rather than dropping it")
    func headerReplacesUndecodableBytes() {
        var body = Data("id\t".utf8)
        body.append(contentsOf: [0xDE, 0xAD])
        body.append(contentsOf: Data("\nUInt32\tString\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.header?.columns.count == 2)
        #expect(outcome.header?.columns.first == "id")
    }

    // MARK: - Values

    @Test("A field that decodes as UTF-8 is text")
    func decodesTextValues() {
        var body = Self.header
        body.append(contentsOf: Data("1\tünïcødé\thello\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("1"), .text("ünïcødé"), .text("hello")]])
    }

    @Test("A field that is not valid UTF-8 keeps its exact bytes")
    func keepsUndecodableBytes() {
        var body = Self.header
        body.append(contentsOf: Data("1\tplain\t".utf8))
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        body.append(contentsOf: Data("\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows.count == 1)
        #expect(outcome.rows[0][2] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }

    @Test("A binary value in one row leaves a text value in the same column as text")
    func decidesPerValueRatherThanPerColumn() {
        var body = Self.header
        body.append(contentsOf: Data("1\ta\t".utf8))
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        body.append(contentsOf: Data("\n2\tb\thello world\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows.count == 2)
        #expect(outcome.rows[0][2] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(outcome.rows[1][2] == .text("hello world"))
    }

    @Test("A lone backslash-N field is null")
    func readsNullMarker() {
        var body = Self.header
        body.append(contentsOf: Data("1\t\\N\tvalue\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("1"), .null, .text("value")]])
    }

    @Test("An escaped backslash before N is the literal text, not null")
    func escapedBackslashIsNotNull() {
        var body = Self.header
        body.append(contentsOf: Data("1\t\\\\N\tvalue\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("1"), .text("\\N"), .text("value")]])
    }

    @Test("Every escape ClickHouse writes comes back as its byte")
    func unescapesEveryEscape() {
        var body = Self.header
        body.append(contentsOf: Data("1\ta\\tb\\nc\\rd\\0e\\be\\fg\\'h\\\\i\tvalue\n".utf8))
        let outcome = decodeAll(body)
        let expected = "a\tb\nc\rd\u{0}e\u{8}e\u{C}g'h\\i"
        #expect(outcome.rows.count == 1)
        #expect(outcome.rows[0][1] == .text(expected))
    }

    @Test("Array, Map and Tuple arrive as the text ClickHouse writes for them")
    func keepsCompoundValuesAsWritten() {
        var body = Data("tags\tattrs\tpair\nArray(String)\tMap(String, String)\tTuple(UInt8, String)\n".utf8)
        body.append(contentsOf: Data("['a','b']\t{'k':'v'}\t(7,'x')\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("['a','b']"), .text("{'k':'v'}"), .text("(7,'x')")]])
    }

    // MARK: - Chunk boundaries

    @Test("A row split across two chunks decodes once it is whole")
    func joinsRowsAcrossChunks() {
        var first = Self.header
        first.append(contentsOf: Data("1\tlab".utf8))
        let second = Data("el\tvalue\n".utf8)
        let outcome = decodeAll([first, second])
        #expect(outcome.rows == [[.text("1"), .text("label"), .text("value")]])
    }

    @Test("A chunk that cuts a multi-byte character in half does not corrupt it")
    func joinsMultiByteCharactersAcrossChunks() {
        var body = Self.header
        body.append(contentsOf: Data("1\tünïcødé\tvalue\n".utf8))
        #expect(bytewise(body) == [[.text("1"), .text("ünïcødé"), .text("value")]])
    }

    @Test("Feeding one byte at a time gives the same rows as one chunk")
    func chunkingDoesNotChangeTheResult() {
        var body = Self.header
        body.append(contentsOf: Data("1\ta\t".utf8))
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        body.append(contentsOf: Data("\n2\tb\thello\n3\t\\N\t\\t\n".utf8))
        #expect(bytewise(body) == decodeAll(body).rows)
    }

    // MARK: - Body edges

    @Test("A body that ends without its closing newline still yields its last row")
    func yieldsUnterminatedFinalRow() {
        var body = Self.header
        body.append(contentsOf: Data("1\tlabel\tvalue".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("1"), .text("label"), .text("value")]])
    }

    @Test("A blank line between rows is not a row")
    func skipsBlankLines() {
        var body = Self.header
        body.append(contentsOf: Data("1\ta\tb\n\n2\tc\td\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows.count == 2)
    }

    @Test("A field holding nothing is empty text, never null")
    func emptyFieldIsEmptyText() {
        var body = Self.header
        body.append(contentsOf: Data("1\t\tvalue\n".utf8))
        let outcome = decodeAll(body)
        #expect(outcome.rows == [[.text("1"), .text(""), .text("value")]])
    }
}
