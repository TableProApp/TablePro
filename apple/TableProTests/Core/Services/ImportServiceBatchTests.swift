//
//  ImportServiceBatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Records every statement and answers the session state an engine that cannot report it would.
private final class RecordingDriver: PluginDriverStub, @unchecked Sendable {
    var transactionState: PluginSessionTransactionState = .unknown
    var failingValue: String?
    private(set) var events: [String] = []

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if let failingValue, query.contains("'\(failingValue)'") {
            throw DatabaseError.queryFailed("Duplicate entry '\(failingValue)'")
        }
        return .empty
    }

    func switchDatabase(to database: String) async throws {}

    func sessionTransactionState() async -> PluginSessionTransactionState {
        transactionState
    }

    var inserts: [String] {
        events.filter { $0.hasPrefix("INSERT") }
    }
}

/// A row format the way the CSV, JSON and XLSX importers run: every line of the file is one row, written through
/// `RowImportRunner` with the configuration the format reports.
private final class LineRowsPlugin: ImportFormatPlugin {
    static let pluginName = "Line Rows"
    static let pluginVersion = "1.0"
    static let pluginDescription = "One row per line"
    static let formatId = "tablepro-tests-line-rows"
    static let formatDisplayName = "Lines"
    static let acceptedFileExtensions = ["lines"]
    static let iconName = "doc"
    static let requiresTargetTable = true

    private let configuration: RowImportRunner.Configuration

    required init() {
        configuration = RowImportRunner.Configuration(
            errorHandling: .stopAndRollback, wrapInTransaction: true, deleteExistingRows: false
        )
    }

    init(_ configuration: RowImportRunner.Configuration) {
        self.configuration = configuration
    }

    var rowImportConfiguration: RowImportRunner.Configuration? { configuration }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let text = try String(contentsOf: source.fileURL(), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        var delivered = false
        let outcome = try await RowImportRunner.run(configuration: configuration, sink: sink, progress: progress) {
            guard !delivered else { return nil }
            delivered = true
            return lines.enumerated().map { index, line in (line: index + 1, row: ["id": .text(line)]) }
        }
        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: 0,
            skippedStatements: outcome.skipped,
            errors: outcome.errors
        )
    }
}

private actor RecordingHistory: QueryHistoryRecording {
    private(set) var queries: [String] = []

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        queries.append(request.query)
        return true
    }
}

/// Twenty files of a folder import as one run: one transaction, so Stop and Rollback takes back every file when one
/// fails, and a file's sink never sends a `BEGIN` of its own inside it.
@MainActor
struct ImportServiceBatchTests {
    private struct Run {
        let report: RowImportBatchReport
        let driver: RecordingDriver
        let history: [String]
    }

