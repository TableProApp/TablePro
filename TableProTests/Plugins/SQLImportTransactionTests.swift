//
//  SQLImportTransactionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private struct FailingStatementError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class RecordingSink: PluginImportDataSink, @unchecked Sendable {
    enum Call: String, Equatable {
        case begin, commit, rollback, disableForeignKeys, enableForeignKeys
    }

    var calls: [Call] = []
    var statementsToFail: Set<String> = []
    var rollbackFails = false
    var enableForeignKeysFails = false

    let databaseTypeId = "SQLite"

    func execute(statement: String) async throws {
        if statementsToFail.contains(statement) {
            throw FailingStatementError(message: "no such table: nope")
        }
    }

    func deleteAllRowsFromTargetTable() async throws {}

    func beginTransaction() async throws { calls.append(.begin) }

    func commitTransaction() async throws { calls.append(.commit) }

    func rollbackTransaction() async throws {
        calls.append(.rollback)
        if rollbackFails {
            throw FailingStatementError(message: "cannot rollback - no transaction is active")
        }
    }

    func disableForeignKeyChecks() async throws { calls.append(.disableForeignKeys) }

    func enableForeignKeyChecks() async throws {
        calls.append(.enableForeignKeys)
        if enableForeignKeysFails {
            throw FailingStatementError(message: "cannot enable foreign keys inside a transaction")
        }
    }
}

private final class StatementSource: PluginImportSource, @unchecked Sendable {
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

/// A transaction is committed at most once and rolled back only while it is open. Rolling back a
/// transaction that already committed fails on the server, and that failure used to be reported to
/// the user in place of the real one (#2314).
///
/// Serialized because `SQLImportPlugin.settings` persists through plugin storage, so two
/// instances in flight at once read each other's error-handling mode.
@Suite("SQL import transaction lifecycle", .serialized)
struct SQLImportTransactionTests {
    private func runImport(
        _ statements: [String],
        failing: Set<String> = [],
        errorHandling: ImportErrorHandling,
        sink: RecordingSink
    ) async -> (any Error)? {
        let plugin = SQLImportPlugin()
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = true
        plugin.settings.disableForeignKeyChecks = true
        sink.statementsToFail = failing

        do {
            _ = try await plugin.performImport(
                source: StatementSource(statements),
                sink: sink,
                progress: PluginImportProgress(progress: Progress())
            )
            return nil
        } catch {
            return error
        }
    }

    @Test("Stop and commit does not then roll back what it committed")
    func stopAndCommitDoesNotRollBack() async {
        let sink = RecordingSink()
        _ = await runImport(
            ["INSERT INTO ok VALUES (1);", "INSERT INTO nope VALUES (1);"],
            failing: ["INSERT INTO nope VALUES (1);"],
            errorHandling: .stopAndCommit,
            sink: sink
        )
        #expect(sink.calls.contains(.commit))
        #expect(sink.calls.contains(.rollback) == false)
    }

    /// The rollback would fail, and that failure would replace the statement error the user needs.
    @Test("Stop and commit still reports the statement that failed")
    func stopAndCommitReportsTheStatement() async throws {
        let sink = RecordingSink()
        sink.rollbackFails = true
        let error = await runImport(
            ["INSERT INTO nope VALUES (1);"],
            failing: ["INSERT INTO nope VALUES (1);"],
            errorHandling: .stopAndCommit,
            sink: sink
        )
        let pluginError = try #require(error as? PluginImportError)
        guard case .statementFailed(_, _, let underlying) = pluginError else {
            Issue.record("Expected statementFailed, got \(pluginError)")
            return
        }
        #expect(underlying.localizedDescription.contains("no such table"))
        #expect(underlying.localizedDescription.contains("rollback") == false)
    }

    @Test("Stop and rollback rolls back and does not commit")
    func stopAndRollbackRollsBack() async {
        let sink = RecordingSink()
        _ = await runImport(
            ["INSERT INTO nope VALUES (1);"],
            failing: ["INSERT INTO nope VALUES (1);"],
            errorHandling: .stopAndRollback,
            sink: sink
        )
        #expect(sink.calls.contains(.rollback))
        #expect(sink.calls.contains(.commit) == false)
    }

    /// The rows are in the database. Telling the user the import failed invites a re-run and a
    /// second copy of every row.
    @Test("A committed import is not failed by the foreign key restore")
    func committedImportSurvivesAFailedForeignKeyRestore() async {
        let sink = RecordingSink()
        sink.enableForeignKeysFails = true
        let error = await runImport(
            ["INSERT INTO ok VALUES (1);"],
            errorHandling: .stopAndRollback,
            sink: sink
        )
        #expect(error == nil)
        #expect(sink.calls.contains(.commit))
        #expect(sink.calls.contains(.rollback) == false)
    }
}
