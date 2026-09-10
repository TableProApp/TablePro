//
//  ImportService.swift
//  TablePro
//
//  Plugin-driven import orchestrator. Resolves the import format plugin,
//  creates the adapter/source objects, and wires progress to the UI.
//

import Foundation
import Observation
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
}

// MARK: - Import Service

@MainActor @Observable
final class ImportService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ImportService")

    var state = ImportState()

    private let connection: DatabaseConnection
    private let historyRecorder: QueryHistoryRecording
    private var currentProgress: PluginImportProgress?

    init(connection: DatabaseConnection, historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared) {
        self.connection = connection
        self.historyRecorder = historyRecorder
    }

    // MARK: - Cancellation

    func cancelImport() {
        currentProgress?.cancel()
    }

    // MARK: - Public API

    func importFile(
        from url: URL,
        formatId: String,
        encoding: String.Encoding,
        decompressedURL: URL? = nil,
        ownsDecompressedFile: Bool = false,
        knownStatementCount: Int? = nil,
        targetTable: String? = nil,
        columnMapping: [String: String] = [:]
    ) async throws -> PluginImportResult {
        guard let plugin = PluginManager.shared.importPlugin(forFormat: formatId) else {
            throw PluginImportError.importFailed("Import format '\(formatId)' not found")
        }

        /// The scope the driver is already on, not the connection's saved default: a tab may have
        /// moved it, and on an engine that reconnects to change database, pinning somewhere else
        /// would refuse the import outright.
        guard let scope = DatabaseManager.shared.browseScope(for: connection.id) else {
            throw DatabaseError.notConnected
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
            let dialect = SqlDialect.from(databaseTypeId: connection.type.rawValue)
            source = SqlFileImportSource(
                url: url,
                encoding: encoding,
                dialect: dialect,
                decompressedURL: decompressedURL,
                ownsDecompressedFile: ownsDecompressedFile
            )
        }
        defer { source.cleanup() }

        let initialTotal = Int64(knownStatementCount ?? 0)
        let nsProgress = Progress(totalUnitCount: initialTotal)
        let progress = PluginImportProgress(progress: nsProgress)
        if knownStatementCount != nil {
            state.estimatedTotalStatements = Int(initialTotal)
        }
        currentProgress = progress

        let observation = nsProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
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
        defer { observation.invalidate() }

        let statusObservation = nsProgress.observe(\.localizedAdditionalDescription) { [weak self] observed, _ in
            let status = observed.localizedAdditionalDescription ?? ""
            Task { @MainActor [weak self] in
                guard let self, !status.isEmpty else { return }
                self.state.statusMessage = status
            }
        }
        defer { statusObservation.invalidate() }

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
                    columnMapping: columnMapping
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
                    query: "-- Import from \(url.lastPathComponent) (\(progress.processedStatements) statements before failure)",
                    connectionId: connection.id,
                    databaseName: DatabaseManager.shared.browseDatabaseName(for: connection),
                    databaseType: connection.type,
                    source: .dataImport,
                    executionTime: Date().timeIntervalSince(startedAt),
                    rowCount: -1,
                    wasSuccessful: false,
                    errorMessage: error.localizedDescription
                )
            )

            reportImportFinished(
                .failed(reason: error.localizedDescription), connection: connection, startedAt: operationStart
            )
            throw error
        }

        state.processedStatements = result.executedStatements
        state.skippedStatements = result.skippedStatements
        state.estimatedTotalStatements = result.executedStatements + result.skippedStatements
        state.progress = 1.0

        await historyRecorder.record(
            QueryHistoryRecordRequest(
                query: "-- Import from \(url.lastPathComponent) (\(result.executedStatements) statements)",
                connectionId: connection.id,
                databaseName: DatabaseManager.shared.browseDatabaseName(for: connection),
                databaseType: connection.type,
                source: .dataImport,
                executionTime: result.executionTime,
                rowCount: -1,
                wasSuccessful: true
            )
        )

        reportImportFinished(
            .succeeded(OperationSummary(statementCount: result.executedStatements)),
            connection: connection,
            startedAt: operationStart
        )

        return result
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
        columnMapping: [String: String]
    ) async throws -> PluginImportResult {
        let sink = ImportDataSinkAdapter(
            driver: driver,
            databaseType: connection.type,
            targetTable: targetTable,
            columnMapping: columnMapping
        )
        return try await plugin.performImport(source: source, sink: sink, progress: progress)
    }

    /// An import the user cancelled reports nothing, matching what history already does with one
    /// and for the same reason: they stopped it, so they know.
    private func reportImportFinished(
        _ outcome: OperationOutcome,
        connection: DatabaseConnection,
        startedAt: ContinuousClock.Instant
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .dataImport,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: DatabaseManager.shared.browseDatabaseName(for: connection),
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
