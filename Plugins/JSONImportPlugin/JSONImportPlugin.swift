//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class JSONImportPlugin: ImportFormatPlugin, SettablePlugin {
    private static let logger = Logger(subsystem: "com.TablePro", category: "JSONImportPlugin")

    static let pluginName = "JSON Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from JSON files"
    static let formatId = "json"
    static let formatDisplayName = "JSON"
    static let acceptedFileExtensions = ["json", "jsonl", "ndjson"]
    static let iconName = "curlybraces"
    static let requiresTargetTable = true

    typealias Settings = JSONImportOptions
    static let settingsStorageId = "json-import"

    var settings = JSONImportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(JSONImportOptionsView(plugin: self))
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()
        let useTransaction = settings.wrapInTransaction && settings.errorHandling != .skipAndContinue

        let batchSize = 500
        var inserted = 0
        var skipped = 0
        var errors: [PluginImportResult.ImportStatementError] = []
        let maxErrors = 1_000
        var batch: [(line: Int, row: [String: PluginCellValue])] = []

        do {
            if settings.deleteExistingRows {
                try await sink.deleteAllRowsFromTargetTable()
            }
            if useTransaction {
                try await sink.beginTransaction()
            }

            if JSONImportParsing.isLineDelimited(url) {
                progress.setEstimatedTotal(max(1, Int(source.fileSizeBytes() / 256)))
                var lineNumber = 0
                for try await line in url.lines {
                    try progress.checkCancellation()
                    lineNumber += 1
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    batch.append((lineNumber, try JSONImportParsing.parseRow(fromLine: trimmed)))
                    if batch.count >= batchSize {
                        try await flush(&batch, into: sink, progress: progress,
                                        inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)
                    }
                }
            } else {
                let rawRows = try JSONImportParsing.parseRows(at: url, targetTable: sink.targetTable)
                progress.setEstimatedTotal(rawRows.count)
                for (index, rawRow) in rawRows.enumerated() {
                    try progress.checkCancellation()
                    batch.append((index + 1, JSONImportParsing.convertRow(rawRow)))
                    if batch.count >= batchSize {
                        try await flush(&batch, into: sink, progress: progress,
                                        inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)
                    }
                }
            }

            try await flush(&batch, into: sink, progress: progress,
                            inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)

            if useTransaction {
                try await sink.commitTransaction()
            }
        } catch {
            if useTransaction {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    Self.logger.warning("Rollback after failed import also failed: \(error.localizedDescription)")
                }
            }
            if error is PluginImportCancellationError { throw error }
            if error is PluginImportError { throw error }
            throw PluginImportError.importFailed(error.localizedDescription)
        }

        progress.finalize()
        return PluginImportResult(
            executedStatements: inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: skipped,
            errors: errors
        )
    }

    private func insert(
        _ row: [String: PluginCellValue],
        into sink: any PluginImportDataSink,
        at line: Int,
        progress: PluginImportProgress,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError],
        maxErrors: Int
    ) async throws {
        do {
            try await sink.insertRow(row)
            inserted += 1
            progress.incrementStatement()
        } catch {
            switch settings.errorHandling {
            case .stopAndRollback, .stopAndCommit:
                throw PluginImportError.statementFailed(statement: "row \(line)", line: line, underlyingError: error)
            case .skipAndContinue:
                skipped += 1
                if errors.count < maxErrors {
                    errors.append(.init(statement: "row \(line)", line: line, errorMessage: error.localizedDescription))
                }
                progress.incrementStatement()
            }
        }
    }

    private func flush(
        _ batch: inout [(line: Int, row: [String: PluginCellValue])],
        into sink: any PluginImportDataSink,
        progress: PluginImportProgress,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError],
        maxErrors: Int
    ) async throws {
        guard !batch.isEmpty else { return }
        let entries = batch
        batch.removeAll(keepingCapacity: true)

        do {
            try await sink.insertRows(entries.map(\.row))
            inserted += entries.count
            progress.incrementStatement(by: entries.count)
        } catch {
            switch settings.errorHandling {
            case .stopAndRollback, .stopAndCommit:
                let firstLine = entries.first?.line ?? 0
                throw PluginImportError.statementFailed(
                    statement: "rows \(firstLine)-\(entries.last?.line ?? firstLine)",
                    line: firstLine,
                    underlyingError: error
                )
            case .skipAndContinue:
                for entry in entries {
                    try await insert(entry.row, into: sink, at: entry.line, progress: progress,
                                     inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)
                }
            }
        }
    }

    // MARK: - Source introspection

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let rows = try JSONImportParsing.sampleRawRows(at: url, targetTable: targetTable, limit: 200)
        return JSONImportParsing.detectFields(in: rows)
    }
}
