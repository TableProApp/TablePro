//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Combine
import Foundation
import TableProPluginKit

nonisolated final class JSONImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = JSONImportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    var rowImportConfiguration: RowImportRunner.Configuration? { Self.runConfiguration(settings) }

    private static func runConfiguration(_ options: JSONImportOptions) -> RowImportRunner.Configuration {
        RowImportRunner.Configuration(
            errorHandling: options.errorHandling,
            wrapInTransaction: options.wrapInTransaction,
            deleteExistingRows: options.deleteExistingRows
        )
    }

    func resetSettingsToDefaults() {
        settings = JSONImportOptions()
    }

    private static let batchSize = 500
    // One budget shared with the rows the runner itself recorded, so the two lists together stay
    // inside the cap the import dialog documents. The skip count is uncapped: a truncated list must
    // not also under-report how much of the file was left out.
    private static let maxRecordedErrors = 1_000

    private let lineDelimitedFields = JSONFieldDetectionCache()

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()
        // One plugin instance serves every window, so a dialog in another window can change `settings` mid-import.
        let options = settings
        let configuration = Self.runConfiguration(options)

        let outcome: RowImportRunner.Outcome
        var unreadableLines: [PluginImportResult.ImportStatementError] = []
        var unreadableLineCount = 0
        if JSONImportParsing.isLineDelimited(url) {
            progress.setEstimatedTotal(max(1, Int(source.fileSizeBytes() / 256)))
            var batches = JSONLineBatches(
                lines: try JSONLineReader(url: url, checkCancellation: progress.checkCancellation),
                linesPerBatch: Self.batchSize,
                skipsUnreadableLines: options.errorHandling == .skipAndContinue,
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
            let document = try JSONImportParsing.rowElements(
                at: url, targetTable: sink.targetTable, checkCancellation: progress.checkCancellation
            )
            progress.setEstimatedTotal(document.count)
            var batches = JSONElementBatches(
                elements: document.elements,
                elementsPerBatch: Self.batchSize,
                skipsUnreadableElements: options.errorHandling == .skipAndContinue,
                maxRecordedErrors: Self.maxRecordedErrors
            )
            defer { batches.close() }
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                try batches.next()
            }
            unreadableLines = batches.unreadableElements
            unreadableLineCount = batches.unreadableElementCount
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
