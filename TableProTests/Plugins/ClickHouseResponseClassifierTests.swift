//
//  ClickHouseResponseClassifierTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ClickHouse Response Classifier")
struct ClickHouseResponseClassifierTests {
    private let matchingFormatHeaders = ["X-ClickHouse-Format": "TabSeparatedWithNamesAndTypes"]

    private func classify(
        headers: [String: String] = [:],
        bodyText: String,
        rowLimit: Int = PluginRowLimits.emergencyMax
    ) -> ClickHouseResponseClassifier.Outcome {
        ClickHouseResponseClassifier.classify(
            headers: headers,
            body: Data(bodyText.utf8),
            rowLimit: rowLimit
        )
    }

    // MARK: - No Result Set vs Empty Result Set

    @Test("An empty body is a statement without a result set")
    func emptyBodyHasNoResultSet() {
        let outcome = ClickHouseResponseClassifier.classify(headers: [:], body: Data())
        #expect(outcome.columns.isEmpty)
        #expect(outcome.rows.isEmpty)
        #expect(outcome.affectedRows == 0)
        #expect(!outcome.isTruncated)
    }

    @Test("An empty body reports written rows from the summary header")
    func emptyBodyReadsWrittenRowsFromSummary() {
        let headers = ["X-ClickHouse-Summary": #"{"read_rows":"0","written_rows":"42","total_rows_to_read":"0"}"#]
        let outcome = ClickHouseResponseClassifier.classify(headers: headers, body: Data())
        #expect(outcome.columns.isEmpty)
        #expect(outcome.affectedRows == 42)
    }

    @Test("An all-zero summary reports zero affected rows")
    func emptyBodyWithZeroSummary() {
        let headers = ["X-ClickHouse-Summary": #"{"read_rows":"0","written_rows":"0"}"#]
        let outcome = ClickHouseResponseClassifier.classify(headers: headers, body: Data())
        #expect(outcome.affectedRows == 0)
    }

    @Test("Read rows never count as affected rows")
    func readRowsAreNotAffectedRows() {
        let headers = ["X-ClickHouse-Summary": #"{"read_rows":"5000000","written_rows":"0"}"#]
        let outcome = ClickHouseResponseClassifier.classify(headers: headers, body: Data())
        #expect(outcome.affectedRows == 0)
    }

    @Test("A zero-row result keeps its column headers")
    func zeroRowResultKeepsColumns() {
        let outcome = classify(headers: matchingFormatHeaders, bodyText: "id\ttitle\nInt32\tString\n")
        #expect(outcome.columns == ["id", "title"])
        #expect(outcome.columnTypeNames == ["Int32", "String"])
        #expect(outcome.rows.isEmpty)
        #expect(outcome.affectedRows == 0)
    }

    // MARK: - Row-Returning Results

    @Test("A result with rows parses columns, types, and cells")
    func resultWithRowsParses() {
        let outcome = classify(
            headers: matchingFormatHeaders,
            bodyText: "id\tname\nUInt64\tString\n1\talpha\n2\tbeta\n"
        )
        #expect(outcome.columns == ["id", "name"])
        #expect(outcome.columnTypeNames == ["UInt64", "String"])
        #expect(outcome.rows == [[.text("1"), .text("alpha")], [.text("2"), .text("beta")]])
        #expect(outcome.affectedRows == 2)
        #expect(!outcome.isTruncated)
    }

    @Test("A response without a format header still parses as TSV")
    func missingFormatHeaderParsesAsTsv() {
        let outcome = classify(bodyText: "x\nUInt8\n1\n")
        #expect(outcome.columns == ["x"])
        #expect(outcome.rows == [[.text("1")]])
    }

    @Test("Null markers decode as null cells")
    func nullMarkerDecodesAsNull() {
        let outcome = classify(headers: matchingFormatHeaders, bodyText: "v\nNullable(String)\n\\N\n")
        #expect(outcome.rows == [[.null]])
    }

    @Test("Escaped fields are unescaped")
    func escapedFieldsAreUnescaped() {
        let outcome = classify(headers: matchingFormatHeaders, bodyText: "v\nString\na\\tb\\nc\\\\d\n")
        #expect(outcome.rows == [[.text("a\tb\nc\\d")]])
    }

    // MARK: - The Full Escape Table ClickHouse Writes

    @Test("Every escape the server emits is decoded, not left as two characters")
    func serverEscapeTableIsDecoded() {
        let outcome = classify(
            headers: matchingFormatHeaders,
            bodyText: "cr\tquote\tbell\tff\tnul\nString\tString\tString\tString\tString\n"
                + "a\\rb\ta\\'b\ta\\bb\ta\\fb\ta\\0b\n"
        )
        #expect(outcome.rows == [[
            .text("a\rb"),
            .text("a'b"),
            .text("a\u{8}b"),
            .text("a\u{C}b"),
            .text("a\u{0}b")
        ]])
    }

