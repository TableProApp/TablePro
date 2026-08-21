//
//  JSONImportSkipTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private final class CountingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String? = "people"

    private(set) var insertedRows = 0

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { insertedRows += 1 }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws { insertedRows += rows.count }
    func deleteAllRowsFromTargetTable() async throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

private final class FileSource: PluginImportSource, @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fileURL() -> URL { url }
    func fileSizeBytes() -> Int64 { 0 }
}

/// Skip and Continue exists so one bad row does not cost the user the whole import. A line the
/// parser cannot read is exactly that case, and it used to throw straight out of the batch
/// closure, past the runner's error handling, aborting everything.
///
/// Serialized because `JSONImportPlugin.settings` persists through plugin storage, so two
/// instances in flight at once read each other's error-handling mode.
@Suite("JSON import skips unreadable lines", .serialized)
struct JSONImportSkipTests {
    private func writeNDJSON(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-import-\(UUID().uuidString).ndjson")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runImport(
        _ lines: [String],
        errorHandling: ImportErrorHandling
    ) async throws -> Result<PluginImportResult, any Error> {
        let url = try writeNDJSON(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        /// `settings` persists through plugin storage, so a test that writes it changes the
        /// developer's own preference unless it puts the value back.
        let plugin = JSONImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = true
        plugin.settings.deleteExistingRows = false

        do {
            let result = try await plugin.performImport(
                source: FileSource(url: url),
                sink: CountingSink(),
                progress: PluginImportProgress(progress: Progress())
            )
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    @Test("A line the parser cannot read is recorded and the rest still imports")
    func unreadableLineIsSkipped() async throws {
        let outcome = try await runImport(
            [
                #"{"name": "Ada"}"#,
                "{ this is not json",
                #"{"name": "Grace"}"#,
            ],
            errorHandling: .skipAndContinue
        )
        guard case .success(let result) = outcome else {
            Issue.record("Skip and Continue must not abort the import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 1)
        #expect(result.errors.contains { $0.line == 2 })
    }

    @Test("A stop mode still fails on a line the parser cannot read")
    func unreadableLineStopsAStopMode() async throws {
        let outcome = try await runImport(
            [
                #"{"name": "Ada"}"#,
                "{ this is not json",
            ],
            errorHandling: .stopAndRollback
        )
        guard case .failure = outcome else {
            Issue.record("Stop and Rollback must not silently skip an unreadable line")
            return
        }
    }

    /// An empty object carries nothing to import. Refusing it would turn a file a user can
    /// reasonably produce into a failed import.
    @Test("An empty object is passed over rather than failing the import")
    func emptyObjectIsPassedOver() async throws {
        let outcome = try await runImport(
            [
                #"{"name": "Ada"}"#,
                "{}",
                #"{"name": "Grace"}"#,
            ],
            errorHandling: .stopAndRollback
        )
        guard case .success(let result) = outcome else {
            Issue.record("An empty object must not fail the import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
    }

    /// The recorded list is capped so a broken file cannot hold the alert open forever, but the
    /// count must not be capped with it: a truncated list that also under-reports the damage tells
    /// the user far less was left out than really was.
    @Test("Every unreadable line is counted even once the recorded list is full")
    func skipCountOutlivesTheRecordedList() async throws {
        let bad = Array(repeating: "{ this is not json", count: 1_100)
        let outcome = try await runImport([#"{"name": "Ada"}"#] + bad, errorHandling: .skipAndContinue)
        guard case .success(let result) = outcome else {
            Issue.record("Skip and Continue must not abort the import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 1)
        #expect(result.skippedStatements == 1_100)
        #expect(result.errors.count <= 1_000)
    }

    @Test("A file the parser reads end to end reports no skips")
    func cleanFileHasNoSkips() async throws {
        let outcome = try await runImport(
            [
                #"{"name": "Ada"}"#,
                #"{"name": "Grace"}"#,
            ],
            errorHandling: .skipAndContinue
        )
        guard case .success(let result) = outcome else {
            Issue.record("A clean file must import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 0)
        #expect(result.errors.isEmpty)
    }
}
