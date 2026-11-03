import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

private final class DocumentRowsSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "MongoDB"
    let elements: [PluginExportStreamElement]

    init(_ elements: [PluginExportStreamElement]) { self.elements = elements }

    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        streamExportRows(table: object.name, databaseName: object.databaseName)
    }

    func streamExportRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish()
        }
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginExportStreamElement.cells(streamExportRows(table: table, databaseName: databaseName))
    }

    func execute(query: String) async throws -> PluginQueryResult { .empty }
    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }
    func quoteIdentifier(_ identifier: String) -> String { identifier }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

private final class DocumentExportDriver: PluginDriverStub, @unchecked Sendable {
    let document: PluginExportDocument
    private let lock = NSLock()
    private var captured: [(String, Bool)] = []

    init(document: PluginExportDocument) { self.document = document }

    var calls: [(String, Bool)] { lock.withLock { captured } }

    func defaultExportQuery(table: String, schema: String?) -> String? { "db.records.find({})" }

    func streamExportRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        lock.withLock { captured.append((query, context.readOnly)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["value"], columnTypeNames: ["VARCHAR"])))
            continuation.yield(.rows([[.text("42")]], documents: [document]))
            continuation.finish()
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: ["value"], columnTypeNames: ["VARCHAR"], rows: [[.text("42")]],
            rowsAffected: 0, executionTime: 0
        )
        result.exportDocuments = [document]
        return result
    }
}

@MainActor
struct DocumentExportDataSourceTests {
    private func field(_ name: String, _ json: String, type: String = "VARCHAR", cell: PluginCellValue) -> PluginExportField {
        PluginExportField(name: name, canonicalJSON: json, typeName: type, cellValue: cell)
    }

    private func collect(_ source: any PluginExportDataSource) async throws -> [PluginExportDocument]? {
        var documents: [PluginExportDocument] = []
        let object = PluginExportTable(name: "records", databaseName: "", tableType: "table")
        for try await element in source.streamExportRows(for: object) {
            if case .rows(_, let batch) = element {
                guard let batch else { return nil }
                documents += batch
            }
        }
        return documents
    }

