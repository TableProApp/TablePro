//
//  JSONExportBooleanTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct JSONExportBooleanTests {
    private final class Source: PluginExportDataSource, @unchecked Sendable {
        struct NoSession: Error {}

        let databaseTypeId = "PostgreSQL"

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(
                    columns: ["flag", "nullable_flag", "label", "untyped", "choice"],
                    columnTypeNames: ["bool", "Nullable(Bool)", "text", "", "Enum8('true' = 1, 'bool' = 2)"]
                )))
                continuation.yield(.rows([[.text("true"), .text("FALSE"), .text("true"), .text("false"), .text("true")]]))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }
        func execute(query: String) async throws -> PluginQueryResult { throw NoSession() }
        func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
        func escapeStringLiteral(_ value: String) -> String { value }
        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { 1 }
    }

    @Test("Only a boolean column writes true and false as JSON booleans; the same text elsewhere stays a string")
    func booleansFollowTheColumn() async throws {
        let plugin = JSONExportPlugin()
        let stored = plugin.settings
        plugin.settings = JSONExportOptions()
        defer { plugin.settings = stored }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try await plugin.export(
            tables: [PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)],
            dataSource: Source(),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )

        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.contains(
            #"{"flag": true, "nullable_flag": false, "label": "true", "untyped": "false", "choice": "true"}"#
        ))
    }
}
