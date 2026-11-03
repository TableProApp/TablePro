//
//  MQLExportValueTypeTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct MQLExportValueTypeTests {
    private final class CollectionDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "MongoDB"
        let header: PluginStreamHeader
        let rows: [[PluginCellValue]]

        init(header: PluginStreamHeader, rows: [[PluginCellValue]]) {
            self.header = header
            self.rows = rows
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            let header = header
            let rows = rows
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(header))
                continuation.yield(.rows(rows))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { identifier }

        func escapeStringLiteral(_ value: String) -> String { value }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"

    private func exportedScript(header: PluginStreamHeader, rows: [[PluginCellValue]]) async throws -> String {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: destination) }
        let table = PluginExportTable(
            name: "people",
            databaseName: "",
            tableType: "table",
            optionValues: [false, false, true],
            schema: nil,
            kind: .table
        )
        _ = try await MQLExportPlugin().export(
            tables: [table],
            dataSource: CollectionDataSource(header: header, rows: rows),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return try String(contentsOf: destination, encoding: .utf8)
    }

    @Test("String fields shaped like booleans, numbers, documents or UUIDs are exported as strings")
    func stringFieldsStayStrings() async throws {
        let header = PluginStreamHeader(
            columns: ["_id", "flag", "count", "nothing", "doc", "list", "ref"],
            columnTypeNames: ["VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR"]
        )
        let row: [PluginCellValue] = [
            .text("42"), .text("true"), .text("-3.5"), .text("null"), .text("{\"a\":1}"), .text("[1,2]"),
            .text("UUID(\"\(Self.uuid)\")")
        ]
        let script = try await exportedScript(header: header, rows: [row])
        let expected = "  {\"_id\": \"42\", \"flag\": \"true\", \"count\": \"-3.5\", \"nothing\": \"null\", "
            + "\"doc\": \"{\\\"a\\\":1}\", \"list\": \"[1,2]\", \"ref\": \"UUID(\\\"\(Self.uuid)\\\")\"}"
        #expect(script.contains("db.people.insertMany([\n\(expected)\n]);"))
    }

    @Test("Typed fields are exported as the type their column reports")
    func typedFieldsKeepTheirTypes() async throws {
        let header = PluginStreamHeader(
            columns: ["_id", "flag", "count", "doc", "ref"],
            columnTypeNames: ["ObjectId", "BOOLEAN", "INTEGER", "JSON", "UUID"]
        )
        let row: [PluginCellValue] = [
            .text("507f1f77bcf86cd799439011"), .text("true"), .text("42"), .text("{\"a\":1}"),
            .text("UUID(\"\(Self.uuid)\")")
        ]
        let script = try await exportedScript(header: header, rows: [row])
        let expected = "  {\"_id\": ObjectId(\"507f1f77bcf86cd799439011\"), \"flag\": true, \"count\": 42, "
            + "\"doc\": {\"a\":1}, \"ref\": BinData(4, \"jNAD60olQySTMoj84toNGg==\")}"
        #expect(script.contains("db.people.insertMany([\n\(expected)\n]);"))
    }
}