    private func runFiles(
        _ contents: [String],
        policy: RowImportBatchPolicy,
        configuration: RowImportRunner.Configuration? = nil,
        failingValue: String? = nil,
        sessionState: PluginSessionTransactionState = .unknown,
        stopsFirst: Bool = false
    ) async throws -> Run {
        let driver = RecordingDriver()
        driver.failingValue = failingValue
        driver.transactionState = sessionState
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "shop"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let formatId = "\(LineRowsPlugin.formatId)-\(UUID().uuidString)"
        PluginManager.shared.importPlugins[formatId] = LineRowsPlugin(configuration ?? RowImportRunner.Configuration(
            errorHandling: policy.errorHandling,
            wrapInTransaction: policy.wrapInTransaction,
            deleteExistingRows: false
        ))
        defer { PluginManager.shared.importPlugins[formatId] = nil }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batch-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var items: [RowImportRunItem] = []
        for (index, content) in contents.enumerated() {
            let url = folder.appendingPathComponent("file\(index + 1).lines")
            try Data(content.utf8).write(to: url)
            items.append(RowImportRunItem(
                url: url,
                sourceName: url.lastPathComponent,
                formatId: formatId,
                targetTable: "table\(index + 1)",
                columnMapping: ["id": "id"],
                sourceFields: ["id"]
            ))
        }

        let history = RecordingHistory()
        let service = ImportService(connection: connection, historyRecorder: history, gate: AlwaysAllowGate())
        if stopsFirst {
            service.cancelImport()
        }
        let report = try await service.importFiles(
            items,
            scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: nil),
            policy: policy
        )
        return Run(report: report, driver: driver, history: await history.queries)
    }

    private static let rollback = RowImportBatchPolicy(errorHandling: .stopAndRollback, wrapInTransaction: true)

    @Test("Every file runs inside one transaction, with no BEGIN of its own")
    func oneTransactionForEveryFile() async throws {
        let run = try await runFiles(["a1\na2", "b1", "c1"], policy: Self.rollback)

        #expect(run.report.ending == .completed)
        #expect(run.driver.events.filter { $0 == "BEGIN" }.count == 1)
        #expect(run.driver.events.filter { $0 == "COMMIT" }.count == 1)
        #expect(run.driver.events.first(where: { $0 == "BEGIN" || $0.hasPrefix("INSERT") }) == "BEGIN")
        #expect(run.driver.events.last(where: { $0 == "COMMIT" || $0.hasPrefix("INSERT") }) == "COMMIT")
        #expect(run.driver.inserts.count == 3)
        #expect(run.report.importedRowCount == 4)
        #expect(run.report.transaction == .committed)
    }

    @Test("A failure in a later file rolls back the files before it under Stop and Rollback")
    func failureRollsBackEveryFile() async throws {
        let contents = (1...20).map { "row\($0)" }
        let run = try await runFiles(contents, policy: Self.rollback, failingValue: "row12")

        #expect(run.report.ending == .failed(file: 11))
        #expect(run.driver.inserts.count == 12)
        #expect(run.driver.events.contains("ROLLBACK"))
        #expect(!run.driver.events.contains("COMMIT"))
        #expect(run.report.transaction == .rolledBack)
        #expect(!run.report.rowsKept)
        guard case .notRun = run.report.outcomes[12] else {
            Issue.record("The file after the failure must not run")
            return
        }
    }

    @Test("A rolled-back run records only the failure in history")
    func rolledBackRunRecordsOnlyTheFailure() async throws {
        let run = try await runFiles(["a1", "b1", "bad"], policy: Self.rollback, failingValue: "bad")

        #expect(run.history == ["-- Import from file3.lines (0 statements before failure)"])
    }

    @Test("Stop and Commit keeps the files before the failure")
    func stopAndCommitKeepsEarlierFiles() async throws {
        let run = try await runFiles(
            ["a1", "b1", "bad"],
            policy: RowImportBatchPolicy(errorHandling: .stopAndCommit, wrapInTransaction: true),
            failingValue: "bad"
        )

        #expect(run.report.ending == .failed(file: 2))
        #expect(run.driver.events.last == "COMMIT")
        #expect(!run.driver.events.contains("ROLLBACK"))
        #expect(run.report.rowsKept)
        #expect(run.history.contains("-- Import from file1.lines (1 statements)"))
    }

    @Test("Skip and Continue opens no transaction and goes on past a failing row")
    func skipAndContinueGoesOn() async throws {
        let run = try await runFiles(
            ["a1\nbad\na3", "b1"],
            policy: RowImportBatchPolicy(errorHandling: .skipAndContinue, wrapInTransaction: true),
            failingValue: "bad"
        )

        #expect(run.report.ending == .completed)
        #expect(!run.driver.events.contains("BEGIN"))
        #expect(run.report.importedRowCount == 3)
        #expect(run.report.hasFailures)
    }

    @Test("A run without a transaction stops at the failure and keeps the files before it")
    func noTransactionStopsAndKeeps() async throws {
        let run = try await runFiles(
            ["a1", "bad", "c1"],
            policy: RowImportBatchPolicy(errorHandling: .stopAndRollback, wrapInTransaction: false),
            failingValue: "bad"
        )

        #expect(run.report.ending == .failed(file: 1))
        #expect(!run.driver.events.contains("BEGIN"))
        #expect(!run.driver.events.contains("ROLLBACK"))
        #expect(run.report.rowsKept)
        #expect(run.driver.inserts.count == 2)
    }

    @Test("A session holding the user's transaction is joined, never committed or rolled back")
    func userTransactionIsJoined() async throws {
        let run = try await runFiles(["a1", "bad"], policy: Self.rollback, failingValue: "bad", sessionState: .inTransaction)

        #expect(!run.driver.events.contains("BEGIN"))
        #expect(!run.driver.events.contains("COMMIT"))
        #expect(!run.driver.events.contains("ROLLBACK"))
    }

    /// The progress sheet is up while the new tables are created, before any file's progress exists to cancel.
    @Test("A Stop pressed before the first file runs imports nothing")
    func stopBeforeTheRunImportsNothing() async throws {
        let run = try await runFiles(["a1", "b1"], policy: Self.rollback, stopsFirst: true)

        #expect(run.report.ending == .stopped(file: 0))
        #expect(run.driver.events.isEmpty)
        #expect(run.history.isEmpty)
    }
}
