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

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseError.notConnected
        }

        state = ImportState(isImporting: true)
        defer {
            state.isImporting = false
            currentProgress = nil
        }

        let sink = ImportDataSinkAdapter(
            driver: driver,
            databaseType: connection.type,
            targetTable: targetTable,
            columnMapping: columnMapping
        )

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
            result = try await plugin.performImport(
                source: source,
                sink: sink,
                progress: progress
            )
        } catch {
            state.errorMessage = error.localizedDescription

            // An import the user cancelled is not a failed import, and the query paths already
            // keep cancellations out of history for the same reason.
            guard !(error is PluginImportCancellationError) else { throw error }

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
