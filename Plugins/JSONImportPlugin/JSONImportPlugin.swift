//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class JSONImportPlugin: ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
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
            var lines = url.lines.makeAsyncIterator()
            var lineNumber = 0
            let skipsErrors = settings.errorHandling == .skipAndContinue
            outcome = try await RowImportRunner.run(
                configuration: configuration, sink: sink, progress: progress
            ) {
                var batch: [RowImportRunner.Entry] = []
                while batch.count < Self.batchSize, let line = try await lines.next() {
                    lineNumber += 1
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    do {
                        let row = try JSONImportParsing.parseRow(fromLine: trimmed)
                        guard !row.isEmpty else { continue }
                        batch.append((lineNumber, row))
                    } catch {
                        guard skipsErrors else { throw error }
                        unreadableLineCount += 1
                        if unreadableLines.count < Self.maxRecordedErrors {
                            unreadableLines.append(.init(
                                statement: "row \(lineNumber)",
                                line: lineNumber,
                                errorMessage: error.localizedDescription
                            ))
                        }
                    }
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
        let rows = try JSONImportParsing.sampleRawRows(at: url, targetTable: targetTable, limit: 200)
        return JSONImportParsing.detectFields(in: rows)
    }
}
