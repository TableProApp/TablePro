//
//  SQLImportBatchTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private struct Refused: LocalizedError {
    var errorDescription: String? { "duplicate key value" }
}

private final class BatchingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    var events: [String] = []
    var failing: Set<String> = []

    func execute(statement: String) async throws {
        events.append(statement)
        if failing.contains(statement) { throw Refused() }
    }

    func batches(_ statement: String) -> Bool {
        !statement.hasPrefix("SET")
    }

    func execute(statements: [PluginImportStatement]) async throws {
        events.append("batch \(statements.count)")
        for (index, statement) in statements.enumerated() where failing.contains(statement.text) {
            throw PluginImportBatchFailure(index: index, underlying: Refused())
        }
    }

    func beginTransaction() async throws { events.append("begin") }
    func commitTransaction() async throws { events.append("commit") }
    func rollbackTransaction() async throws { events.append("rollback") }
}

private final class LineSource: PluginImportSource, @unchecked Sendable {
    private let lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let lines = self.lines
        return AsyncThrowingStream { continuation in
            for (index, line) in lines.enumerated() {
                continuation.yield((statement: line, lineNumber: index + 1))
            }
            continuation.finish()
        }
    }

    func fileURL() -> URL { URL(fileURLWithPath: "/dev/null") }

    func fileSizeBytes() -> Int64 { 0 }
}

@Suite(.serialized)
struct SQLImportBatchTests {
    private static func inserts(_ count: Int) -> [String] {
        (1...count).map { "INSERT INTO t VALUES (\($0))" }
    }

    private func runImport(
        _ statements: [String],
        errorHandling: ImportErrorHandling = .stopAndRollback,
        sink: BatchingSink
    ) async -> Result<PluginImportResult, any Error> {
        let plugin = SQLImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = true
        plugin.settings.disableForeignKeyChecks = false
        do {
            return .success(try await plugin.performImport(
                source: LineSource(statements),
                sink: sink,
                progress: PluginImportProgress(progress: Progress())
            ))
        } catch {
            return .failure(error)
        }
    }

    @Test("Statements inside the import's transaction go out in batches")
    func sendsBatches() async throws {
        let sink = BatchingSink()

        let result = try await runImport(Self.inserts(3), sink: sink).get()

        #expect(sink.events == ["begin", "batch 3", "commit"])
        #expect(result.executedStatements == 3)
    }

    @Test("A batch stops the import at its failed statement and names that statement's line")
    func failureNamesItsLine() async {
        let sink = BatchingSink()
        let statements = Self.inserts(3)
        sink.failing = [statements[1]]

        let outcome = await runImport(statements, sink: sink)

        guard case .failure(let error) = outcome,
              case .statementFailed(let statement, let line, _) = error as? PluginImportError else {
            Issue.record("The import should have stopped at the failed statement")
            return
        }
        #expect(statement == statements[1])
        #expect(line == 2)
        #expect(sink.events == ["begin", "batch 3", "rollback"])
    }

    @Test("Stop and commit commits what ran before a batched failure")
    func stopAndCommitCommits() async {
        let sink = BatchingSink()
        let statements = Self.inserts(3)
        sink.failing = [statements[2]]

        _ = await runImport(statements, errorHandling: .stopAndCommit, sink: sink)

        #expect(sink.events == ["begin", "batch 3", "commit"])
    }

    @Test("A statement the connection keeps alone first sends the batch waiting ahead of it")
    func loneStatementFlushesFirst() async throws {
        let sink = BatchingSink()
        let statements = [Self.inserts(1)[0], "SET search_path = app", "INSERT INTO t VALUES (9)"]

        _ = try await runImport(statements, sink: sink).get()

        #expect(sink.events == ["begin", "batch 1", "SET search_path = app", "batch 1", "commit"])
    }

    @Test("Skip and continue runs outside a transaction, so every statement goes alone")
    func skipModeNeverBatches() async throws {
        let sink = BatchingSink()
        let statements = Self.inserts(3)
        sink.failing = [statements[1]]

        let result = try await runImport(statements, errorHandling: .skipAndContinue, sink: sink).get()

        #expect(sink.events == statements)
        #expect(result.executedStatements == 2)
        #expect(result.skippedStatements == 1)
    }

    @Test("A batch never grows past its statement limit")
    func batchesAreBounded() async throws {
        let sink = BatchingSink()
        let limit = SQLImportBatch.statementLimit

        _ = try await runImport(Self.inserts(limit * 2 + 7), sink: sink).get()

        #expect(sink.events == ["begin", "batch \(limit)", "batch \(limit)", "batch 7", "commit"])
    }
}
