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
        let documents: [PluginExportDocument]?

        init(header: PluginStreamHeader, rows: [[PluginCellValue]], documents: [PluginExportDocument]?) {
            self.header = header
            self.rows = rows
            self.documents = documents
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

        func streamExportRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(header))
                continuation.yield(.rows(rows, documents: documents))
                continuation.finish()
            }
        }

        func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
            streamExportRows(table: object.name, databaseName: object.databaseName)
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

    private func exportedScript(header: PluginStreamHeader, rows: [[PluginCellValue]], documents: [PluginExportDocument]?) async throws -> String {
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
            dataSource: CollectionDataSource(header: header, rows: rows, documents: documents),
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return try String(contentsOf: destination, encoding: .utf8)
    }

    private func document(_ json: String) -> PluginExportDocument {
        PluginExportDocument(fields: [PluginExportField(name: "value", canonicalJSON: json, typeName: "VARCHAR", cellValue: .text("display"))])
    }

    @Test("A mixed field exports every document's stored type instead of its sampled column type")
    func mixedFieldKeepsTypes() async throws {
        let header = PluginStreamHeader(columns: ["value"], columnTypeNames: ["VARCHAR"])
        let script = try await exportedScript(
            header: header, rows: [[.text("42")], [.text("42")], [.null]],
            documents: [document(#""42""#), document(#"{"$numberInt":"42"}"#), document("null")]
        )
        #expect(script.contains(#"new Map([["value", "42"]])"#))
        #expect(script.contains(#"new Map([["value", EJSON.parse("{\"$numberInt\":\"42\"}", {relaxed: false})]])"#))
        #expect(script.contains(#"new Map([["value", null]])"#))
        #expect(script.contains("db.runCommand({insert: \"people\""))
        #expect(script.contains("result.writeErrors"))
    }

    @Test("Cell-only results are refused rather than changing their BSON types")
    func refusesCellsWithoutDocuments() async {
        do {
            _ = try await exportedScript(
                header: PluginStreamHeader(columns: ["value"], columnTypeNames: ["VARCHAR"]),
                rows: [[.text("42")]], documents: nil
            )
            Issue.record("Expected a typed document error")
        } catch {
            #expect(error.localizedDescription.contains("typed documents"))
        }
    }
}
