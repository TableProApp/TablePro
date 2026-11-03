import Foundation
import TableProPluginKit
import Testing

@Suite("Document export values")
struct PluginExportDocumentTests {
    @Test("Stored fields keep order, nulls, and their own types")
    func orderedFields() throws {
        let document = PluginExportDocument(fields: [
            PluginExportField(name: "10", canonicalJSON: #"{"$numberLong":"42"}"#, typeName: "BIGINT", cellValue: "42"),
            PluginExportField(name: "2", canonicalJSON: "null", typeName: "VARCHAR", cellValue: .null),
            PluginExportField(name: "__proto__", canonicalJSON: #""true""#, typeName: "VARCHAR", cellValue: "true")
        ])
        #expect(document.canonicalJSON == #"{"10":{"$numberLong":"42"},"2":null,"__proto__":"true"}"#)
        let restored = try JSONDecoder().decode(PluginExportDocument.self, from: JSONEncoder().encode(document))
        #expect(restored == document)
    }

    @Test("BSON sizing metadata survives coding and remains optional for earlier payloads")
    func bsonSizeCoding() throws {
        let document = PluginExportDocument(fields: [], bsonSizeUpperBound: 5)
        let encoded = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(PluginExportDocument.self, from: encoded)
        #expect(restored.bsonSizeUpperBound == 5)
        #expect(restored.canonicalJSON == "{}")
        let old = try JSONDecoder().decode(PluginExportDocument.self, from: Data(#"{"fields":[]}"#.utf8))
        #expect(old.bsonSizeUpperBound == nil)
        #expect(PluginExportDocument(fields: []).bsonSizeUpperBound == nil)
    }

    @Test("Names encode as JSON strings")
    func escapedNames() throws {
        let name = "quote\" slash\\ newline\n nul\0 emoji😀"
        let encoded = PluginExportDocument.jsonString(name)
        #expect(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)) == name)
    }

    @Test("Result coding preserves documents and reads old results")
    func resultCoding() throws {
        var result = PluginQueryResult(columns: ["v"], columnTypeNames: ["VARCHAR"], rows: [["42"]], rowsAffected: 0, executionTime: 0)
        result.exportDocuments = [PluginExportDocument(fields: [
            PluginExportField(name: "v", canonicalJSON: #"{"$numberInt":"42"}"#, typeName: "INTEGER", cellValue: "42")
        ])]
        let encoded = try JSONEncoder().encode(result)
        let restored = try JSONDecoder().decode(PluginQueryResult.self, from: encoded)
        #expect(restored.exportDocuments == result.exportDocuments)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "exportDocuments")
        let old = try JSONDecoder().decode(PluginQueryResult.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.exportDocuments == nil)
    }

    @Test("Legacy stream adapts without claiming document types")
    func legacyStream() async throws {
        let old = AsyncThrowingStream<PluginStreamElement, Error> { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["v"], columnTypeNames: ["VARCHAR"])))
            continuation.yield(.rows([["42"], [.null]]))
            continuation.finish()
        }
        var count = 0
        for try await element in PluginExportStreamElement.wrapping(old) {
            switch element {
            case .header(let header): #expect(header.columns == ["v"])
            case .rows(let rows, let documents):
                #expect(rows == [["42"], [.null]])
                #expect(documents == nil)
                count += rows.count
            @unknown default: Issue.record("Unexpected stream element")
            }
        }
        #expect(count == 2)
    }

    @Test("Cell consumers retain every row from document streams")
    func cellStream() async throws {
        let stream = AsyncThrowingStream<PluginExportStreamElement, Error> { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["v", "absent"], columnTypeNames: ["VARCHAR", "VARCHAR"])))
            let document = PluginExportDocument(fields: [
                PluginExportField(name: "v", canonicalJSON: #""42""#, typeName: "VARCHAR", cellValue: "42")
            ])
            continuation.yield(.rows([["42", .null]], documents: [document]))
            continuation.finish()
        }
        var rows: [PluginRow] = []
        for try await element in PluginExportStreamElement.cells(stream) {
            if case .rows(let batch) = element { rows += batch }
        }
        #expect(rows == [["42", .null]])
    }

    @Test("A late document field refuses a fixed-column export")
    func lateFieldRefused() async {
        await expectCellStreamRefusal(columns: ["sampled"], fieldNames: ["sampled", "late"], rowCount: 1)
    }

