//
//  XLSXExportBatchTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct XLSXExportBatchTests {
    // 7,000 rows in batches of `batchSize`, as a driver's stream hands them over.
    private final class BatchedDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "PostgreSQL"
        private let batchSize: Int

        init(batchSize: Int) {
            self.batchSize = batchSize
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            rows()
        }

        func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
            rows()
        }

        private func rows() -> AsyncThrowingStream<PluginStreamElement, Error> {
            let batchSize = batchSize
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(
                    columns: ["id", "name", "note"], columnTypeNames: ["int4", "text", "text"]
                )))
                let all: [PluginRow] = (1...7_000).map { id in
                    [.text(String(id)), .text("name \(id) & <more>"), id % 3 == 0 ? .null : .text(" pad \(id)")]
                }
                for start in stride(from: 0, to: all.count, by: batchSize) {
                    continuation.yield(.rows(Array(all[start ..< min(start + batchSize, all.count)])))
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

    private func sheetXML(batchSize: Int) async throws -> String {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let table = PluginExportTable(
            name: "people", databaseName: "", tableType: "table", optionValues: [], schema: nil, kind: .table
        )
        _ = try await XLSXExportPlugin().export(
            tables: [table],
            dataSource: BatchedDataSource(batchSize: batchSize),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return try XLSXArchiveContents(contentsOf: destination).xml(of: "xl/worksheets/sheet1.xml")
    }

    @Test("Each batch is written as it arrives: one batch of 7,000 rows writes the sheet seven of 1,000 do")
    func batchShapeDoesNotChangeTheSheet() async throws {
        let whole = try await sheetXML(batchSize: 7_000)
        let pieces = try await sheetXML(batchSize: 1_000)
        let single = try await sheetXML(batchSize: 1)
        #expect(whole == pieces)
        #expect(whole == single)
        #expect(whole.contains(#"<row r="7001">"#))
    }
}
