//
//  ImportService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Import State

struct ImportState {
    var isImporting: Bool = false
    var progress: Double = 0.0
    var processedStatements: Int = 0
    var skippedStatements: Int = 0
    var estimatedTotalStatements: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
    var transactionOutcome: ImportTransactionOutcome = .untracked
    var rowTally: ImportRowTally?
    var fileCount: Int = 0
    var fileIndex: Int = 0
    var fileName: String = ""
}

// MARK: - Import Service

@MainActor
final class ImportService: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ImportService")

    @Published var state = ImportState()

    private let connection: DatabaseConnection
    private let historyRecorder: QueryHistoryRecording
    private let gate: ExecutionGate
    @Published private var currentProgress: PluginImportProgress?
    /// A Stop pressed before a file's progress exists, while a table is created or between two files, which
    /// cancelling the progress alone would drop. A service runs one import, so it is never reset.
    private var isStopRequested = false

    init(
        connection: DatabaseConnection,
        historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared,
        gate: ExecutionGate = ExecutionGateProvider.shared
    ) {
        self.connection = connection
        self.historyRecorder = historyRecorder
        self.gate = gate
    }

    // MARK: - Cancellation

    func cancelImport() {
        isStopRequested = true
        currentProgress?.cancel()
    }

    // MARK: - Public API

    /// `sourceName` names the history row when the file is a copy the app wrote under a generated
    /// name, so history shows the file the user imported. `authorization` is a grant the caller
    /// already got from the gate in this run, so one import asks once.
    func importFile(
        from url: URL,
        sourceName: String? = nil,
        formatId: String,
        encoding: String.Encoding,
        scope: DatabaseScope,
        decompressedURL: URL? = nil,
        ownsDecompressedFile: Bool = false,
        knownStatementCount: Int? = nil,
        targetTable: String? = nil,
        columnMapping: [String: String] = [:],
        sourceFields: Set<String> = [],
        rowWriting: ImportRowWriting = .insert,
        authorization: OperationReceipt? = nil
    ) async throws -> PluginImportResult {
        guard let plugin = PluginManager.shared.importPlugin(forFormat: formatId) else {
            throw PluginImportError.importFailed("Import format '\(formatId)' not found")
        }

        let route = DatabaseManager.shared.executionRoute(for: scope)

        state = ImportState(isImporting: true)
        defer {
            state.isImporting = false
            currentProgress = nil
        }

        let source: any PluginImportSource
        if type(of: plugin).requiresTargetTable {
            source = PlainFileImportSource(url: decompressedURL ?? url)
        } else {
            source = SqlFileImportSource(
                url: url,
                encoding: encoding,
                grammar: SQLLexicalResolver.executionGrammar(for: connection.type, connectionId: connection.id),
                family: TransactionEngineFamily.of(connection.type),
                decompressedURL: decompressedURL,
                ownsDecompressedFile: ownsDecompressedFile
            )
        }
        defer { source.cleanup() }
        guard !isStopRequested else { throw PluginImportCancellationError() }

        let historyName = sourceName ?? url.lastPathComponent
        /// After the source exists, so a refusal still removes the decompressed copy it was handed.
        try await authorizeRun(named: historyName, given: authorization)
        let initialTotal = Int64(knownStatementCount ?? 0)
        let nsProgress = Progress(totalUnitCount: initialTotal)
        let progress = PluginImportProgress(progress: nsProgress)
        if knownStatementCount != nil {
            state.estimatedTotalStatements = Int(initialTotal)
        }
        currentProgress = progress
        let observations = track(nsProgress)
        defer { observations.forEach { $0.invalidate() } }

        let result: PluginImportResult
        let startedAt = Date()
        let operationStart = ContinuousClock.Instant.now
        do {
            /// The whole import runs inside one lease, because the plugin's own `BEGIN` spans the
            /// run: a per-statement lease would let another tab's statement execute inside the
            /// import's transaction and be committed or rolled back with it. Taking the lease is
            /// also what registers the import, so the health check no longer enters the same
            /// non-thread-safe driver partway through a batch of inserts. `.protectedWrite`
            /// because an import writes, so Stop in another tab must not reach it.
            result = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: route,
                workload: .bulk,
                cancellation: .protectedWrite
            ) { driver in
                try await self.runImport(
                    plugin: plugin,
                    driver: driver,
                    source: source,
                    progress: progress,
                    targetTable: targetTable,
                    columnMapping: columnMapping,
                    sourceFields: sourceFields,
                    rowWriting: rowWriting
                )
            }
        } catch {
            state.errorMessage = error.localizedDescription

            // An import the user cancelled is not a failed import, and the query paths already
            // keep cancellations out of history for the same reason.
            guard !(error is PluginImportCancellationError) else { throw error }
            /// Cancelling while the import is still queued behind another tab's operation throws
            /// before a single statement runs. That is the same "they stopped it" case, arriving
            /// from the gate rather than from the plugin.
            guard !(error is CancellationError) else { throw error }

            await historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: "-- Import from \(historyName) (\(progress.processedStatements) statements before failure)",
                    connectionId: connection.id,
                    databaseName: scope.database,
                    databaseType: connection.type,
                    source: .dataImport,
                    executionTime: Date().timeIntervalSince(startedAt),
                    rowCount: -1,
                    wasSuccessful: false,
                    errorMessage: error.localizedDescription
                )
            )

            reportImportFinished(
                .failed(reason: error.localizedDescription), in: scope, startedAt: operationStart
            )
            throw error
        }

        state.processedStatements = result.executedStatements
        state.skippedStatements = result.skippedStatements
        state.estimatedTotalStatements = result.executedStatements + result.skippedStatements
        state.progress = 1.0

        await historyRecorder.record(
            QueryHistoryRecordRequest(
                query: "-- Import from \(historyName) (\(result.executedStatements) statements)",
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                source: .dataImport,
                executionTime: result.executionTime,
                rowCount: -1,
                wasSuccessful: true
            )
        )

        reportImportFinished(
            .succeeded(OperationSummary(statementCount: result.executedStatements)),
            in: scope,
            startedAt: operationStart
        )

        return result
    }

    private func track(_ nsProgress: Progress) -> [NSKeyValueObservation] {
        let counts = nsProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let processed = Int(observed.completedUnitCount)
                let total = Int(observed.totalUnitCount)
                self.state.processedStatements = processed
                self.state.estimatedTotalStatements = total
                if total > 0 {
                    self.state.progress = min(1.0, Double(processed) / Double(total))
                }
            }
        }
        let status = nsProgress.observe(\.localizedAdditionalDescription) { [weak self] observed, _ in
            let status = observed.localizedAdditionalDescription ?? ""
            Task { @MainActor [weak self] in
                guard let self, !status.isEmpty else { return }
                self.state.statusMessage = status
            }
        }
        return [counts, status]
    }

    // MARK: - Several files

    /// Imports each file into its own table in one lease, one session scope and, unless the policy turns it off,
    /// one transaction, so a failure in any file takes back every file under Stop and Rollback. A failure or a Stop
    /// is in the report rather than thrown, because the report says what became of the files before it.
    func importFiles(
        _ files: [RowImportRunItem],
        scope: DatabaseScope,
        policy: RowImportBatchPolicy,
        authorization: OperationReceipt? = nil
    ) async throws -> RowImportBatchReport {
        let plugins: [any ImportFormatPlugin] = try files.map { file in
            guard let plugin = PluginManager.shared.importPlugin(forFormat: file.formatId) else {
                throw PluginImportError.importFailed("Import format '\(file.formatId)' not found")
            }
            return plugin
        }

        let route = DatabaseManager.shared.executionRoute(for: scope)
        state = ImportState(isImporting: true)
        state.fileCount = files.count
        defer {
            state.isImporting = false
            currentProgress = nil
        }
        guard !isStopRequested else {
            return RowImportBatchReport(
                files: files,
                outcomes: files.map { _ in .notRun },
                ending: .stopped(file: 0),
                transaction: .untracked,
                executionTime: 0
            )
        }

        try await authorizeRun(named: Self.batchName(fileCount: files.count), given: authorization)
        let operationStart = ContinuousClock.Instant.now
        let report = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            workload: .bulk,
            cancellation: .protectedWrite
        ) { driver in
            try await self.runFiles(files, plugins: plugins, driver: driver, policy: policy)
        }
        state.transactionOutcome = report.transaction

        await recordHistory(of: report, in: scope)
        switch report.ending {
        case .completed:
            reportImportFinished(
                .succeeded(OperationSummary(statementCount: report.importedRowCount)),
                in: scope,
                startedAt: operationStart
            )
        case .failed:
            let reason = report.failure?.localizedDescription ?? String(localized: "Unknown error")
            reportImportFinished(.failed(reason: reason), in: scope, startedAt: operationStart)
        case .stopped:
            break
        }
        return report
    }

    internal static func batchName(fileCount: Int) -> String {
        fileCount == 1
            ? String(localized: "1 file")
            : String(format: String(localized: "%lld files"), Int64(fileCount))
    }

    @MainActor
    private func runFiles(
        _ files: [RowImportRunItem],
        plugins: [any ImportFormatPlugin],
        driver: DatabaseDriver,
        policy: RowImportBatchPolicy
    ) async throws -> RowImportBatchReport {
        let started = Date()
        let owner = ImportDataSinkAdapter(driver: driver, databaseType: connection.type)
        let sessionScope = await openPreservingScope(on: driver)
        if policy.usesTransaction {
            do {
                try await owner.beginTransaction()
            } catch {
                await closePreservingScope(sessionScope, on: driver)
                throw error
            }
        }

        var outcomes = [RowImportBatchReport.FileOutcome](repeating: .notRun, count: files.count)
        var ending = RowImportBatchReport.Ending.completed
        for (index, file) in files.enumerated() {
            guard !isStopRequested, !Task.isCancelled else {
                outcomes[index] = .stopped(rowsBefore: 0)
                ending = .stopped(file: index)
                break
            }
            switch await runFile(file, plugin: plugins[index], index: index, driver: driver, policy: policy) {
            case .imported(let result):
                outcomes[index] = .imported(result)
            case .stopped(let rows):
                outcomes[index] = .stopped(rowsBefore: rows)
                ending = .stopped(file: index)
            case .failed(let error, let rows):
                outcomes[index] = .failed(error, rowsBefore: rows)
                if policy.errorHandling != .skipAndContinue {
                    ending = .failed(file: index)
                }
            case .notRun:
                break
            }
            guard ending == .completed else { break }
        }

        if policy.usesTransaction {
            do {
                try await endTransaction(owner, after: ending, policy: policy)
            } catch {
                await closePreservingScope(sessionScope, on: driver)
                throw error
            }
        }
        await closePreservingScope(sessionScope, on: driver)
        return RowImportBatchReport(
            files: files,
            outcomes: outcomes,
            ending: ending,
            transaction: owner.transactionOutcome,
            executionTime: Date().timeIntervalSince(started)
        )
    }

    @MainActor
    private func runFile(
        _ file: RowImportRunItem,
        plugin: any ImportFormatPlugin,
        index: Int,
        driver: DatabaseDriver,
        policy: RowImportBatchPolicy
    ) async -> RowImportBatchReport.FileOutcome {
        state.fileIndex = index
        state.fileName = file.sourceName
        state.processedStatements = 0
        state.estimatedTotalStatements = 0
        state.progress = 0
        state.statusMessage = ""

        let nsProgress = Progress(totalUnitCount: 0)
        let progress = PluginImportProgress(progress: nsProgress)
        currentProgress = progress
        let observations = track(nsProgress)
        defer { observations.forEach { $0.invalidate() } }

        let source = PlainFileImportSource(url: file.url)
        defer { source.cleanup() }
        let sink = ImportDataSinkAdapter(
            driver: driver,
            databaseType: connection.type,
            targetTable: file.targetTable,
            columnMapping: file.columnMapping,
            sourceFields: file.sourceFields,
            joinsTransaction: policy.usesTransaction,
            isCancelled: { progress.isCancelled }
        )
        do {
            return .imported(try await plugin.performImport(source: source, sink: sink, progress: progress))
        } catch is PluginImportCancellationError {
            return .stopped(rowsBefore: progress.processedStatements)
        } catch is CancellationError {
            return .stopped(rowsBefore: progress.processedStatements)
        } catch {
            return .failed(error, rowsBefore: progress.processedStatements)
        }
    }

    /// Stop and Commit keeps what ran before the failure, as one file's import does. A failure under Stop and
    /// Rollback, and a Stop under any policy, take back every file.
    @MainActor
    private func endTransaction(
        _ owner: ImportDataSinkAdapter,
        after ending: RowImportBatchReport.Ending,
        policy: RowImportBatchPolicy
    ) async throws {
        switch ending {
        case .completed:
            do {
                try await owner.commitTransaction()
            } catch {
                try? await owner.rollbackTransaction()
                throw error
            }
        case .failed where policy.errorHandling == .stopAndCommit:
            do {
                try await owner.commitTransaction()
            } catch {
                Self.logger.warning("Commit of a partial import failed: \(error.publicLogShape, privacy: .public)")
            }
        case .failed, .stopped:
            do {
                try await owner.rollbackTransaction()
            } catch {
                Self.logger.warning("Rollback of a failed import failed: \(error.publicLogShape, privacy: .public)")
            }
        }
    }

    /// A file's row is recorded only while its rows are still there, so a rolled-back run records the failure alone.
    private func recordHistory(of report: RowImportBatchReport, in scope: DatabaseScope) async {
        for (file, outcome) in zip(report.files, report.outcomes) {
            switch outcome {
            case .imported(let result) where report.rowsKept:
                await recordImport(of: file.sourceName, statements: result.executedStatements,
                                   executionTime: result.executionTime, error: nil, in: scope)
            case .failed(let error, let rows):
                await recordImport(of: file.sourceName, statements: rows,
                                   executionTime: 0, error: error, in: scope)
            case .imported, .stopped, .notRun:
                break
            }
        }
    }

    private func recordImport(
        of fileName: String,
        statements: Int,
        executionTime: TimeInterval,
        error: (any Error)?,
        in scope: DatabaseScope
    ) async {
        let query = error == nil
            ? "-- Import from \(fileName) (\(statements) statements)"
            : "-- Import from \(fileName) (\(statements) statements before failure)"
        await historyRecorder.record(
            QueryHistoryRecordRequest(
                query: query,
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                source: .dataImport,
                executionTime: executionTime,
                rowCount: -1,
                wasSuccessful: error == nil,
                errorMessage: error?.localizedDescription
            )
        )
    }

    /// Before the lease, because a confirmation or a Touch ID prompt answered while it is held keeps
    /// every other tab on this connection waiting on the person.
    private func authorizeRun(named fileName: String, given authorization: OperationReceipt?) async throws {
        if let authorization, authorization.connectionId == connection.id, authorization.effectiveWrite {
            return
        }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: nil,
                kind: .importData,
                caller: .importPipeline,
                capabilities: .interactiveUser,
                operationDescription: String(format: String(localized: "Import %@"), fileName)
            )
        )
        if let denial = decision.denialError { throw denial }
    }

    /// The sink is built here rather than before the lease so it cannot outlive the driver it
    /// wraps, and so every statement it issues lands on the leased, pinned connection.
    @MainActor
    private func runImport(
        plugin: any ImportFormatPlugin,
        driver: DatabaseDriver,
        source: any PluginImportSource,
        progress: PluginImportProgress,
        targetTable: String?,
        columnMapping: [String: String],
        sourceFields: Set<String>,
        rowWriting: ImportRowWriting
    ) async throws -> PluginImportResult {
        let sink = ImportDataSinkAdapter(
            driver: driver,
            databaseType: connection.type,
            targetTable: targetTable,
            columnMapping: columnMapping,
            sourceFields: sourceFields,
            rowWriting: rowWriting,
            isCancelled: { progress.isCancelled }
        )
        defer {
            reportNameHazards(sink.nameHazardStatements)
            state.transactionOutcome = sink.transactionOutcome
            state.rowTally = targetTable == nil ? nil : sink.rowTally
        }
        let sessionScope = await openPreservingScope(on: driver)
        let result: PluginImportResult
        do {
            result = try await plugin.performImport(source: source, sink: sink, progress: progress)
        } catch {
            await closePreservingScope(sessionScope, on: driver)
            guard sink.transactionOutcome == .committedBeforeRollback else { throw error }
            throw ImportCommittedTransactionError.noting(error)
        }
        await closePreservingScope(sessionScope, on: driver)
        return result
    }

    /// The file runs on the editor's own session, so whatever it sets is put back once the import ends, however it
    /// ends.
    private func openPreservingScope(on driver: DatabaseDriver) async -> PluginSessionScope? {
        do {
            return try await driver.openSessionScope(for: .preserve)
        } catch {
            Self.logger.warning("Import runs without saving the session settings: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    private func closePreservingScope(_ scope: PluginSessionScope?, on driver: DatabaseDriver) async {
        guard let scope else { return }
        do {
            try await driver.closeSessionScope(scope)
        } catch {
            Self.logger.warning(
                "Could not restore the session settings after the import: \(error.publicLogShape, privacy: .public)"
            )
        }
    }

    /// The file ran on the same session as the editor, so a temporary table it made shadows a real one there
    /// for as long as the connection stays open, and has to reach the catalog like any statement the editor ran.
    private func reportNameHazards(_ statements: [String]) {
        guard !statements.isEmpty else { return }
        CatalogChangeService.post(
            .statementsRan(connectionId: connection.id, statements: statements, databaseType: connection.type)
        )
    }

    /// An import the user cancelled reports nothing, matching what history already does with one
    /// and for the same reason: they stopped it, so they know.
    ///
    /// Named after the scope the import ran in, as its history row is. The browse database read when
    /// the import ends is wherever another window moved the connection in the meantime.
    private func reportImportFinished(
        _ outcome: OperationOutcome,
        in scope: DatabaseScope,
        startedAt: ContinuousClock.Instant
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .dataImport,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: scope.database,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}

internal struct ImportCommittedTransactionError: LocalizedError {
    internal let cause: any Error

    internal static var note: String {
        String(localized: """
            The rollback did not undo everything. A statement in the file, such as COMMIT, CREATE, ALTER or DROP, \
            committed the import's transaction as it ran, so some of the statements before the failure were kept.
            """)
    }

    internal var errorDescription: String? {
        "\(cause.localizedDescription)\n\(Self.note)"
    }

    /// A statement failure keeps its shape, because the alert reads its line and statement from it. A cancel stays a
    /// cancel: its own alert already says what ran stays committed.
    internal static func noting(_ error: any Error) -> any Error {
        guard !(error is PluginImportCancellationError), !(error is CancellationError) else { return error }
        if let pluginError = error as? PluginImportError,
           case .statementFailed(let statement, let line, let underlyingError) = pluginError {
            return PluginImportError.statementFailed(
                statement: statement,
                line: line,
                underlyingError: ImportCommittedTransactionError(cause: underlyingError)
            )
        }
        return ImportCommittedTransactionError(cause: error)
    }
}
