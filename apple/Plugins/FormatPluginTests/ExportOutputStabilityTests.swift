//
//  ExportOutputStabilityTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// The file a format writes is the contract, so these pin its bytes for the values each shortcut has to leave alone.
struct ExportOutputStabilityTests {
    private final class Source: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "PostgreSQL"
        private let elements: [PluginStreamElement]

        init(_ elements: [PluginStreamElement]) {
            self.elements = elements
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            let elements = elements
            return AsyncThrowingStream { continuation in
                for element in elements {
                    continuation.yield(element)
                }
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

        func escapeStringLiteral(_ value: String) -> String { value }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private static let table = PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)

    private static func header(_ columns: [String], types: [String]? = nil) -> PluginStreamElement {
        .header(PluginStreamHeader(columns: columns, columnTypeNames: types ?? columns.map { _ in "text" }))
    }

    private func csv(
        _ elements: [PluginStreamElement],
        configure: (inout CSVExportOptions) -> Void = { _ in }
    ) async throws -> (data: Data, result: ExportFormatResult) {
        var options = CSVExportOptions()
        options.includeFieldNames = false
        configure(&options)
        return try await CSVExportHarness.shared.bytes(options: options, tables: [Self.table], dataSource: Source(elements))
    }

    private func csvText(
        values: [String],
        configure: (inout CSVExportOptions) -> Void = { _ in }
    ) async throws -> String {
        let output = try await csv([Self.header(["a"]), .rows(values.map { [.text($0)] })], configure: configure)
        return String(decoding: output.data, as: UTF8.self)
    }

    private func ndjson(_ elements: [PluginStreamElement]) async throws -> String {
        let plugin = JSONExportPlugin()
        let stored = plugin.settings
        var options = JSONExportOptions()
        options.layout = .newlineDelimited
        plugin.settings = options
        defer { plugin.settings = stored }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try await plugin.export(
            tables: [Self.table],
            dataSource: Source(elements),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return String(decoding: try Data(contentsOf: destination), as: UTF8.self)
    }

    private func ndjsonValues(_ values: [String], type: String) async throws -> [String] {
        let text = try await ndjson([Self.header(["v"], types: [type]), .rows(values.map { [.text($0)] })])
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
            String(line.dropFirst(#"{"v": "#.count).dropLast())
        }
    }

    @Test("CSV quotes a value only for the characters that need it")
    func csvQuotesOnlyWhatNeedsIt() async throws {
        let text = try await csvText(values: [
            "plain", "a,b", #"say "hi""#, "tab\there", "two\nlines", "cr\rhere", "semi;colon", "", "é€🎉"
        ])

        let expected = [
            "plain", #""a,b""#, #""say ""hi""""#, "\"tab\there\"", "\"two\nlines\"", "\"cr\rhere\"", "semi;colon", "", "é€🎉"
        ]
        #expect(text == expected.joined(separator: "\n") + "\n")
    }

    @Test("CSV always-quote doubles quotes and leaves a null bare")
    func csvAlwaysQuote() async throws {
        let output = try await csv([Self.header(["a", "b"]), .rows([[.text(#"x"y"#), .null], [.text("plain"), .text("")]])]) {
            $0.quoteHandling = .always
        }

        #expect(String(decoding: output.data, as: UTF8.self) == "\"x\"\"y\",\n\"plain\",\"\"\n")
    }

    @Test("CSV never-quote writes the value as it is")
    func csvNeverQuote() async throws {
        let text = try await csvText(values: ["a,b", #"q"q"#]) { $0.quoteHandling = .never }

        #expect(text == "a,b\nq\"q\n")
    }

    @Test("CSV neutralises formula leads, full-width ones included, and leaves numbers alone")
    func csvSanitizesFormulas() async throws {
        let output = try await csv([
            Self.header(["a"]),
            .rows([[.text("=1+1")], [.text("-5")], [.text("-x")], [.text("\u{FF1D}1")], [.text("a=b")], [.text("@me")]])
        ]) {
            $0.sanitizeFormulas = true
        }

        #expect(String(decoding: output.data, as: UTF8.self) == "\"'=1+1\"\n-5\n\"'-x\"\n\"'\u{FF1D}1\"\na=b\n\"'@me\"\n")
        #expect(output.result.warnings.count == 1)
    }

    @Test("CSV decimal comma follows the column type and every digit the pattern accepts")
    func csvDecimalComma() async throws {
        let output = try await csv([
            Self.header(["price", "code", "untyped"], types: ["decimal(10,2)", "varchar", ""]),
            .rows([
                [.text("1.10"), .text("1.10"), .text("1.10")],
                [.text("\u{0663}.\u{0661}\u{0664}"), .text("v1.2"), .text("1.2.3")],
                [.text("1.5\n"), .text("x"), .text("-2.5")]
            ])
        ]) {
            $0.decimalFormat = .comma
            $0.delimiter = .semicolon
        }

        let expected = "1,10;1.10;1,10\n\u{0663},\u{0661}\u{0664};v1.2;1.2.3\n\"1,5\n\";x;-2,5\n"
        #expect(String(decoding: output.data, as: UTF8.self) == expected)
    }

    @Test("CSV turns line breaks into spaces and still quotes the value they came from")
    func csvLineBreaksBecomeSpaces() async throws {
        let text = try await csvText(values: ["a\r\nb", "plain"]) { $0.convertLineBreakToSpace = true }

        #expect(text == "\"a b\"\nplain\n")
    }

    @Test("CSV writes bytes as uppercase hex and a null as its placeholder")
    func csvBytesAndNull() async throws {
        let output = try await csv([Self.header(["a", "b", "c"]), .rows([[.bytes(Data([0x00, 0xAB, 0xFF])), .bytes(Data()), .null]])]) {
            $0.convertNullToEmpty = false
        }

        #expect(String(decoding: output.data, as: UTF8.self) == "0x00ABFF,0x,NULL\n")
    }

    @Test("CSV in a single-byte encoding composes a value and reports what it could not write")
    func csvSingleByteEncoding() async throws {
        let output = try await csv([Self.header(["a"]), .rows([[.text("e\u{301}")], [.text("日")]])]) {
            $0.encoding = .windowsCP1252
        }

        #expect(output.data == Data([0xE9, 0x0A, 0x3F, 0x0A]))
        #expect(output.result.warnings.count == 1)
    }

    @Test("A CSV larger than the write buffer keeps every row in order")
    func csvLargerThanTheBuffer() async throws {
        let values = (0 ..< 30_000).map { "row-\($0)-\(String(repeating: "x", count: 48))" }

        let text = try await csvText(values: values)

        #expect(text == values.joined(separator: "\n") + "\n")
    }

    @Test("JSON escapes what the format requires and drops a leading byte order mark")
    func jsonEscapes() async throws {
        let values = try await ndjsonValues(
            [#"say "hi""#, #"back\slash"#, "line\nbreak", "\u{1}", "\u{2028}", "a\u{85}b", "\u{FEFF}bom", "a\u{FEFF}b", "é€©🎉"],
            type: "text"
        )

        #expect(values == [
            #""say \"hi\"""#, #""back\\slash""#, #""line\nbreak""#, #""\u0001""#, "\"\\u2028\"", #""a\u0085b""#,
            #""bom""#, "\"a\u{FEFF}b\"", #""é€©🎉""#
        ])
    }

    @Test("JSON keeps a canonical number as sent and normalises every other spelling")
    func jsonNumbers() async throws {
        let values = try await ndjsonValues(
            ["42", "-1.50", "0", "-0", "0.5", "+1", "007", "5.", ".5", "1E3", "1.", "-", "", "abc", "1.2.3", "١"],
            type: "numeric(10,2)"
        )

        #expect(values == [
            "42", "-1.50", "0", "-0", "0.5", "1", "7", "5", "0.5", "1e3", "1",
            #""-""#, #""""#, #""abc""#, #""1.2.3""#, #""١""#
        ])
    }

    @Test("A canonical number takes the same path as the normaliser", arguments: [
        "1", "10", "-10", "0.0", "-0.10", "123456789012345678901234567890.123456789"
    ])
    func canonicalNumberMatchesTheNormaliser(value: String) {
        let written = JSONExportPlugin.formatJSONValue(.text(value), columnTypeName: "numeric", preserveAsString: false)

        #expect(written == JsonNumberNormalizer.numberLiteral(from: value))
        #expect(written == value)
    }

    @Test("JSON writes booleans only for a boolean column, in any letter case")
    func jsonBooleans() async throws {
        #expect(try await ndjsonValues(["TRUE", "false", "yes"], type: "Nullable(Bool)") == ["true", "false", #""yes""#])
        #expect(try await ndjsonValues(["TRUE"], type: "text") == [#""TRUE""#])
    }

    @Test("JSON escapes a column name once and skips columns a short row does not have")
    func jsonColumnsAndShortRows() async throws {
        let text = try await ndjson([
            Self.header([#"a"b"#, "c"], types: ["int"]),
            .rows([[.text("1"), .text("2")], [.text("3")], [.null, .bytes(Data([0xFF]))]])
        ])

        let expected = [#"{"a\"b": 1, "c": "2"}"#, #"{"a\"b": 3}"#, #"{"a\"b": null, "c": "/w=="}"#]
        #expect(text == expected.joined(separator: "\n") + "\n")
    }

    @Test("JSON writes an empty object for a row that arrives before its header")
    func jsonRowBeforeHeader() async throws {
        let text = try await ndjson([.rows([[.text("1")]]), Self.header(["a"]), .rows([[.text("2")]])])

        #expect(text == "{}\n{\"a\": \"2\"}\n")
    }

    @Test("JSON larger than the write buffer keeps every row in order")
    func jsonLargerThanTheBuffer() async throws {
        let values = (0 ..< 30_000).map { "row-\($0)-\(String(repeating: "x", count: 48))" }

        let text = try await ndjson([Self.header(["a"]), .rows(values.map { [.text($0)] })])

        #expect(text == values.map { "{\"a\": \"\($0)\"}\n" }.joined())
    }
}
