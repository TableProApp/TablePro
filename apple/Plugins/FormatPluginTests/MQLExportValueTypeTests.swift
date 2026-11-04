//
//  MQLExportValueTypeTests.swift
//  FormatPluginTests
//

import Foundation
import JavaScriptCore
import TableProPluginKit
import Testing

struct MQLExportValueTypeTests {
    private final class CollectionDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "MongoDB"
        let header: PluginStreamHeader
        let rows: [[PluginCellValue]]
        let documents: [PluginExportDocument]?
        let ddl: String

        init(header: PluginStreamHeader, rows: [[PluginCellValue]], documents: [PluginExportDocument]?, ddl: String = "") {
            self.header = header
            self.rows = rows
            self.documents = documents
            self.ddl = ddl
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

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { ddl }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { identifier }

        func escapeStringLiteral(_ value: String) -> String { value }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"

    private func exportedScript(
        header: PluginStreamHeader, rows: [[PluginCellValue]], documents: [PluginExportDocument]?,
        optionValues: [Bool] = [false, false, true], ddl: String = ""
    ) async throws -> String {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: destination) }
        let table = PluginExportTable(
            name: "people",
            databaseName: "",
            tableType: "table",
            optionValues: optionValues,
            schema: nil,
            kind: .table
        )
        let plugin = MQLExportPlugin()
        let originalOptions = plugin.settings
        defer { plugin.settings = originalOptions }
        plugin.settings.batchSize = 500
        _ = try await plugin.export(
            tables: [table],
            dataSource: CollectionDataSource(header: header, rows: rows, documents: documents, ddl: ddl),
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
    @Test("The exporter sends large document batches in byte-bounded commands without losing rows")
    func exportUsesDocumentByteBounds() async throws {
        let documents = (0..<500).map { index in
            PluginExportDocument(
                fields: [PluginExportField(
                    name: "value", canonicalJSON: "\"row_\(index)\"", typeName: "VARCHAR", cellValue: .text("row_\(index)")
                )],
                bsonSizeUpperBound: 100 * 1_024
            )
        }
        let script = try await exportedScript(
            header: PluginStreamHeader(columns: ["value"], columnTypeNames: ["VARCHAR"]),
            rows: documents.map { [$0.fields[0].cellValue] }, documents: documents
        )
        #expect(script.components(separatedBy: "const result = db.runCommand({insert:").count - 1 == 4)
        for index in 0..<500 {
            #expect(script.components(separatedBy: "[\"value\", \"row_\(index)\"]").count - 1 == 1)
        }
    }

    @Test("An empty collection is recreated with the default export options")
    func emptyCollectionIsCreated() async throws {
        let script = try await exportedScript(
            header: PluginStreamHeader(columns: [], columnTypeNames: []), rows: [], documents: nil,
            optionValues: [true, true, true]
        )
        #expect(script.contains("db.people.drop();"))
        #expect(script.contains("db.runCommand({create: \"people\"})"))
        #expect(!script.contains("documents:"))
    }

    @Test("An empty collection exists before its validator is restored without secondary indexes")
    func emptyValidatorCollectionIsCreatedFirst() async throws {
        let script = try await exportedScript(
            header: PluginStreamHeader(columns: [], columnTypeNames: []), rows: [], documents: [],
            optionValues: [true, true, false],
            ddl: "// Collection: people\n" + #"db.runCommand({"collMod":"people","validator":{"value":{"$type":"string"}}})"#
        )
        let context = try #require(JSContext())
        context.evaluateScript("""
        var exists = true;
        var operations = [];
        var EJSON = {stringify: JSON.stringify};
        var db = {
          people: {drop: function() {exists = false; operations.push("drop");}},
          runCommand: function(command) {
            if (command.create) {exists = true; operations.push("create"); return {ok:1};}
            operations.push("validator");
            return exists ? {ok:1} : {ok:0,code:26};
          }
        };
        """)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(operations)")?.toString() == #"["drop","create","validator"]"#)
    }

    @Test("Drop-only exports do not recreate the collection")
    func dropOnlyStaysDropOnly() async throws {
        let script = try await exportedScript(
            header: PluginStreamHeader(columns: [], columnTypeNames: []), rows: [], documents: nil,
            optionValues: [true, false, false]
        )
        #expect(script.contains("db.people.drop();"))
        #expect(!script.contains("runCommand"))
    }

}
