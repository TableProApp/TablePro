//
//  ExportFormatRowScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ExportFormatRowScopeTests {
    private final class ScopedExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "SQLite"
        private let values = ["alpha", "beta", "gamma"]

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            rows(limit: nil)
        }

        func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
            rows(limit: object.rowScope.rowLimit)
        }

        private func rows(limit: Int?) -> AsyncThrowingStream<PluginStreamElement, Error> {
            let kept = values.prefix(limit ?? values.count)
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["name"], columnTypeNames: ["TEXT"])))
                continuation.yield(.rows(kept.map { [.text($0)] }))
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

    private func firstRowOnly(optionValues: [Bool]) -> PluginExportTable {
        PluginExportTable(
            name: "people",
            databaseName: "",
            tableType: "table",
            optionValues: optionValues,
            schema: nil,
            kind: .table,
            rowScope: PluginExportRowScope(rowLimit: 1)
        )
    }

    private func exportedText(
        by plugin: any ExportFormatPlugin,
        table: PluginExportTable,
        fileExtension: String
    ) async throws -> String {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await plugin.export(
            tables: [table],
            dataSource: ScopedExportDataSource(),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        let written = try Data(contentsOf: destination)
        return try #require(String(bytes: written, encoding: .isoLatin1))
    }

    @Test("A CSV export writes only the rows its row scope keeps")
    func csvHonorsRowScope() async throws {
        let output = try await CSVExportHarness.shared.bytes(
            options: CSVExportOptions(),
            tables: [firstRowOnly(optionValues: [true, true, true])],
            dataSource: ScopedExportDataSource()
        )
        #expect(output.data == Data("name\nalpha\n".utf8))
    }

    @Test("An XLSX export writes only the rows its row scope keeps")
    func xlsxHonorsRowScope() async throws {
        let text = try await exportedText(
            by: XLSXExportPlugin(),
            table: firstRowOnly(optionValues: []),
            fileExtension: "xlsx"
        )
        #expect(text.contains("alpha"))
        #expect(!text.contains("beta"))
        #expect(!text.contains("gamma"))
    }

    @Test("An MQL export writes only the documents its row scope keeps")
    func mqlHonorsRowScope() async throws {
        let text = try await exportedText(
            by: MQLExportPlugin(),
            table: firstRowOnly(optionValues: [false, false, true]),
            fileExtension: "js"
        )
        #expect(text.contains("\"alpha\""))
        #expect(!text.contains("beta"))
        #expect(!text.contains("gamma"))
    }
}
