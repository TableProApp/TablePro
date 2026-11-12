//
//  ImportService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

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
    // A row import counts rows through the statement counter.
    var countsRows = false
    var totalIsEstimate = true
}

// MARK: - Import Service

@MainActor
final class ImportService: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ImportService")

    @Published var state = ImportState()

    private let connection: DatabaseConnection
    private let historyRecorder: QueryHistoryRecording
    private let gate: ExecutionGate
    private let runningWork: RunningWorkRegistry
    @Published private var currentProgress: PluginImportProgress?
    // A Stop before a file's progress exists, while a table is created or between two files. Never reset.
    internal let run = ImportRun()
    @Published private(set) var stopQuestion: ImportStopQuestion?
    @Published private(set) var stopPhase = ImportRunPhase.running
    private var isStopRequested: Bool { run.stopChoice != nil }
    var stopResult: ImportStopResult { ImportStopResult(ledger: run.snapshot) }

    init(
        connection: DatabaseConnection,
        historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared,
        gate: ExecutionGate = ExecutionGateProvider.shared,
        runningWork: RunningWorkRegistry = .shared
    ) {
        self.connection = connection
        self.historyRecorder = historyRecorder
        self.gate = gate
        self.runningWork = runningWork
        run.observe { [weak self] in
            Task { @MainActor [weak self] in self?.syncStopState() }
        }
    }

    private func beginRunningWork(named subject: String) -> UUID {
        runningWork.begin(
            .dataImport,
            subject: subject,
            connectionName: connection.name,
            connectionIds: [connection.id]
        ) { [weak self] in
            self?.cancelImport()
        }
    }

    // MARK: - Cancellation

    func cancelImport() {
        run.stop(.rollBack)
        currentProgress?.cancel()
        syncStopState()
    }

    func requestStop() {
        run.requestPause()
        syncStopState()
    }

    func answerStop(_ choice: ImportStopChoice?, generation: Int) {
        if let choice {
            if run.stop(choice, generation: generation) { currentProgress?.cancel() }
        } else {
            run.resume(generation: generation)
        }
        syncStopState()
    }

    func stopUnansweredQuestion() {
        if run.stopUnansweredPause() { currentProgress?.cancel() }
        syncStopState()
    }

    private func syncStopState() {
        stopPhase = run.currentPhase
        stopQuestion = run.questionIfPaused().map { ImportStopQuestion(generation: $0.generation, ledger: $0.ledger) }
    }

    // MARK: - Public API

    // `sourceName` names history for a copy the app wrote; `authorization` is a grant this run already has.
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
        do {
            let result = try await performImportFile(
                from: url, sourceName: sourceName, formatId: formatId, encoding: encoding, scope: scope,
                decompressedURL: decompressedURL, ownsDecompressedFile: ownsDecompressedFile,
                knownStatementCount: knownStatementCount, targetTable: targetTable, columnMapping: columnMapping,
                sourceFields: sourceFields, rowWriting: rowWriting, authorization: authorization
            )
            await run.complete()
            syncStopState()
            if run.stopChoice != nil { throw PluginImportCancellationError() }
            return result
        } catch {
            await run.complete()
            syncStopState()
            throw error
        }
    }

    private func performImportFile(
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
        let historyName = sourceName ?? url.lastPathComponent

        state = ImportState(isImporting: true)
        state.fileName = historyName
        state.countsRows = targetTable != nil
        state.totalIsEstimate = knownStatementCount == nil
        let workId = beginRunningWork(named: historyName)
        defer {
            state.isImporting = false
            currentProgress = nil
            runningWork.end(workId)
        }

        let sqlSource = type(of: plugin).requiresTargetTable ? nil : SqlFileImportSource(
            url: url,
            encoding: encoding,
            family: TransactionEngineFamily.of(connection.type),
            decompressedURL: decompressedURL,
            ownsDecompressedFile: ownsDecompressedFile
        )
        let source: any PluginImportSource
        if let sqlSource {
            source = sqlSource
        } else {
            source = PlainFileImportSource(url: decompressedURL ?? url)
        }
        defer { source.cleanup() }
        guard !isStopRequested else { throw PluginImportCancellationError() }

        // After the source exists, so a refusal still removes the decompressed copy it was handed.
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
            result = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: route,
                workload: .bulk,
                cancellation: .protectedWrite
            ) { driver in
                sqlSource?.readsGrammar(from: Self.sessionGrammar(of: driver))
                return try await self.runImport(
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

    func importFiles(
        _ files: [RowImportRunItem],
        scope: DatabaseScope,
        policy: RowImportBatchPolicy,
        authorization: OperationReceipt? = nil
    ) async throws -> RowImportBatchReport {
        do {
            let result = try await performImportFiles(files, scope: scope, policy: policy, authorization: authorization)
            await run.complete()
            syncStopState()
            return result
        } catch {
            await run.complete()
            syncStopState()
            throw error
        }
    }

    private func performImportFiles(
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
        state.countsRows = true
        let workId = beginRunningWork(named: Self.batchName(fileCount: files.count))
        defer {
            state.isImporting = false
            currentProgress = nil
            runningWork.end(workId)
        }
        guard !isStopRequested else {
            return RowImportBatchReport(
                files: files,
                outcomes: files.map { _ in .notRun },
                ending: .stopped(file: 0),
                transaction: .untracked,
                executionTime: 0,
                stopResult: stopResult
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
        let control = run
        return try await withTaskCancellationHandler {
            try await self.runFilesControlled(files, plugins: plugins, driver: driver, policy: policy)
        } onCancel: { control.stop(.rollBack) }
    }

    private func runFilesControlled(
        _ files: [RowImportRunItem],
        plugins: [any ImportFormatPlugin],
        driver: DatabaseDriver,
        policy: RowImportBatchPolicy
    ) async throws -> RowImportBatchReport {
        let started = Date()
        let owner = ImportDataSinkAdapter(
            driver: driver,
            databaseType: connection.type,
            commitMode: DatabaseManager.shared.commitMode(for: connection.id),
            importRun: run,
            fileIndex: nil
        )
        var sessionScope: PluginSessionScope?
        var outcomes = [RowImportBatchReport.FileOutcome](repeating: .notRun, count: files.count)
        var ending = RowImportBatchReport.Ending.completed
        var currentIndex = 0
        do {
            try await owner.prepareImportRun()
            sessionScope = try await owner.withImportSession { await self.openPreservingScope(on: driver) }
            if policy.usesTransaction { try await owner.beginTransaction() }
            for (index, file) in files.enumerated() {
                currentIndex = index
                try await owner.importCheckpoint()
                let outcome = await runFile(file, plugin: plugins[index], index: index, driver: driver)
                outcomes[index] = outcome
                switch outcome {
                case .stopped:
                    ending = .stopped(file: index)
                case .failed where policy.errorHandling != .skipAndContinue:
                    ending = .failed(file: index)
                case .imported, .failed, .notRun:
                    break
                }
                guard ending == .completed else { break }
            }
            try await owner.importCheckpoint()
        } catch {
            if error is PluginImportCancellationError || error is CancellationError {
                run.stop(.rollBack)
                ending = .stopped(file: currentIndex)
            } else {
                await owner.recordImportError(error)
                if !files.isEmpty { outcomes[currentIndex] = .failed(error, rowsBefore: submittedRows(for: currentIndex)) }
                ending = .failed(file: currentIndex)
            }
        }
        let commits: Bool
        switch ending {
        case .completed: commits = true
        case .failed: commits = policy.errorHandling == .stopAndCommit
        case .stopped: commits = false
        }
        if let error = await finishOwner(owner, commit: commits), ending == .completed, !files.isEmpty {
            outcomes[currentIndex] = .failed(error, rowsBefore: submittedRows(for: currentIndex))
            ending = .failed(file: currentIndex)
        }
        try? await owner.withImportSession { await self.closePreservingScope(sessionScope, on: driver) }
        await run.complete()
        syncStopState()
        if run.stopChoice != nil { ending = .stopped(file: currentIndex) }
        let report = RowImportBatchReport(
            files: files, outcomes: outcomes, ending: ending, transaction: owner.transactionOutcome,
            executionTime: Date().timeIntervalSince(started), stopResult: stopResult
        )
        return report
    }

    private func submittedRows(for index: Int) -> Int {
        run.snapshot.effects[index]?.submittedRows ?? 0
    }

    @MainActor
    private func runFile(
        _ file: RowImportRunItem,
        plugin: any ImportFormatPlugin,
        index: Int,
        driver: DatabaseDriver
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
            binaryText: ImportBinaryText(formatId: file.formatId),
            joinsTransaction: true,
            importRun: run,
            fileIndex: index,
            isCancelled: { progress.isCancelled }
        )
        do {
            try await sink.prepareImportRun()
            return .imported(try await plugin.performImport(source: source, sink: sink, progress: progress))
        } catch is PluginImportCancellationError {
            run.stop(.rollBack)
            return .stopped(rowsBefore: submittedRows(for: index))
        } catch is CancellationError {
            run.stop(.rollBack)
            return .stopped(rowsBefore: submittedRows(for: index))
        } catch {
            await sink.recordImportError(error)
            return .failed(error, rowsBefore: submittedRows(for: index))
        }
    }

    internal func finishOwner(_ owner: ImportDataSinkAdapter, commit: Bool) async -> (any Error)? {
        var selected = run.stopChoice ?? (commit ? .commit : .rollBack)
        while true {
            do {
                if selected == .commit { try await owner.commitTransaction() } else { try await owner.rollbackTransaction() }
            } catch is PluginImportCancellationError {
                if let winner = run.stopChoice, winner != selected {
                    selected = winner
                    continue
                }
                return PluginImportCancellationError()
            } catch {
                await owner.recordImportError(error)
                return error
            }
            if let winner = run.stopChoice, winner != selected {
                selected = winner
                continue
            }
            return nil
        }
    }

    private func recordHistory(of report: RowImportBatchReport, in scope: DatabaseScope) async {
        for (index, pair) in zip(report.files, report.outcomes).enumerated() {
            let (file, outcome) = pair
            let fate = report.stopResult?.fate(for: index)
            let keepsFile = report.rowsKept || fate == .kept || fate == .committed
            switch outcome {
            case .imported(let result) where keepsFile:
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

    // Read before each statement from the leased session, whose sql_mode the file's own statements change.
    nonisolated private static func sessionGrammar(of driver: DatabaseDriver) -> @Sendable () -> SQLLexicalGrammar {
        let databaseType = driver.connection.type
        return { SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution }
    }

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
        let control = run
        return try await withTaskCancellationHandler {
            try await self.runImportControlled(
                plugin: plugin, driver: driver, source: source, progress: progress, targetTable: targetTable,
                columnMapping: columnMapping, sourceFields: sourceFields, rowWriting: rowWriting
            )
        } onCancel: { control.stop(.rollBack) }
    }

    private func runImportControlled(
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
            driver: driver, databaseType: connection.type, targetTable: targetTable,
            columnMapping: columnMapping, sourceFields: sourceFields, rowWriting: rowWriting,
            binaryText: ImportBinaryText(formatId: type(of: plugin).formatId),
            commitMode: DatabaseManager.shared.commitMode(for: connection.id),
            importRun: run, isCancelled: { progress.isCancelled }
        )
        defer {
            reportNameHazards(sink.nameHazardStatements)
            state.transactionOutcome = sink.transactionOutcome
            state.rowTally = targetTable == nil ? nil : sink.rowTally
        }
        var sessionScope: PluginSessionScope?
        var result: PluginImportResult?
        var failure: (any Error)?
        do {
            try await sink.prepareImportRun()
            sessionScope = try await sink.withImportSession { await self.openPreservingScope(on: driver) }
            result = try await plugin.performImport(source: source, sink: sink, progress: progress)
            try await sink.importCheckpoint()
        } catch {
            failure = error
            if error is PluginImportCancellationError || error is CancellationError {
                run.stop(.rollBack)
            } else {
                await sink.recordImportError(error)
            }
        }
        if let error = await finishOwner(sink, commit: failure == nil), failure == nil { failure = error }
        try? await sink.withImportSession { await self.closePreservingScope(sessionScope, on: driver) }
        await run.complete()
        syncStopState()
        if run.stopChoice != nil { throw PluginImportCancellationError() }
        if let failure {
            if sink.transactionOutcome == .committedBeforeRollback { throw ImportCommittedTransactionError.noting(failure) }
            throw failure
        }
        guard let result else { throw PluginImportError.importFailed(String(localized: "Import did not finish.")) }
        return result
    }

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
            run.record { $0.recordCleanupError(error); $0.uncertainHistory = true }
            Self.logger.warning(
                "Could not restore the session settings after the import: \(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func reportNameHazards(_ statements: [String]) {
        guard !statements.isEmpty else { return }
        CatalogChangeService.post(
            .statementsRan(connectionId: connection.id, statements: statements, databaseType: connection.type)
        )
    }

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
