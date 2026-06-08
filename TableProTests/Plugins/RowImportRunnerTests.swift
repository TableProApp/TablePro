//
//  RowImportRunnerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private struct MockSinkError: Error {}

private final class MockImportSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String? = "table"

    private(set) var calls: [String] = []
    var onInsertRow: ([String: PluginCellValue]) throws -> Void = { _ in }
    var onInsertRows: ([[String: PluginCellValue]]) throws -> Void = { _ in }

    func execute(statement: String) async throws {
        calls.append("execute")
    }

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        calls.append("insertRow")
        try onInsertRow(values)
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        calls.append("insertRows(\(rows.count))")
        try onInsertRows(rows)
    }

    func deleteAllRowsFromTargetTable() async throws {
        calls.append("deleteAll")
    }

    func beginTransaction() async throws {
        calls.append("begin")
    }

    func commitTransaction() async throws {
        calls.append("commit")
    }

    func rollbackTransaction() async throws {
        calls.append("rollback")
    }

    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

@Suite("Row Import Runner")
struct RowImportRunnerTests {
    private func entry(_ line: Int, _ value: String = "v") -> RowImportRunner.Entry {
        (line, ["c": .text(value)])
    }

    private func makeProgress() -> PluginImportProgress {
        PluginImportProgress(progress: Progress())
    }

    private func provider(_ groups: [[RowImportRunner.Entry]]) -> () async throws -> [RowImportRunner.Entry]? {
        var remaining = groups
        return {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }

    private func configuration(
        _ errorHandling: ImportErrorHandling,
        wrapInTransaction: Bool = true,
        deleteExistingRows: Bool = false,
        maxRecordedErrors: Int = 1_000
    ) -> RowImportRunner.Configuration {
        RowImportRunner.Configuration(
            errorHandling: errorHandling,
            wrapInTransaction: wrapInTransaction,
            deleteExistingRows: deleteExistingRows,
            maxRecordedErrors: maxRecordedErrors
        )
    }

    @Test("Delete existing rows runs inside the transaction")
    func testDeleteRunsInsideTransaction() async throws {
        let sink = MockImportSink()
        let outcome = try await RowImportRunner.run(
            configuration: configuration(.stopAndRollback, deleteExistingRows: true),
            sink: sink,
            progress: makeProgress(),
            nextBatch: provider([[entry(1), entry(2)]])
        )
        #expect(sink.calls == ["begin", "deleteAll", "insertRows(2)", "commit"])
        #expect(outcome.inserted == 2)
    }

    @Test("Stop and rollback rolls back and reports the failed row range")
    func testStopAndRollbackRollsBack() async throws {
        let sink = MockImportSink()
        sink.onInsertRows = { _ in throw MockSinkError() }
        await #expect(throws: PluginImportError.self) {
            _ = try await RowImportRunner.run(
                configuration: configuration(.stopAndRollback),
                sink: sink,
                progress: makeProgress(),
                nextBatch: provider([[entry(1), entry(2)]])
            )
        }
        #expect(sink.calls.contains("rollback"))
        #expect(!sink.calls.contains("commit"))
    }

    @Test("Stop and commit keeps rows inserted before the error")
    func testStopAndCommitCommitsPartialWork() async throws {
        let sink = MockImportSink()
        var batchesSeen = 0
        sink.onInsertRows = { _ in
            batchesSeen += 1
            if batchesSeen == 2 { throw MockSinkError() }
        }
        await #expect(throws: PluginImportError.self) {
            _ = try await RowImportRunner.run(
                configuration: configuration(.stopAndCommit),
                sink: sink,
                progress: makeProgress(),
                nextBatch: provider([[entry(1)], [entry(2)]])
            )
        }
        #expect(sink.calls.contains("commit"))
        #expect(!sink.calls.contains("rollback"))
    }

    @Test("Skip mode inserts row by row, never retries a batch, and skips only failures")
    func testSkipModeInsertsRowByRowWithoutBatchRetry() async throws {
        let sink = MockImportSink()
        sink.onInsertRow = { values in
            if values["c"] == .text("bad") { throw MockSinkError() }
        }
        let outcome = try await RowImportRunner.run(
            configuration: configuration(.skipAndContinue),
            sink: sink,
            progress: makeProgress(),
            nextBatch: provider([[entry(1), entry(2, "bad"), entry(3)]])
        )
        #expect(outcome.inserted == 2)
        #expect(outcome.skipped == 1)
        #expect(outcome.errors.map(\.line) == [2])
        #expect(sink.calls.filter { $0 == "insertRow" }.count == 3)
        #expect(!sink.calls.contains { $0.hasPrefix("insertRows") })
        #expect(!sink.calls.contains("begin"))
        #expect(!sink.calls.contains("commit"))
        #expect(!sink.calls.contains("rollback"))
    }

    @Test("Skip mode caps recorded errors but keeps counting skips")
    func testErrorCapLimitsRecordedErrors() async throws {
        let sink = MockImportSink()
        sink.onInsertRow = { _ in throw MockSinkError() }
        let outcome = try await RowImportRunner.run(
            configuration: configuration(.skipAndContinue, maxRecordedErrors: 2),
            sink: sink,
            progress: makeProgress(),
            nextBatch: provider([[entry(1), entry(2), entry(3), entry(4)]])
        )
        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 4)
        #expect(outcome.errors.count == 2)
    }

    @Test("Cancellation rolls back even in stop-and-commit mode")
    func testCancellationRollsBack() async throws {
        let sink = MockImportSink()
        let progress = makeProgress()
        progress.cancel()
        await #expect(throws: PluginImportCancellationError.self) {
            _ = try await RowImportRunner.run(
                configuration: configuration(.stopAndCommit),
                sink: sink,
                progress: progress,
                nextBatch: provider([[entry(1)]])
            )
        }
        #expect(sink.calls.contains("rollback"))
        #expect(!sink.calls.contains("commit"))
    }

    @Test("Transaction is skipped when wrap is off")
    func testNoTransactionWhenWrapOff() async throws {
        let sink = MockImportSink()
        let outcome = try await RowImportRunner.run(
            configuration: configuration(.stopAndRollback, wrapInTransaction: false),
            sink: sink,
            progress: makeProgress(),
            nextBatch: provider([[entry(1)]])
        )
        #expect(outcome.inserted == 1)
        #expect(sink.calls == ["insertRows(1)"])
    }
}