    @Test("A column type name carrying escaped quotes is reported unescaped")
    func columnTypeNameIsUnescaped() {
        let outcome = classify(
            headers: matchingFormatHeaders,
            bodyText: "e\nEnum8(\\'q\\' = 1)\nq\n"
        )
        #expect(outcome.columnTypeNames == ["Enum8('q' = 1)"])
    }

    @Test("A column name carrying an escaped tab keeps the column count")
    func columnNameWithEscapedTabIsOneColumn() {
        let outcome = classify(headers: matchingFormatHeaders, bodyText: "a\\tb\nString\nv\n")
        #expect(outcome.columns == ["a\tb"])
        #expect(outcome.rows == [[.text("v")]])
    }

    // MARK: - Binary Values

    @Test("A binary value stays bytes instead of being forced through a text decode")
    func binaryValueStaysBytes() {
        var body = Data("raw\nString\n".utf8)
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x0A])
        let outcome = ClickHouseResponseClassifier.classify(headers: matchingFormatHeaders, body: body)
        #expect(outcome.rows == [[.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))]])
    }

    @Test("A binary value in one column never mojibakes a text value in another")
    func binaryValueLeavesOtherColumnsIntact() {
        var body = Data("raw\ttxt\nString\tString\n".utf8)
        body.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x09])
        body.append(contentsOf: Data("héllo\n".utf8))
        let outcome = ClickHouseResponseClassifier.classify(headers: matchingFormatHeaders, body: body)
        #expect(outcome.rows == [[.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])), .text("héllo")]])
    }

    @Test("One undecodable value makes the whole column bytes, losslessly")
    func oneBinaryValueDemotesItsWholeColumn() {
        var body = Data("v\nString\n".utf8)
        body.append(contentsOf: Data("héllo\n".utf8))
        body.append(contentsOf: [0xC3, 0x0A])
        let outcome = ClickHouseResponseClassifier.classify(headers: matchingFormatHeaders, body: body)
        #expect(outcome.rows == [
            [.bytes(Data("héllo".utf8))],
            [.bytes(Data([0xC3]))]
        ])
    }

    @Test("A binary value does not demote a text column beside it")
    func demotionIsPerColumn() {
        var body = Data("a\tb\nString\tString\n".utf8)
        body.append(contentsOf: [0xC3, 0x09])
        body.append(contentsOf: Data("keep\n".utf8))
        let outcome = ClickHouseResponseClassifier.classify(headers: matchingFormatHeaders, body: body)
        #expect(outcome.rows == [[.bytes(Data([0xC3])), .text("keep")]])
    }

    @Test("A tab or newline inside binary data arrives escaped and never splits a field")
    func escapedControlBytesInBinaryDoNotSplitFields() {
        var body = Data("v\nString\n".utf8)
        body.append(contentsOf: Array("\\t\\n".utf8))
        body.append(contentsOf: [0x0B, 0x41, 0x0A])
        let outcome = ClickHouseResponseClassifier.classify(headers: matchingFormatHeaders, body: body)
        #expect(outcome.rows == [[.text("\t\n\u{B}A")]])
    }

    @Test("A body in another format that is not text is kept as bytes")
    func nonTextRawBodyIsKeptAsBytes() {
        let body = Data([0x00, 0x01, 0xFF, 0xFE])
        let outcome = ClickHouseResponseClassifier.classify(headers: ["X-ClickHouse-Format": "Native"], body: body)
        #expect(outcome.rows == [[.bytes(body)]])
    }

    @Test("A body cut by the byte cap mid-character still reads as text")
    func cappedBodyCutMidCharacterIsText() {
        let cap = 1_048_576
        var body = Data(repeating: UInt8(ascii: "x"), count: cap - 1)
        body.append(contentsOf: Data("é".utf8))
        let outcome = ClickHouseResponseClassifier.classify(headers: ["X-ClickHouse-Format": "Pretty"], body: body)
        #expect(outcome.isTruncated)
        #expect(outcome.rows[0][0].asText?.utf8.count == cap - 1)
    }

    @Test("A body the cap did not cut is never trimmed to make it decode")
    func uncutBodyIsNotTrimmed() {
        let body = Data([0x61, 0x62, 0xC3])
        let outcome = ClickHouseResponseClassifier.classify(headers: ["X-ClickHouse-Format": "Native"], body: body)
        #expect(outcome.rows == [[.bytes(body)]])
    }

    @Test("Rows beyond the limit are dropped and marked truncated")
    func rowLimitTruncates() {
        let outcome = classify(
            headers: matchingFormatHeaders,
            bodyText: "n\nUInt8\n1\n2\n3\n4\n5\n",
            rowLimit: 3
        )
        #expect(outcome.rows.count == 3)
        #expect(outcome.isTruncated)
    }

    // MARK: - User-Supplied FORMAT Clause

    @Test("A different response format wraps the raw body instead of discarding it")
    func mismatchedFormatWrapsRawBody() {
        let body = #"{"meta":[{"name":"1","type":"UInt8"}],"data":[[1]],"rows":1}"#
        let outcome = classify(headers: ["X-ClickHouse-Format": "JSON"], bodyText: body)
        #expect(outcome.columns.count == 1)
        #expect(outcome.columnTypeNames == ["String"])
        #expect(outcome.rows == [[.text(body)]])
        #expect(outcome.affectedRows == 1)
        #expect(!outcome.isTruncated)
    }

    @Test("A format header with different casing is still matched")
    func formatHeaderLookupIsCaseInsensitive() {
        let outcome = classify(headers: ["x-clickhouse-format": "CSV"], bodyText: "1,alpha\n")
        #expect(outcome.columnTypeNames == ["String"])
        #expect(outcome.rows == [[.text("1,alpha\n")]])
    }

    @Test("An oversized raw body is byte-capped and marked truncated")
    func oversizedRawBodyIsCapped() {
        let body = String(repeating: "x", count: 1_048_576 + 10)
        let outcome = classify(headers: ["X-ClickHouse-Format": "Pretty"], bodyText: body)
        #expect(outcome.isTruncated)
        let cell = outcome.rows[0][0].asText
        #expect(cell?.count == 1_048_576)
    }

    // MARK: - Malformed Bodies Never Vanish

    @Test("A single-line body falls back to raw output instead of empty columns")
    func singleLineBodyFallsBackToRaw() {
        let outcome = classify(bodyText: "1")
        #expect(outcome.columns.count == 1)
        #expect(outcome.rows == [[.text("1")]])
    }

    @Test("A whitespace-only body is a statement without a result set")
    func whitespaceOnlyBodyHasNoResultSet() {
        let outcome = classify(bodyText: "\n")
        #expect(outcome.columns.isEmpty)
        #expect(outcome.rows.isEmpty)
    }

    // MARK: - Summary Header Parsing

    @Test("A malformed summary header reports zero without throwing")
    func malformedSummaryReportsZero() {
        #expect(ClickHouseResponseClassifier.affectedRowsFromSummary(headers: ["X-ClickHouse-Summary": "not json"]) == 0)
        #expect(ClickHouseResponseClassifier.affectedRowsFromSummary(headers: [:]) == 0)
    }

    @Test("A numeric summary value is accepted alongside the string form")
    func numericSummaryValueIsAccepted() {
        let headers = ["X-ClickHouse-Summary": #"{"written_rows":7}"#]
        #expect(ClickHouseResponseClassifier.affectedRowsFromSummary(headers: headers) == 7)
    }

    // MARK: - Transport Query Items

    @Test("Transport items pin the format and buffer the response")
    func transportItemsPinFormatAndBuffer() {
        let items = ClickHouseResponseClassifier.transportQueryItems(supportsWriteExceptionSetting: true)
        #expect(items.contains(URLQueryItem(name: "default_format", value: "TabSeparatedWithNamesAndTypes")))
        #expect(items.contains(URLQueryItem(name: "wait_end_of_query", value: "1")))
        #expect(items.contains(URLQueryItem(name: "http_write_exception_in_output_format", value: "0")))
    }

    @Test("Older servers are not sent the write-exception setting")
    func olderServersOmitWriteExceptionSetting() {
        let items = ClickHouseResponseClassifier.transportQueryItems(supportsWriteExceptionSetting: false)
        #expect(items.contains(URLQueryItem(name: "default_format", value: "TabSeparatedWithNamesAndTypes")))
        #expect(items.contains(URLQueryItem(name: "wait_end_of_query", value: "1")))
        #expect(!items.contains { $0.name == "http_write_exception_in_output_format" })
    }
}
