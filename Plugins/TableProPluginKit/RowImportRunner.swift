//
//  RowImportRunner.swift
//  TableProPluginKit
//
//  Shared orchestration for row-based importers (JSON, CSV): transaction
//  lifecycle, delete-before-import, batching, per-mode error handling, and
//  progress. Format plugins supply rows through the nextBatch closure.
//

import Foundation
import os

public enum RowImportRunner {
    public typealias Entry = (line: Int, row: [String: PluginCellValue])

    public struct Configuration: Sendable {
        public var errorHandling: ImportErrorHandling
        public var wrapInTransaction: Bool
        public var deleteExistingRows: Bool
        public var maxRecordedErrors: Int

        public init(
            errorHandling: ImportErrorHandling,
            wrapInTransaction: Bool,
            deleteExistingRows: Bool,
            maxRecordedErrors: Int = 1_000
        ) {
            self.errorHandling = errorHandling
            self.wrapInTransaction = wrapInTransaction
            self.deleteExistingRows = deleteExistingRows
            self.maxRecordedErrors = maxRecordedErrors
        }
    }

    public struct Outcome: Sendable {
        public let inserted: Int
        public let skipped: Int
        public let errors: [PluginImportResult.ImportStatementError]
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "RowImportRunner")

    public static func run(
        configuration: Configuration,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress,
        nextBatch: () async throws -> [Entry]?
    ) async throws -> Outcome {
        let useTransaction = configuration.wrapInTransaction
            && configuration.errorHandling != .skipAndContinue
        var inserted = 0
        var skipped = 0
        var errors: [PluginImportResult.ImportStatementError] = []

        do {
            if useTransaction {
                try await sink.beginTransaction()
            }
            if configuration.deleteExistingRows {
                try await sink.deleteAllRowsFromTargetTable()
            }

            while let batch = try await nextBatch() {
                try progress.checkCancellation()
                guard !batch.isEmpty else { continue }
                if configuration.errorHandling == .skipAndContinue {
                    try await insertSkippingErrors(
                        batch, into: sink, progress: progress, configuration: configuration,
                        inserted: &inserted, skipped: &skipped, errors: &errors
                    )
                } else {
                    try await insertBatch(batch, into: sink, progress: progress, inserted: &inserted)
                }
            }

            if useTransaction {
                try await sink.commitTransaction()
            }
        } catch {
            try await conclude(after: error, sink: sink, useTransaction: useTransaction, configuration: configuration)
        }

        progress.finalize()
        return Outcome(inserted: inserted, skipped: skipped, errors: errors)
    }

    private static func insertBatch(
        _ batch: [Entry],
        into sink: any PluginImportDataSink,
        progress: PluginImportProgress,
        inserted: inout Int
    ) async throws {
        do {
            try await sink.insertRows(batch.map(\.row))
            inserted += batch.count
            progress.incrementStatement(by: batch.count)
        } catch {
            let firstLine = batch.first?.line ?? 0
            throw PluginImportError.statementFailed(
                statement: "rows \(firstLine)-\(batch.last?.line ?? firstLine)",
                line: firstLine,
                underlyingError: error
            )
        }
    }

    private static func insertSkippingErrors(
        _ batch: [Entry],
        into sink: any PluginImportDataSink,
        progress: PluginImportProgress,
        configuration: Configuration,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError]
    ) async throws {
        for entry in batch {
            try progress.checkCancellation()
            do {
                try await sink.insertRow(entry.row)
                inserted += 1
            } catch {
                skipped += 1
                if errors.count < configuration.maxRecordedErrors {
                    errors.append(.init(
                        statement: "row \(entry.line)",
                        line: entry.line,
                        errorMessage: error.localizedDescription
                    ))
                }
            }
            progress.incrementStatement()
        }
    }

    private static func conclude(
        after error: Error,
        sink: any PluginImportDataSink,
        useTransaction: Bool,
        configuration: Configuration
    ) async throws -> Never {
        if useTransaction {
            if configuration.errorHandling == .stopAndCommit, !(error is PluginImportCancellationError) {
                do {
                    try await sink.commitTransaction()
                } catch {
                    logger.warning("Commit of partial import failed: \(error.localizedDescription)")
                }
            } else {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    logger.warning("Rollback after failed import also failed: \(error.localizedDescription)")
                }
            }
        }
        if error is PluginImportCancellationError { throw error }
        if error is PluginImportError { throw error }
        throw PluginImportError.importFailed(error.localizedDescription)
    }
}
