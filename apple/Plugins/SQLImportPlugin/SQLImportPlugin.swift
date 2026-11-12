//
//  SQLImportPlugin.swift
//  SQLImportPlugin
//

import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit

final class SQLImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLImportPlugin")

    static let pluginName = "SQL Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from SQL files"
    static let formatId = "sql"
    static let formatDisplayName = "SQL"
    static let acceptedFileExtensions = ["sql", "gz"]
    static let iconName = "doc.text"
    static let excludedDatabaseTypeIds = ["MongoDB", "Redis"]

    typealias Settings = SQLImportOptions
    static let settingsStorageId = "sql-import"

    @Published var settings = SQLImportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(SQLImportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = SQLImportOptions()
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        var executedCount = 0
        var skippedCount = 0
        var didCommit = false
        var errors: [PluginImportResult.ImportStatementError] = []
        let maxErrors = 1_000

        // One plugin instance serves every window: a checkbox unticked elsewhere mid-import left the checks off.
        let options = settings
        let errorMode = options.errorHandling
        let useTransaction = options.wrapInTransaction && errorMode != .skipAndContinue

        let fileSizeBytes = source.fileSizeBytes()
        let estimatedTotal = max(1, Int(fileSizeBytes / 500))
        progress.setEstimatedTotal(estimatedTotal)

        do {
            if options.disableForeignKeyChecks {
                try await sink.disableForeignKeyChecks()
            }

            if useTransaction {
                try await sink.beginTransaction()
            }

            let stream = try await source.statements()

            for try await (statement, lineNumber) in stream {
                try progress.checkCancellation()

                do {
                    try await sink.execute(statement: statement, line: lineNumber)
                    executedCount += 1
                    progress.incrementStatement()
                } catch is PluginImportCancellationError {
                    throw PluginImportCancellationError()
                } catch is CancellationError {
                    throw CancellationError()
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
                                didCommit = true
                            } catch {
                                Self.logger.warning("Failed to commit partial import")
                            }
                        }
                        if options.disableForeignKeyChecks {
                            do {
                                try await sink.enableForeignKeyChecks()
                            } catch {
                                Self.logger.warning("Failed to re-enable foreign key checks")
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
                didCommit = true
            }

            if options.disableForeignKeyChecks {
                do {
                    try await sink.enableForeignKeyChecks()
                } catch {
                    Self.logger.warning("Failed to re-enable foreign key checks")
                }
            }
        } catch {
            let importError = error
            var rollbackError: Error?

            if useTransaction, !didCommit {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    Self.logger.error(
                        "The import and its rollback both failed"
                    )
                    rollbackError = error
                }
            }

            if options.disableForeignKeyChecks {
                do {
                    try await sink.enableForeignKeyChecks()
                } catch {
                    Self.logger.warning("Failed to re-enable foreign key checks")
                }
            }

            throw SQLImportFailure.error(cause: importError, rollbackError: rollbackError)
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
