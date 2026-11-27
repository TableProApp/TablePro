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

private struct Unreadable: LocalizedError {
    var errorDescription: String? { "The string that starts on line 3 is longer than the import reads." }
}

private struct RulesChanged: Error {}

private final class BatchingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    var events: [String] = []
    var failing: Set<String> = []
    var refusesBatches = false
    var changesReadingRules = false
    var stopsDuringBatch: Progress?

    func execute(statement: String) async throws {
        events.append(statement)
        if failing.contains(statement) { throw Refused() }
    }

    func batches(_ statement: String) -> Bool {
        statement.hasPrefix("INSERT") && !statement.contains("\\")
    }

    func execute(statements: [PluginImportStatement], readAhead: Bool) async throws {
        events.append("batch \(statements.count)\(readAhead ? " read ahead" : "")")
        if refusesBatches { throw Refused() }
        stopsDuringBatch?.cancel()
        for (index, statement) in statements.enumerated() where failing.contains(statement.text) {
            throw PluginImportBatchFailure(index: index, underlying: Refused())
        }
        if changesReadingRules, readAhead {
            throw PluginImportBatchFailure(index: statements.count, underlying: RulesChanged())
        }
    }

    func beginTransaction() async throws { events.append("begin") }
    func commitTransaction() async throws { events.append("commit") }
    func rollbackTransaction() async throws { events.append("rollback") }
}

private final class LineSource: PluginImportSource, @unchecked Sendable {
    private let lines: [String]
    private let failsAfterLines: Bool

