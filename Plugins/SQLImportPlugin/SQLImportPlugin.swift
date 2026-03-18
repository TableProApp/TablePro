//
//  SQLImportPlugin.swift
//  SQLImportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class SQLImportPlugin: ImportFormatPlugin, SettablePlugin {
    static let pluginName = "SQL Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from SQL files"
    static let formatId = "sql"
    static let formatDisplayName = "SQL"
    static let acceptedFileExtensions = ["sql", "gz"]
    static let iconName = "doc.text"

    typealias Settings = SQLImportOptions
    static let settingsStorageId = "sql-import"

    var settings = SQLImportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(SQLImportOptionsView(plugin: self))
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        var executedCount = 0

        // Estimate total from file size (~500 bytes per statement)
        let fileSizeBytes = source.fileSizeBytes()
        let estimatedTotal = max(1, Int(fileSizeBytes / 500))
        progress.setEstimatedTotal(estimatedTotal)

        do {
            // Disable FK checks if enabled
            if settings.disableForeignKeyChecks {
                try await sink.disableForeignKeyChecks()
            }

            // Begin transaction if enabled
            if settings.wrapInTransaction {
                try await sink.beginTransaction()
            }

            // Stream and execute statements
            let stream = try await source.statements()

            for try await (statement, lineNumber) in stream {
                try progress.checkCancellation()

                do {
                    try await sink.execute(statement: statement)
                    executedCount += 1
                    progress.incrementStatement()
                } catch {
                    throw PluginImportError.statementFailed(
                        statement: statement,
                        line: lineNumber,
                        underlyingError: error
                    )
                }
            }

            // Commit transaction
            if settings.wrapInTransaction {
                try await sink.commitTransaction()
            }

            // Re-enable FK checks
            if settings.disableForeignKeyChecks {
                try await sink.enableForeignKeyChecks()
            }
        } catch {
            let importError = error

            // Rollback on error
            if settings.wrapInTransaction {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    throw PluginImportError.rollbackFailed(underlyingError: importError)
                }
            }

            // Re-enable FK checks (best-effort)
            if settings.disableForeignKeyChecks {
                try? await sink.enableForeignKeyChecks()
            }

            // Re-throw cancellation as-is, wrap others
            if importError is PluginImportCancellationError {
                throw importError
            }
            if importError is PluginImportError {
                throw importError
            }
            throw PluginImportError.importFailed(importError.localizedDescription)
        }

        progress.finalize()

        return PluginImportResult(
            executedStatements: executedCount,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }
}