    @Test("Document rows require a header before reaching cell consumers")
    func missingHeaderRefused() async {
        await expectCellStreamRefusal(columns: nil, fieldNames: ["v"], rowCount: 1)
    }

    @Test("Document counts must match the cell rows")
    func misalignedDocumentsRefused() async {
        await expectCellStreamRefusal(columns: ["v"], fieldNames: ["v"], rowCount: 2)
    }

    @Test("A short cell row cannot discard a declared document field")
    func shortRowRefused() async {
        await expectCellStreamRefusal(columns: ["a", "b"], fieldNames: ["a", "b"], rowCount: 1)
    }

    @Test("A canonically equivalent name cannot stand in for another stored field")
    func distinctUnicodeFieldRefused() async {
        await expectCellStreamRefusal(columns: ["\u{00E9}"], fieldNames: ["e\u{0301}"], rowCount: 1)
    }

    private func expectCellStreamRefusal(columns: [String]?, fieldNames: [String], rowCount: Int) async {
        let stream = AsyncThrowingStream<PluginExportStreamElement, Error> { continuation in
            if let columns {
                continuation.yield(.header(PluginStreamHeader(columns: columns, columnTypeNames: [])))
            }
            let document = PluginExportDocument(fields: fieldNames.map {
                PluginExportField(name: $0, canonicalJSON: #""private value""#, typeName: "VARCHAR", cellValue: "private value")
            })
            continuation.yield(.rows(Array(repeating: ["private value"], count: rowCount), documents: [document]))
            continuation.finish()
        }
        do {
            for try await element in PluginExportStreamElement.cells(stream) {
                if case .rows = element { Issue.record("Rows with incomplete columns reached the cell consumer") }
            }
            Issue.record("The incomplete export was accepted")
        } catch let error as PluginExportError {
            #expect(!error.localizedDescription.contains("private value"))
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("Default export source keeps its scoped legacy read")
    func defaultSource() async throws {
        let source = LegacyExportSource()
        let table = PluginExportTable(name: "items", databaseName: "db")
        var values: [PluginRow] = []
        for try await element in source.streamExportRows(for: table) {
            if case .rows(let rows, let documents) = element {
                values += rows
                #expect(documents == nil)
            }
        }
        #expect(values == [["scoped"]])
    }

    @Test("A legacy driver receives the export statement context")
    func defaultDriver() async throws {
        let driver: any PluginDatabaseDriver = LegacyExportDriver()
        var context = PluginStatementContext()
        context.readOnly = true
        context.allowsServerCode = false
        var values: [PluginRow] = []
        for try await element in driver.streamExportRows(query: "read", context: context) {
            if case .rows(let rows, let documents) = element {
                values += rows
                #expect(documents == nil)
            }
        }
        #expect(values == [["true", "false"]])
    }

    @Test("Cancelling the adapted stream ends its producer", .timeLimit(.minutes(1)))
    func cancellation() async {
        let (terminated, termination) = AsyncStream<Void>.makeStream()
        let (started, start) = AsyncStream<Void>.makeStream()
        let source = AsyncThrowingStream<PluginStreamElement, Error> { continuation in
            continuation.onTermination = { _ in termination.yield(); termination.finish() }
            continuation.yield(.rows([["first"]]))
        }
        let consumer = Task {
            do {
                for try await _ in PluginExportStreamElement.wrapping(source) {
                    start.yield()
                    start.finish()
                }
            } catch {}
        }
        for await _ in started { break }
        consumer.cancel()
        for await _ in terminated { break }
        await consumer.value
    }
}

private final class LegacyExportSource: PluginExportDataSource, Sendable {
    let databaseTypeId = "test"
    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { $0.yield(.rows([["plain"]])); $0.finish() }
    }
    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { $0.yield(.rows([["scoped"]])); $0.finish() }
    }
    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }
    func execute(query: String) async throws -> PluginQueryResult { .empty }
    func quoteIdentifier(_ identifier: String) -> String { identifier }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

private final class LegacyExportDriver: PluginDatabaseDriver, Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil
    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult { .empty }
    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream {
            $0.yield(.rows([[.text(String(context.readOnly)), .text(String(context.allowsServerCode))]]))
            $0.finish()
        }
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}
