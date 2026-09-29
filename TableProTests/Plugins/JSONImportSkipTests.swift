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

    private(set) var rows: [[String: PluginCellValue]] = []

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { rows.append(values) }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws { self.rows.append(contentsOf: rows) }
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
    private func writeNDJSON(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-import-\(UUID().uuidString).ndjson")
        try contents.write(to: url)
        return url
    }

    private func runImport(
        _ lines: [String],
        errorHandling: ImportErrorHandling,
        sink: CountingSink = CountingSink(),
        progress: Progress = Progress()
    ) async throws -> Result<PluginImportResult, any Error> {
        try await runImport(
            contents: Data(lines.joined(separator: "\n").utf8),
            errorHandling: errorHandling,
            sink: sink,
            progress: progress
        )
    }

    private func runImport(
        contents: Data,
        errorHandling: ImportErrorHandling,
        sink: CountingSink = CountingSink(),
        progress: Progress = Progress()
    ) async throws -> Result<PluginImportResult, any Error> {
        let url = try writeNDJSON(contents)
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
                sink: sink,
                progress: PluginImportProgress(progress: progress)
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

    /// JSON allows U+2028, U+2029 and U+0085 unescaped inside a string. Reading the file with
    /// `URL.lines` ended a line at each of them and failed both halves.
    @Test("A string holding a Unicode line separator imports as one row")
    func unicodeSeparatorInsideAStringImportsWhole() async throws {
        let sink = CountingSink()
        let outcome = try await runImport(
            ["{\"note\":\"a\u{2028}b\u{2029}c\u{0085}d\"}", #"{"note": "e"}"#],
            errorHandling: .skipAndContinue,
            sink: sink
        )
        guard case .success(let result) = outcome else {
            Issue.record("A valid file must import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 0)
        let first = try #require(sink.rows.first)
        #expect(first["note"] == .text("a\u{2028}b\u{2029}c\u{0085}d"))
    }

    @Test("Lines ending in CRLF import every row")
    func crlfLinesImport() async throws {
        let outcome = try await runImport(
            contents: Data("{\"a\":1}\r\n\r\n{\"a\":2}\r\n".utf8),
            errorHandling: .stopAndRollback
        )
        guard case .success(let result) = outcome else {
            Issue.record("A CRLF file must import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
    }

    /// The same bytes in a `.json` file fail the whole parse. A JSON Lines file used to have the
    /// bad byte swapped for U+FFFD and imported as if nothing were wrong.
    @Test("A line that is not UTF-8 is reported rather than imported with replacement characters")
    func invalidUTF8LineIsReported() async throws {
        var contents = Data("{\"name\": \"Ada\"}\n{\"name\": \"".utf8)
        contents.append(0xFF)
        contents.append(Data("\"}\n{\"name\": \"Grace\"}".utf8))
        let sink = CountingSink()
        let outcome = try await runImport(contents: contents, errorHandling: .skipAndContinue, sink: sink)
        guard case .success(let result) = outcome else {
            Issue.record("Skip and Continue must not abort the import: \(outcome)")
            return
        }
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 1)
        #expect(result.errors.contains { $0.line == 2 })
        #expect(sink.rows.compactMap { $0["name"] } == [.text("Ada"), .text("Grace")])
    }

    /// `URL.lines` reads through `FileHandle.AsyncBytes`, which Foundation serves from one queue for
    /// the whole process. A reader parked on a quiet pipe, as the Copilot language server's is,
    /// held that queue and the import waited behind it.
    @Test("An import finishes while another reader in the process waits on a quiet pipe")
    func importIgnoresABlockedAsyncBytesReader() async throws {
        let pipe = Pipe()
        let blocker = Task {
            for try await _ in pipe.fileHandleForReading.bytes {}
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let outcome = try? await self.runImport(
                    [#"{"name": "Ada"}"#, #"{"name": "Grace"}"#],
                    errorHandling: .stopAndRollback
                )
                guard case .success(let result) = outcome else { return false }
                return result.executedStatements == 2
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            try? pipe.fileHandleForWriting.close()
            group.cancelAll()
            return first
        }
        blocker.cancel()

        #expect(finished)
    }

    /// The runner checks for a stop between batches, and a batch used to end only once it held 500
    /// rows. A long run of lines with no row in them was read to the end of the file first.
    @Test("A stopped import stops within a batch of lines even when no line holds a row")
    func stopReachesARunOfUnreadableLines() async throws {
        let progress = Progress()
        progress.cancel()
        let outcome = try await runImport(
            Array(repeating: "{ this is not json", count: 5_000),
            errorHandling: .skipAndContinue,
            progress: progress
        )
        guard case .failure(let error) = outcome else {
            Issue.record("A stopped import must not run to the end of the file: \(outcome)")
            return
        }
        #expect(error is PluginImportCancellationError)
    }
}