    @Test func tableAndQueryAdaptersKeepDriverDocuments() async throws {
        let document = PluginExportDocument(fields: [field("value", #"{"$numberInt":"42"}"#, type: "INTEGER", cell: .text("42"))])
        let plugin = DocumentExportDriver(document: document)
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mongodb), pluginDriver: plugin)
        let table = ExportDataSourceAdapter(driver: driver, databaseType: .mongodb)
        #expect(try await collect(table) == [document])
        #expect(plugin.calls.first?.1 == true)
        let query = StreamingQueryExportDataSource(query: "db.records.find({})", driver: driver, databaseType: .mongodb)
        #expect(try await collect(query) == [document])
        let result = try await driver.execute(query: "db.records.find({})")
        #expect(result.exportDocuments == [document])
    }

    @Test func columnMasksCoverMinorityTypesAndLateFields() async throws {
        let document = PluginExportDocument(fields: [
            field("value", #"{"$numberInt":"42"}"#, type: "INTEGER", cell: .text("42")),
            field("late", #""private""#, cell: .text("private")),
            field("kept", #"{"$numberLong":"7"}"#, type: "BIGINT", cell: .text("7"))
        ])
        let base = DocumentRowsSource([
            .header(PluginStreamHeader(columns: ["value"], columnTypeNames: ["VARCHAR"])),
            .rows([[.text("42")]], documents: [document])
        ])
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "VARCHAR", target: .type),
            MaskingRule(pattern: "late", style: .null)
        ])
        let source = MaskingExportDataSource.wrapping(base, policy: policy)
        let result = try #require(try await collect(source)?.first)
        #expect(result.fields[0].canonicalJSON == #""••••""#)
        #expect(result.fields[1].canonicalJSON == #""••••""#)
        #expect(result.fields[2] == document.fields[2])
    }

    @Test func queryRulesUseUnknownTableAndFirstMatch() async throws {
        let document = PluginExportDocument(fields: [field("email", #""jane@example.com""#, cell: .text("jane@example.com"))])
        let base = DocumentRowsSource([
            .header(PluginStreamHeader(columns: [], columnTypeNames: [])),
            .rows([[]], documents: [document])
        ])
        let policy = MaskingPolicy(rules: [
            MaskingRule(pattern: "users.email", style: .null),
            MaskingRule(pattern: "*", style: .lastFour)
        ])
        let source = MaskingExportDataSource.wrapping(base, policy: policy, streamsTables: false)
        let documents = try await collect(source)
        #expect(documents?.first?.fields.first?.canonicalJSON == "null")
    }

    @Test func documentRowsNeedHeaderAndMatchingCount() async {
        let batches: [[PluginExportStreamElement]] = [
            [.rows([[]], documents: [])],
            [.header(PluginStreamHeader(columns: [], columnTypeNames: [])), .rows([[]], documents: [])]
        ]
        for elements in batches {
            let source = MaskingExportDataSource.wrapping(
                DocumentRowsSource(elements), policy: MaskingPolicy(rules: [MaskingRule(pattern: "*")])
            )
            await #expect(throws: (any Error).self) { _ = try await collect(source) }
        }
    }

    @Test func selectionKeepsDocumentIdentityAcrossReorderAndPages() async throws {
        let first = PluginExportDocument(fields: [field("value", #""first""#, cell: .text("first"))])
        let second = PluginExportDocument(fields: [field("value", #"{"$numberInt":"2"}"#, type: "INTEGER", cell: .text("2"))])
        var rows = TableRows.from(
            queryRows: [[.text("first")]], columns: ["value"], columnTypes: [.text(rawType: "VARCHAR")],
            exportDocuments: [first]
        )
        rows.appendPage([[.text("2")]], startingAt: 1, exportDocuments: [second])
        rows.reorderRows(ContiguousArray(rows.rows.reversed()))
        let source = QueryResultExportDataSource(detachedRows: rows, rowIndices: [0], databaseTypeId: "MongoDB")
        #expect(try await collect(source) == [second])
        rows.remove(rowIDs: [.existing(0)])
        #expect(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")) == [second])
    }

    @Test func gridMaskChangeRedactsSnapshotAndBaseline() async throws {
        let document = PluginExportDocument(fields: [field("value", #""secret""#, cell: .text("secret"))])
        var rows = TableRows.from(
            queryRows: [[.text("secret")]], columns: ["value"], columnTypes: [.text(rawType: "VARCHAR")],
            exportDocuments: [document]
        )
        rows.addMasks(ColumnMasks(styles: [0: .null]))
        let source = QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")
        let documents = try await collect(source)
        #expect(documents?.first?.fields.first?.canonicalJSON == "null")
        #expect(rows.rows[0].exportSnapshot?.values == [.null])
        #expect(rows.rows[0].exportSnapshot?.document.canonicalJSON.contains("secret") == false)
    }

    @Test func documentColumnMasksUseGridCellsAndDoNotMaskTwice() async throws {
        let document = PluginExportDocument(fields: [
            field("value", #"{"$binary":{"base64":"YWJjZA==","subType":"04"}}"#, type: "UUID", cell: .text("UUID(abcd)"))
        ])
        for style in [MaskingStyle.lastFour, .hash] {
            var rows = TableRows.from(
                queryRows: [[.bytes(Data("abcd".utf8))]], columns: ["value"], columnTypes: [.text(rawType: "BLOB")],
                exportDocuments: [document], masks: ColumnMasks(styles: [0: style])
            )
            let first = try #require(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB"))?.first)
            #expect(first.fields[0].cellValue == rows.rows[0].values[0])
            rows.addMasks(ColumnMasks(styles: [0: .full]), policy: MaskingPolicy(rules: [MaskingRule(pattern: "*")]))
            let again = try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB"))
            #expect(again == [first])
        }
    }

    @Test func gridPolicyMasksActualTypeAndSurvivesReplacement() async throws {
        let document = PluginExportDocument(fields: [
            field("value", #"{"$numberInt":"42"}"#, type: "INTEGER", cell: .text("42"))
        ])
        let policy = MaskingPolicy(rules: [MaskingRule(pattern: "INTEGER", target: .type)])
        var rows = TableRows.from(
            queryRows: [[.text("42")]], columns: ["value"], columnTypes: [.text(rawType: "VARCHAR")],
            exportDocuments: [document], exportPolicy: policy
        )
        rows.replace(rows: [[.text("42")]], exportDocuments: [document])
        let documents = try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB"))
        #expect(documents?.first?.fields.first?.canonicalJSON == #""••••""#)
    }

    @Test func editsAndAbsentChangesRequireSavedDocumentsButUndoRestoresThem() async throws {
        let document = PluginExportDocument(fields: [field("value", "null", cell: .null)])
        var rows = TableRows.from(
            queryRows: [[.null]], columns: ["value"], columnTypes: [.text(rawType: "VARCHAR")], exportDocuments: [document]
        )
        rows.edit(row: 0, column: 0, value: .text("new"))
        #expect(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")) == nil)
        rows.edit(row: 0, column: 0, value: .null)
        #expect(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")) == [document])
        rows.edit(row: 0, column: 0, value: .null, isAbsent: true)
        #expect(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")) == nil)
        rows.edit(row: 0, column: 0, value: .null)
        rows.appendInsertedRow(values: [.text("new")])
        #expect(try await collect(QueryResultExportDataSource(detachedRows: rows, databaseTypeId: "MongoDB")) == nil)
    }
}
