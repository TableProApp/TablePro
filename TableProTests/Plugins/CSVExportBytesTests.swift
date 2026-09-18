//
//  CSVExportBytesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// What reaches the file, asserted as bytes. Every write the exporter makes goes through one
/// encoder, and a call site that missed it would still produce a readable file in the default
/// UTF-8 case, so only the bytes of a non-UTF-8 export can catch one.
@Suite("CSV export bytes")
struct CSVExportBytesTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "SQLite"
        let rows: [[PluginCellValue]]
        let columns: [String]

        init(columns: [String], rows: [[PluginCellValue]]) {
            self.columns = columns
            self.rows = rows
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: columns.map { _ in "TEXT" }
                )))
                continuation.yield(.rows(rows))
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

    private func table(_ name: String) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "", tableType: "table", optionValues: [true, true, true], schema: nil)
    }

    private func export(
        _ options: CSVExportOptions,
        columns: [String] = ["name"],
        rows: [[PluginCellValue]],
        tables: [String] = ["people"]
    ) async throws -> (data: Data, result: ExportFormatResult) {
        try await CSVExportHarness.shared.bytes(
            options: options,
            tables: tables.map(table),
            dataSource: StubExportDataSource(columns: columns, rows: rows)
        )
    }

    @Test("The stock export is UTF-8 with no mark")
    func defaultExportIsPlainUTF8() async throws {
        let output = try await export(CSVExportOptions(), rows: [[.text("café")]])
        #expect(output.data == Data("name\ncafé\n".utf8))
        #expect(output.result.warnings.isEmpty)
    }

    @Test("The byte order mark opens the file, before the header row")
    func markComesFirst() async throws {
        var options = CSVExportOptions()
        options.writesByteOrderMark = true
        let output = try await export(options, rows: [[.text("café")]])
        #expect(output.data == Data([0xEF, 0xBB, 0xBF]) + Data("name\ncafé\n".utf8))
    }

    /// The flag survives a detour through an encoding that has no mark, so a choice made for UTF-8
    /// is still there on the way back. It just writes nothing while the detour lasts.
    @Test("An encoding with no mark writes none even when the option is on")
    func markIsIgnoredWithoutOne() async throws {
        var options = CSVExportOptions()
        options.encoding = .windowsCP1252
        options.writesByteOrderMark = true
        let output = try await export(options, rows: [[.text("cafe")]])
        #expect(output.data == Data("name\ncafe\n".utf8))
    }

    @Test("Windows-1252 writes single-byte values")
    func windows1252WritesSingleBytes() async throws {
        var options = CSVExportOptions()
        options.encoding = .windowsCP1252
        let output = try await export(options, rows: [[.text("café")]])
        #expect(output.data == Data([0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x0A]))
        #expect(output.result.warnings.isEmpty)
    }

    @Test("A value the encoding cannot represent is written as a question mark and warned about")
    func unrepresentableValueWarns() async throws {
        var options = CSVExportOptions()
        options.encoding = .isoLatin1
        let output = try await export(options, rows: [[.text("東京")], [.text("Paris")]])
        #expect(output.data == Data([
            0x6E, 0x61, 0x6D, 0x65, 0x0A,
            0x3F, 0x3F, 0x0A,
            0x50, 0x61, 0x72, 0x69, 0x73, 0x0A
        ]))
        let warning = try #require(output.result.warnings.first)
        #expect(warning.contains("ISO Latin 1"))
        #expect(warning.contains("東"))
        #expect(warning.contains("京"))
    }

    /// One plugin instance serves every window, so an export reads its options once at the start.
    /// A picker changed in another window's dialog must not reach a file already being written.
    @Test("Changing the encoding mid-export does not reach the file")
    func encodingIsCapturedForTheWholeExport() async throws {
        var options = CSVExportOptions()
        options.encoding = .isoLatin1
        let output = try await export(options, rows: [[.text("café")], [.text("crème")]])
        #expect(output.data == Data([
            0x6E, 0x61, 0x6D, 0x65, 0x0A,
            0x63, 0x61, 0x66, 0xE9, 0x0A,
            0x63, 0x72, 0xE8, 0x6D, 0x65, 0x0A
        ]))
        #expect(output.result.warnings.isEmpty)
    }

    /// The header row is encoded on the same path as the values, so a column name outside the
    /// encoding is reported rather than silently mangled.
    @Test("A column name the encoding cannot represent is reported too")
    func headerIsEncodedOnTheSamePath() async throws {
        var options = CSVExportOptions()
        options.encoding = .windowsCP1252
        let output = try await export(options, columns: ["名前"], rows: [[.text("Ada")]])
        let warning = try #require(output.result.warnings.first)
        #expect(warning.contains("名"))
        #expect(warning.contains("前"))
    }

    /// Every line the multi-table branch writes takes the chosen line ending, the comment line
    /// included. A lone LF among CRLFs joins the comment onto the header for a reader that splits
    /// on CRLF alone.
    @Test("The table comment line takes the chosen line ending")
    func tableCommentTakesTheLineEnding() async throws {
        var options = CSVExportOptions()
        options.lineBreak = .crlf
        let output = try await export(options, rows: [[.text("Ada")]], tables: ["people", "orders"])
        let text = try #require(String(data: output.data, encoding: .utf8))
        #expect(text.hasPrefix("# Table: people\r\n"))
        let bytes = [UInt8](output.data)
        let lonelyFeeds = bytes.indices.filter { bytes[$0] == 0x0A && ($0 == 0 || bytes[$0 - 1] != 0x0D) }
        #expect(lonelyFeeds.isEmpty)
    }
}
