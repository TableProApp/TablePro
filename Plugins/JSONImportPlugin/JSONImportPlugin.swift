//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class JSONImportPlugin: ImportFormatPlugin, SettablePlugin {
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

    func resetSettingsToDefaults() {
        settings = JSONImportOptions()
    }

    private static let batchSize = 500

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
        if JSONImportParsing.isLineDelimited(url) {
            progress.setEstimatedTotal(max(1, Int(source.fileSizeBytes() / 256)))
            var lines = url.lines.makeAsyncIterator()
            var lineNumber = 0
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                var batch: [RowImportRunner.Entry] = []
                while batch.count < Self.batchSize, let line = try await lines.next() {
                    lineNumber += 1
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    batch.append((lineNumber, try JSONImportParsing.parseRow(fromLine: trimmed)))
                }
                return batch.isEmpty ? nil : batch
            }
        } else {
            let rawRows = try JSONImportParsing.parseRows(at: url, targetTable: sink.targetTable)
            progress.setEstimatedTotal(rawRows.count)
            var cursor = 0
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                guard cursor < rawRows.count else { return nil }
                let end = min(cursor + Self.batchSize, rawRows.count)
                let batch = (cursor..<end).map { index in
                    (index + 1, JSONImportParsing.convertRow(rawRows[index]))
                }
                cursor = end
                return batch
            }
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: outcome.skipped,
            errors: outcome.errors
        )
    }

    // MARK: - Source introspection

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let rows = try JSONImportParsing.sampleRawRows(at: url, targetTable: targetTable, limit: 200)
        return JSONImportParsing.detectFields(in: rows)
    }
}