    init(_ lines: [String], failsAfterLines: Bool = false) {
        self.lines = lines
        self.failsAfterLines = failsAfterLines
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let lines = self.lines
        let fails = failsAfterLines
        return AsyncThrowingStream { continuation in
            for (index, line) in lines.enumerated() {
                continuation.yield((statement: line, lineNumber: index + 1))
            }
            continuation.finish(throwing: fails ? Unreadable() : nil)
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
        wrapInTransaction: Bool = true,
        sink: BatchingSink,
        source: LineSource? = nil,
        progress: Progress = Progress()
    ) async -> Result<PluginImportResult, any Error> {
        let plugin = SQLImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = wrapInTransaction
        plugin.settings.disableForeignKeyChecks = false
        do {
            return .success(try await plugin.performImport(
                source: source ?? LineSource(statements),
                sink: sink,
                progress: PluginImportProgress(progress: progress)
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func failedLine(_ outcome: Result<PluginImportResult, any Error>) -> (String, Int)? {
        guard case .failure(let error) = outcome,
              case .statementFailed(let statement, let line, _) = error as? PluginImportError else { return nil }
        return (statement, line)
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

        #expect(Self.failedLine(outcome)?.0 == statements[1])
        #expect(Self.failedLine(outcome)?.1 == 2)
        #expect(sink.events == ["begin", "batch 3", "rollback"])
    }

    @Test("A batch refused before any statement ran fails as its first statement would have")
    func refusedBatchNamesItsFirstStatement() async {
        let sink = BatchingSink()
        sink.refusesBatches = true

        let outcome = await runImport(Self.inserts(3), sink: sink)

        #expect(Self.failedLine(outcome)?.1 == 1)
        #expect(sink.events == ["begin", "batch 3", "rollback"])
    }

    @Test("A Stop that lands while the last batch runs rolls the import back instead of committing it")
    func stopDuringLastBatchRollsBack() async {
        let sink = BatchingSink()
        let progress = Progress()
        sink.stopsDuringBatch = progress

        let outcome = await runImport(Self.inserts(3), sink: sink, progress: progress)

        guard case .failure = outcome else {
            Issue.record("A stopped import should not succeed")
            return
        }
        #expect(sink.events == ["begin", "batch 3", "rollback"])
    }

    @Test("Stop and commit commits what ran before a batched failure")
    func stopAndCommitCommits() async {
        let sink = BatchingSink()
        let statements = Self.inserts(3)
        sink.failing = [statements[2]]

        let outcome = await runImport(statements, errorHandling: .stopAndCommit, sink: sink)

        #expect(Self.failedLine(outcome)?.1 == 3)
        #expect(sink.events == ["begin", "batch 3", "commit"])
    }

    @Test("A statement the connection keeps alone first sends the batch waiting ahead of it, saying the file was read past it")
    func loneStatementFlushesFirst() async throws {
        let sink = BatchingSink()
        let statements = [Self.inserts(1)[0], "SET search_path = app", "INSERT INTO t VALUES (9)"]

        _ = try await runImport(statements, sink: sink).get()

        #expect(sink.events == ["begin", "batch 1 read ahead", "SET search_path = app", "batch 1", "commit"])
    }

    @Test("A statement holding a backslash runs alone, after the batch read ahead of it")
    func backslashRunsAlone() async throws {
        let sink = BatchingSink()
        let escaped = #"INSERT INTO t VALUES ('a\'b')"#
        let statements = [Self.inserts(1)[0], escaped, "INSERT INTO t VALUES (9)"]

        _ = try await runImport(statements, sink: sink).get()

        #expect(sink.events == ["begin", "batch 1 read ahead", escaped, "batch 1", "commit"])
    }

    @Test("A batch that changed how the file reads stops the import at the statement read past it")
    func changedReadingRulesStopAtTheNextStatement() async {
        let sink = BatchingSink()
        sink.changesReadingRules = true
        let escaped = #"INSERT INTO t VALUES ('a\'b')"#

        let outcome = await runImport(Self.inserts(2) + [escaped], sink: sink)

        #expect(Self.failedLine(outcome)?.0 == escaped)
        #expect(Self.failedLine(outcome)?.1 == 3)
        #expect(sink.events == ["begin", "batch 2 read ahead", "rollback"])
    }

    @Test("Stop and commit keeps the statements that ran before the one the import could no longer read")
    func changedReadingRulesUnderStopAndCommit() async {
        let sink = BatchingSink()
        sink.changesReadingRules = true

        let outcome = await runImport(Self.inserts(2) + ["SET x = 1"], errorHandling: .stopAndCommit, sink: sink)

        #expect(Self.failedLine(outcome)?.1 == 3)
        #expect(sink.events == ["begin", "batch 2 read ahead", "commit"])
    }

    @Test("A statement that fails ahead of text the file cannot read is the failure reported, as it was one at a time")
    func failureAheadOfReadFailureIsReported() async {
        let sink = BatchingSink()
        let statements = Self.inserts(2)
        sink.failing = [statements[1]]

        let outcome = await runImport(statements, sink: sink, source: LineSource(statements, failsAfterLines: true))

        #expect(Self.failedLine(outcome)?.1 == 2)
        #expect(sink.events == ["begin", "batch 2 read ahead", "rollback"])
    }

    @Test("A read failure after a batch rolls back in every stop mode, as one read one statement at a time does", arguments: [
        ImportErrorHandling.stopAndRollback, .stopAndCommit,
    ])
    func readFailureRollsBack(errorHandling: ImportErrorHandling) async {
        let sink = BatchingSink()
        let statements = Self.inserts(2)

        let outcome = await runImport(
            statements, errorHandling: errorHandling, sink: sink, source: LineSource(statements, failsAfterLines: true)
        )

        guard case .failure(let error) = outcome,
              case .importFailed(let message) = error as? PluginImportError else {
            Issue.record("The read failure should end the import")
            return
        }
        #expect(message == Unreadable().errorDescription)
        #expect(sink.events == ["begin", "batch 2 read ahead", "rollback"])
    }

    @Test("A batch that changed how the file reads, ahead of a read failure, still rolls back under Stop and Commit")
    func changedReadingRulesBeforeReadFailureRollBack() async {
        let sink = BatchingSink()
        sink.changesReadingRules = true
        let statements = Self.inserts(2)

        let outcome = await runImport(
            statements, errorHandling: .stopAndCommit, sink: sink, source: LineSource(statements, failsAfterLines: true)
        )

        guard case .failure(let error) = outcome, case .importFailed = error as? PluginImportError else {
            Issue.record("The import should fail as a read failure does")
            return
        }
        #expect(sink.events == ["begin", "batch 2 read ahead", "rollback"])
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

    @Test("Without the import's transaction every statement goes alone", arguments: [
        ImportErrorHandling.stopAndRollback, .stopAndCommit,
    ])
    func unwrappedImportNeverBatches(errorHandling: ImportErrorHandling) async {
        let sink = BatchingSink()
        let statements = Self.inserts(3)
        sink.failing = [statements[1]]

        let outcome = await runImport(statements, errorHandling: errorHandling, wrapInTransaction: false, sink: sink)

        #expect(Self.failedLine(outcome)?.1 == 2)
        #expect(sink.events == Array(statements.prefix(2)))
    }

    @Test("A batch never grows past its statement limit")
    func batchesAreBounded() async throws {
        let sink = BatchingSink()
        let limit = SQLImportBatch.statementLimit

        _ = try await runImport(Self.inserts(limit * 2 + 7), sink: sink).get()

        #expect(sink.events == ["begin", "batch \(limit)", "batch \(limit)", "batch 7", "commit"])
    }
}
