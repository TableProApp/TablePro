//
//  SQLImportPlugin.swift
//  SQLImportPlugin
//

import Combine
import Foundation
import os
import TableProPluginKit

nonisolated final class SQLImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = SQLImportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

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

            let stream = try await source.elements()

            // What one failed statement does to the run, the same whether it ran alone or in a batch.
            func handleFailure(_ error: any Error, statement: String, lineNumber: Int) async throws {
                if error is PluginImportCancellationError { throw PluginImportCancellationError() }
                if error is CancellationError { throw CancellationError() }
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

            // Only inside the import's transaction, never in Skip mode: a stop rolls back or commits what ran before the
            // failure, and the server runs nothing after it.
            var pending = SQLImportBatch()

            // `next` is the element the file was read for while the batch waited, nil when reading it failed.
            func flush(readAhead: Bool, next: PluginImportStatement? = nil) async throws {
                guard !pending.isEmpty else { return }
                try progress.checkCancellation()
                let statements = pending.take()
                do {
                    try await sink.execute(statements: statements, readAhead: readAhead)
                    executedCount += statements.count
                    for _ in statements { progress.incrementStatement() }
                    // A Stop during the batch could not reach the statements in it; the rollback still can.
                    try progress.checkCancellation()
                } catch let failure as PluginImportBatchFailure {
                    let ran = min(max(failure.index, 0), statements.count)
                    executedCount += ran
                    for _ in 0..<ran { progress.incrementStatement() }
                    if ran < statements.count {
                        let failed = statements[ran]
                        try await handleFailure(failure.underlying, statement: failed.text, lineNumber: failed.line)
                    } else if let next {
                        try await handleFailure(failure.underlying, statement: next.text, lineNumber: next.line)
                    } else {
                        // Past text the file could not read: the import ends as a read failure does, whatever the mode.
                        throw failure.underlying
                    }
                } catch {
                    // Refused before any of them ran, as the first one alone would have been.
                    try await handleFailure(error, statement: statements[0].text, lineNumber: statements[0].line)
                }
            }

            var elements = stream.makeAsyncIterator()
            while true {
                let element: PluginImportElement
                do {
                    guard let read = try await elements.next() else { break }
                    element = read
                } catch {
                    // One at a time, the statements before text the file cannot read would have run first. When they
                    // changed how the session reads text, the read failure may be theirs, and that is the error instead.
                    try await flush(readAhead: true)
                    throw error
                }
                try progress.checkCancellation()
                if useTransaction, case .statement(let statement, let lineNumber) = element, sink.batches(statement) {
                    pending.append(PluginImportStatement(text: statement, line: lineNumber))
                    if pending.isFull { try await flush(readAhead: false) }
                    continue
                }
                let statement = element.statementText
                let lineNumber = element.lineNumber
                try await flush(readAhead: true, next: PluginImportStatement(text: statement, line: lineNumber))

                do {
                    try await Self.run(element, on: sink, progress: progress)
                    executedCount += 1
                    progress.incrementStatement()
                } catch {
                    try await handleFailure(error, statement: statement, lineNumber: lineNumber)
                }
            }
            try await flush(readAhead: false)

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

    private static func run(
        _ element: PluginImportElement,
        on sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws {
        switch element {
        case .statement(let statement, let lineNumber):
            try await sink.execute(statement: statement, line: lineNumber)
        case .copyFromStandardInput(let statement, let lineNumber, let rows):
            let watched = SQLImportCopyRows.watching(rows, line: lineNumber, progress: progress)
            try await sink.copyFromStandardInput(statement: statement, line: lineNumber, rows: watched)
        @unknown default:
            throw PluginImportError.importFailed(String(
                format: String(localized: "This version of SQL Import cannot run line %@."),
                element.lineNumber.formatted()
            ))
        }
    }
}
