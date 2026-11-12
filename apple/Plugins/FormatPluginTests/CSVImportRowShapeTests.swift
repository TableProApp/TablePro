//
//  CSVImportRowShapeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private final class RowRecordingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String? = "people"

    private(set) var rows: [[String: PluginCellValue]] = []
    private(set) var rolledBack = false
    private(set) var committed = false

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { rows.append(values) }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws { self.rows.append(contentsOf: rows) }
    func deleteAllRowsFromTargetTable() async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws { committed = true }
    func rollbackTransaction() async throws { rolledBack = true }
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

private final class CSVFileSource: PluginImportSource, @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fileURL() -> URL { url }
    func fileSizeBytes() -> Int64 { 0 }
}

@Suite("CSV import reports a row with more fields than columns", .serialized)
struct CSVImportRowShapeTests {
    private func runImport(
        _ text: String,
        errorHandling: ImportErrorHandling
    ) async throws -> (Result<PluginImportResult, any Error>, RowRecordingSink) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-shape-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let plugin = CSVImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        var options = CSVImportOptions()
        options.errorHandling = errorHandling
        plugin.settings = options

        let sink = RowRecordingSink()
        do {
            let result = try await plugin.performImport(
                source: CSVFileSource(url: url),
                sink: sink,
                progress: PluginImportProgress(progress: Progress())
            )
            return (.success(result), sink)
        } catch {
            return (.failure(error), sink)
        }
    }

    private static let unquotedComma = "id,name,city\n1,Ada,Paris\n2,Smith, John,NY\n3,Lin,Hanoi\n"

    @Test("A row with an extra field stops the import and names its line")
    func extraFieldStopsTheImport() async throws {
        let (outcome, sink) = try await runImport(Self.unquotedComma, errorHandling: .stopAndRollback)
        guard case .failure(let error) = outcome else {
            Issue.record("The import went ahead over a row it had to cut")
            return
        }
        #expect(error.localizedDescription.contains("line 3"))
        #expect(error.localizedDescription.contains("4 fields"))
        #expect(sink.rolledBack)
        #expect(!sink.rows.contains { $0["id"] == .text("2") })
        #expect(!sink.rows.contains { $0["id"] == .text("3") })
    }

    @Test("Stop and commit keeps the rows above the malformed one")
    func stopAndCommitKeepsEarlierRows() async throws {
        let (outcome, sink) = try await runImport(Self.unquotedComma, errorHandling: .stopAndCommit)
        guard case .failure = outcome else {
            Issue.record("The import went ahead over a row it had to cut")
            return
        }
        #expect(sink.committed)
        #expect(sink.rows.map { $0["id"] } == [.text("1")])
    }

    @Test("Skip and continue leaves the row out and reports it")
    func skipModeRecordsTheRow() async throws {
        let (outcome, sink) = try await runImport(Self.unquotedComma, errorHandling: .skipAndContinue)
        let result = try outcome.get()
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 1)
        #expect(result.errors.map { $0.line } == [3])
        #expect(sink.rows.map { $0["id"] } == [.text("1"), .text("3")])
    }

    @Test("A record of empty fields, how export writes an all-NULL row, imports as one; an empty line does not")
    func emptyFieldsAreARow() async throws {
        let (outcome, sink) = try await runImport(
            "id,name,city\n1,Ada,Paris\n,,\n\n3,Lin,Hanoi\n", errorHandling: .stopAndRollback)
        let result = try outcome.get()
        #expect(result.executedStatements == 3)
        #expect(sink.rows.map { $0["id"] } == [.text("1"), .null, .text("3")])
        #expect(sink.rows[1] == ["id": .null, "name": .null, "city": .null])
    }

    @Test("The empty rows a spreadsheet saves under its data, and a trailing empty line, are not rows")
    func trailingEmptyRecordsAreNotRows() async throws {
        let (outcome, sink) = try await runImport("id,name\n1,Ada\n,\n,\n", errorHandling: .stopAndRollback)
        #expect(try outcome.get().executedStatements == 1)
        #expect(sink.rows.map { $0["id"] } == [.text("1")])

        let (oneColumn, oneColumnSink) = try await runImport("email\na@x.io\nb@x.io\n\n", errorHandling: .stopAndRollback)
        _ = try oneColumn.get()
        #expect(oneColumnSink.rows.map { $0["email"] } == [.text("a@x.io"), .text("b@x.io")])
    }

    @Test("In a one-column file an empty line is a NULL, as export writes one")
    func emptyLineInOneColumnIsARow() async throws {
        let (outcome, sink) = try await runImport("name\nAda\n\nLin\n", errorHandling: .stopAndRollback)
        _ = try outcome.get()
        #expect(sink.rows.map { $0["name"] } == [.text("Ada"), .null, .text("Lin")])
    }

    @Test("A row that lacks trailing fields imports with them NULL")
    func shortRowIsPadded() async throws {
        let (outcome, sink) = try await runImport(
            "id,name,city\n1,Ada,Paris\n2,Smith\n", errorHandling: .stopAndRollback)
        let result = try outcome.get()
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 0)
        #expect(result.errors.isEmpty)
        #expect(sink.rows.count == 2)
        #expect(sink.rows.last?["name"] == .text("Smith"))
        #expect(sink.rows.last?["city"] == .null)
    }

    @Test("Trailing delimiters and blank lines are not errors")
    func trailingDelimitersImport() async throws {
        let (outcome, sink) = try await runImport(
            "id,name\n1,Ada,,\n\n2,Lin\n", errorHandling: .stopAndRollback)
        let result = try outcome.get()
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 0)
        #expect(sink.rows.count == 2)
    }

    @Test("Only a surplus field that holds something is an error")
    func shapeCheck() {
        let options = CSVImportOptions()
        var trimming = CSVImportOptions()
        trimming.trimWhitespace = true
        #expect(CSVImportParsing.shapeError(fields: ["1", "a"], columnCount: 2, options: options) == nil)
        #expect(CSVImportParsing.shapeError(fields: ["1", "a", ""], columnCount: 2, options: options) == nil)
        #expect(CSVImportParsing.shapeError(fields: ["1"], columnCount: 2, options: options) == nil)
        #expect(CSVImportParsing.shapeError(fields: ["1", "a", "x"], columnCount: 2, options: options)
            == CSVImportParsing.RowShapeError(fieldCount: 3, columnCount: 2))
        #expect(CSVImportParsing.shapeError(fields: ["1", "a", " "], columnCount: 2, options: options)
            == CSVImportParsing.RowShapeError(fieldCount: 3, columnCount: 2))
        #expect(CSVImportParsing.shapeError(fields: ["1", "a", " ", ""], columnCount: 2, options: trimming) == nil)
        #expect(CSVImportParsing.shapeError(fields: ["1", "a", " x "], columnCount: 2, options: trimming)
            == CSVImportParsing.RowShapeError(fieldCount: 3, columnCount: 2))
    }
}
