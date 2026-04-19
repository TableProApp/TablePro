//
//  SQLImportPlugin.swift
//  SQLImportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class SQLImportPlugin: ImportFormatPlugin, SettablePlugin {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLImportPlugin")

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
        var skippedCount = 0
        var errors: [PluginImportResult.ImportStatementError] = []
        let maxErrors = 1_000

        let errorMode = settings.errorHandling
        let useTransaction = settings.wrapInTransaction && errorMode != .skipAndContinue

        let fileSizeBytes = source.fileSizeBytes()
        let estimatedTotal = max(1, Int(fileSizeBytes / 500))
        progress.setEstimatedTotal(estimatedTotal)

        do {
            if settings.disableForeignKeyChecks {
                try await sink.disableForeignKeyChecks()
            }

            if useTransaction {
                try await sink.beginTransaction()
            }

            let stream = try await source.statements()

            for try await (statement, lineNumber) in stream {
                try progress.checkCancellation()

                do {
                    try await sink.execute(statement: statement)
                    executedCount += 1
                    progress.incrementStatement()
                } catch {
                    switch errorMode {
                    case .stopAndRollback:
                        throw PluginImportError.statementFailed(
                            statement: statement,
                            line: lineNumber,
                            underlyingError: error
                        )

                    case .stopAndCommit:
                        let statementError = error
                        if useTransaction {
                            do {
                                try await sink.commitTransaction()
                            } catch {
                                Self.logger.warning("Failed to commit partial import: \(error.localizedDescription)")
                            }
                        }
                        if settings.disableForeignKeyChecks {
                            do {
                                try await sink.enableForeignKeyChecks()
                            } catch {
                                Self.logger.warning("Failed to re-enable foreign key checks: \(error.localizedDescription)")
                            }
                        }
                        throw PluginImportError.statementFailed(
                            statement: statement,
                            line: lineNumber,
                            underlyingError: statementError
                        )

                    case .skipAndContinue:
                        skippedCount += 1
                        if errors.count < maxErrors {
                            let snippet = (statement as NSString).length > 200
                                ? String(statement.prefix(200)) + "..."
                                : statement
                            errors.append(.init(
                                statement: snippet,
                                line: lineNumber,
                                errorMessage: error.localizedDescription
                            ))
                        }
                        progress.incrementStatement()
                    }
                }
            }

            if useTransaction {
                try await sink.commitTransaction()
            }

            if settings.disableForeignKeyChecks {
                try await sink.enableForeignKeyChecks()
            }
        } catch {
            let importError = error
            var rollbackError: Error?

            if useTransaction {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    Self.logger.error("Import failed: \(importError.localizedDescription). Rollback also failed.")
                    rollbackError = error
                }
            }

            if settings.disableForeignKeyChecks {
                do {
                    try await sink.enableForeignKeyChecks()
                } catch {
                    Self.logger.warning("Failed to re-enable foreign key checks: \(error.localizedDescription)")
                }
            }

            if let rollbackError {
                throw PluginImportError.rollbackFailed(underlyingError: rollbackError)
            }
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
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: skippedCount,
            errors: errors
        )
    }
}
