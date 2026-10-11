//
//  DataFileExportFormatTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DataFileExportFormatTests {
    private static func dataSource() -> QueryResultExportDataSource {
        let rows = TableRows.from(
            queryRows: [["1", "O'Brien"], ["2", .null]],
            columns: ["id", "full \"name\""],
            columnTypes: [.integer(rawType: "INTEGER"), .text(rawType: "")]
        )
        return QueryResultExportDataSource(
            detachedRows: rows,
            databaseTypeId: DataSourceExportRequest.dataFileTypeId
        )
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
            dataSource: Self.dataSource()
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
            dataSource: Self.dataSource()
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
