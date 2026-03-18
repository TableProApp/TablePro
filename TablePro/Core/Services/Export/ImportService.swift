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
    var estimatedTotalStatements: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
}

// MARK: - Import Service

@MainActor @Observable
final class ImportService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportService")

    var state = ImportState()

    private let connection: DatabaseConnection
    private var currentProgress: PluginImportProgress?

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Cancellation

    func cancelImport() {
        currentProgress?.cancel()
    }

    // MARK: - Public API

    func importFile(
        from url: URL,
        formatId: String,
        encoding: String.Encoding
    ) async throws -> PluginImportResult {
        guard let plugin = PluginManager.shared.importPlugins[formatId] else {
            throw PluginImportError.importFailed("Import format '\(formatId)' not found")
        }

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseError.notConnected
        }

        // Reset state
        state = ImportState(isImporting: true)
        defer {
            state.isImporting = false
            currentProgress = nil
        }

        // Create adapter and source
        let sink = ImportDataSinkAdapter(driver: driver, databaseType: connection.type)
        let source = SqlFileImportSource(url: url, encoding: encoding)
        defer { source.cleanup() }

        // Create progress tracker
        let progress = PluginImportProgress()
        currentProgress = progress

        // Wire progress to UI state via coalescer
        let pendingUpdate = ProgressUpdateCoalescer()
        progress.onUpdate = { [weak self] processed, total, status in
            let shouldDispatch = pendingUpdate.markPending()
            if shouldDispatch {
                Task { @MainActor [weak self] in
                    pendingUpdate.clearPending()
                    guard let self else { return }
                    self.state.processedStatements = processed
                    self.state.estimatedTotalStatements = total
                    if total > 0 {
                        self.state.progress = min(1.0, Double(processed) / Double(total))
                    }
                    if !status.isEmpty {
                        self.state.statusMessage = status
                    }
                }
            }
        }

        let result: PluginImportResult
        do {
            result = try await plugin.performImport(
                source: source,
                sink: sink,
                progress: progress
            )
        } catch {
            state.errorMessage = error.localizedDescription

            // Record failed import history
            QueryHistoryManager.shared.recordQuery(
                query: "-- Import from \(url.lastPathComponent) (\(progress.processedStatements) statements before failure)",
                connectionId: connection.id,
                databaseName: connection.database,
                executionTime: 0,
                rowCount: progress.processedStatements,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )

            throw error
        }

        // Update final state
        state.processedStatements = result.executedStatements
        state.estimatedTotalStatements = result.executedStatements
        state.progress = 1.0

        // Record success history
        QueryHistoryManager.shared.recordQuery(
            query: "-- Import from \(url.lastPathComponent) (\(result.executedStatements) statements)",
            connectionId: connection.id,
            databaseName: connection.database,
            executionTime: result.executionTime,
            rowCount: result.executedStatements,
            wasSuccessful: true,
            errorMessage: nil
        )

        return result
    }
}
