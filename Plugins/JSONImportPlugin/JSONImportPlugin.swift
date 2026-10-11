//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

final class JSONImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    @Published var settings = JSONImportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(JSONImportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = JSONImportOptions()
    }

    private static let batchSize = 500
    /// One budget shared with the rows the runner itself recorded, so the two lists together stay
    /// inside the cap the import dialog documents. The skip *count* is deliberately uncapped: a
    /// truncated list must not also under-report how much of the file was left out.
    private static let maxRecordedErrors = 1_000

    private let lineDelimitedFields = JSONFieldDetectionCache()

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()
        let configuration = RowImportRunner.Configuration(
            errorHandling: settings.errorHandling,
            wrapInTransaction: settings.wrapInTransaction,
            deleteExistingRows: settings.deleteExistingRows
        )

        let outcome: RowImportRunner.Outcome
        var unreadableLines: [PluginImportResult.ImportStatementError] = []
        var unreadableLineCount = 0
        if JSONImportParsing.isLineDelimited(url) {
            progress.setEstimatedTotal(max(1, Int(source.fileSizeBytes() / 256)))
            var batches = JSONLineBatches(
                lines: try JSONLineReader(url: url, checkCancellation: progress.checkCancellation),
                linesPerBatch: Self.batchSize,
                skipsUnreadableLines: settings.errorHandling == .skipAndContinue,
                maxRecordedErrors: Self.maxRecordedErrors
            )
            defer { batches.close() }
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                try batches.next()
            }
            unreadableLines = batches.unreadableLines
            unreadableLineCount = batches.unreadableLineCount
        } else {
            let rawRows = try JSONImportParsing.parseRows(at: url, targetTable: sink.targetTable)
            progress.setEstimatedTotal(rawRows.count)
            var cursor = 0
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                guard cursor < rawRows.count else { return nil }
                let end = min(cursor + Self.batchSize, rawRows.count)
                let batch = (cursor..<end).compactMap { index -> RowImportRunner.Entry? in
                    let row = JSONImportParsing.convertRow(rawRows[index])
                    guard !row.isEmpty else { return nil }
                    return (index + 1, row)
                }
                cursor = end
                return batch
            }
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: outcome.skipped + unreadableLineCount,
            errors: Array((outcome.errors + unreadableLines).prefix(Self.maxRecordedErrors))
        )
    }

    // MARK: - Source introspection

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        guard JSONImportParsing.isLineDelimited(url) else {
            return try JSONImportParsing.detectFields(at: url, targetTable: targetTable)
        }
        return try lineDelimitedFields.fields(at: url) {
            try JSONImportParsing.detectFields(inLinesAt: url)
        }
    }
}
