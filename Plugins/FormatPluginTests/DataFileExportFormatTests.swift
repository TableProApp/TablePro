//
//  DataFileExportFormatTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct DataFileExportFormatTests {
    /// What the app's `QueryResultExportDataSource(detachedRows:databaseTypeId:)` hands a format for a data file: the
    /// `DataFile` type id, ANSI quoting and escaping, and no engine session.
    private final class DataFileSource: PluginExportDataSource, @unchecked Sendable {
        struct NoSession: Error {}

        let databaseTypeId = "DataFile"

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(
                    columns: ["id", "full \"name\""],
                    columnTypeNames: ["INTEGER", ""],
                    estimatedRowCount: 2
                )))
                continuation.yield(.rows([[.text("1"), .text("O'Brien")], [.text("2"), .null]]))
                continuation.finish()
            }
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { 2 }

        func quoteIdentifier(_ identifier: String) -> String {
            "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: "\0", with: "")
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            throw NoSession()
        }
    }

    private static func table(optionValues: [Bool]) -> PluginExportTable {
        PluginExportTable(
            name: "order items",
            databaseName: "",
            tableType: "query",
            optionValues: optionValues,
            schema: nil,
            kind: .table
        )
    }

    @Test("A SQL export of a data file quotes and escapes the ANSI way and opens no engine session")
    func sqlExportIsAnsi() async throws {
        let output = try await SQLExportHarness.shared.dump(
            tables: [Self.table(optionValues: [false, false, true])],
            dataSource: DataFileSource()
        )

        #expect(output.text.contains("-- Database Type: DataFile"))
        #expect(output.text.contains("INSERT INTO \"order items\" (\"id\", \"full \"\"name\"\"\") VALUES"))
        #expect(output.text.contains("(1, 'O''Brien')"))
        #expect(output.text.contains("(2, NULL)"))
        #expect(!output.text.contains("`"))
        #expect(!output.text.contains("SET NAMES"))
        #expect(!output.text.contains("SET client_encoding"))
    }

    @Test("A CSV export of a data file writes its header and every row")
    func csvExportWritesEveryRow() async throws {
        let output = try await CSVExportHarness.shared.bytes(
            options: CSVExportOptions(),
            tables: [Self.table(optionValues: [])],
            dataSource: DataFileSource()
        )
        let text = try #require(String(bytes: output.data, encoding: .utf8))
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }

        #expect(lines.count == 3)
        #expect(lines.last == "2,")
        #expect(lines.first?.contains("\"full \"\"name\"\"\"") == true)
    }
}
