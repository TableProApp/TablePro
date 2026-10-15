//
//  DataFileExportSourceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// FormatPluginTests' DataFileExportFormatTests runs the SQL and CSV exports over a source shaped like this one.
struct DataFileExportSourceTests {
    @Test("A data file's export source hands a format its header, its rows, ANSI quoting and no engine session")
    func dataFileSourceIsWhatTheFormatsAreHeldTo() async throws {
        let rows = TableRows.from(
            queryRows: [["1", "O'Brien"], ["2", .null]],
            columns: ["id", "full \"name\""],
            columnTypes: [.integer(rawType: "INTEGER"), .text(rawType: "")]
        )
        let source = QueryResultExportDataSource(
            detachedRows: rows,
            databaseTypeId: DataSourceExportRequest.dataFileTypeId
        )

        #expect(source.databaseTypeId == "DataFile")
        #expect(source.quoteIdentifier("full \"name\"") == "\"full \"\"name\"\"\"")
        #expect(source.escapeStringLiteral("O'Brien") == "O''Brien")

        var header: PluginStreamHeader?
        var streamed: [[PluginCellValue]] = []
        for try await element in source.streamRows(table: "order items", databaseName: "") {
            if case .header(let first) = element { header = first }
            if case .rows(let batch) = element { streamed.append(contentsOf: batch) }
        }
        #expect(header?.columns == ["id", "full \"name\""])
        #expect(header?.columnTypeNames == ["INTEGER", ""])
        #expect(streamed == [[.text("1"), .text("O'Brien")], [.text("2"), .null]])

        await #expect(throws: (any Error).self) {
            _ = try await source.execute(query: "SELECT 1")
        }
    }
}
