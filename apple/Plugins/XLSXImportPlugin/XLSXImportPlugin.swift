//
//  XLSXImportPlugin.swift
//  XLSXImportPlugin
//

import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit
import TableProTabularIO

final class XLSXImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "XLSX Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from Excel workbooks"
    static let formatId = "xlsx"
    static let formatDisplayName = "XLSX"
    static let acceptedFileExtensions = ["xlsx"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true
    static let sourceFieldsFollowFileOrder = true

    typealias Settings = XLSXImportOptions
    static let settingsStorageId = "xlsximport"

    private static let batchSize = 500

    // The whole sheet is already in memory, so this bounds only the type guess for the mapping sheet.
    private static let detectionSampleRows = 200

    @Published var settings = XLSXImportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "XLSXImportPlugin")

    required init() { loadSettings() }

    var fieldDetectionSignature: String { settings.detectionSignature }

    var rowImportConfiguration: RowImportRunner.Configuration? { Self.runConfiguration(settings) }

    private static func runConfiguration(_ options: XLSXImportOptions) -> RowImportRunner.Configuration {
        RowImportRunner.Configuration(
            errorHandling: options.errorHandling,
            wrapInTransaction: options.wrapInTransaction,
            deleteExistingRows: options.deleteExistingRows
        )
    }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(XLSXImportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = XLSXImportOptions()
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let sheet = try XLSXImportSheet.read(at: url, hasHeaderRow: settings.hasHeaderRow, isCancelled: { Task.isCancelled })
        guard let header = sheet.header else { return [] }
        let sample = sheet.rows(0 ..< Self.detectionSampleRows).map(\.values)
        return header.enumerated().map { index, name in
            let values = sample.compactMap { $0[safe: index] ?? nil }
            return PluginImportField(
                name: name,
                sampleValue: values.first,
                inferredType: Self.inferType(from: values)
            )
        }
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let started = Date()
        // One plugin instance serves every window, so a dialog in another window can change `settings` mid-import.
        let options = settings
        let sheet: XLSXImportSheet
        do {
            sheet = try XLSXImportSheet.read(
                at: source.fileURL(),
                hasHeaderRow: options.hasHeaderRow,
                isCancelled: { progress.isCancelled }
            )
        } catch is TabularCancellation {
            throw PluginImportCancellationError()
        }
        guard let header = sheet.header else {
            throw PluginImportError.importFailed(
                String(localized: "The first sheet has no header row to map columns from."))
        }

        progress.setEstimatedTotal(max(1, sheet.rowCount))
        var cursor = 0
        let outcome = try await RowImportRunner.run(
            configuration: Self.runConfiguration(options),
            sink: sink,
            progress: progress
        ) {
            guard cursor < sheet.rowCount else { return nil }
            let end = min(cursor + Self.batchSize, sheet.rowCount)
            let rows = sheet.rows(cursor ..< end)
            cursor = end
            let filled = rows.filter { $0.values.contains { $0 != nil } }
            if filled.count < rows.count {
                progress.incrementStatement(by: rows.count - filled.count)
            }
            return filled.map { (line: $0.line, row: Self.row($0.values, header: header, options: options)) }
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(started),
            skippedStatements: outcome.skipped,
            errors: outcome.errors
        )
    }

    // MARK: - Private

    private static func row(_ values: [String?], header: [String], options: XLSXImportOptions) -> [String: PluginCellValue] {
        var mapped: [String: PluginCellValue] = [:]
        for (index, column) in header.enumerated() {
            let raw = values[safe: index] ?? nil
            guard let raw else {
                mapped[column] = .null
                continue
            }
            let trimmed = options.trimWhitespace
                ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                : raw
            if options.emptyAsNull, trimmed.isEmpty {
                mapped[column] = .null
            } else {
                mapped[column] = .text(trimmed)
            }
        }
        return mapped
    }

    // The sink casts on the way in, so the guess only drives what the mapping sheet shows.
    static func inferType(from values: [String]) -> PluginImportFieldType {
        let candidates = values.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return .text }
        if candidates.allSatisfy({ Int($0) != nil }) { return .integer }
        if candidates.allSatisfy({ Double($0) != nil }) { return .real }
        let booleans: Set<String> = ["true", "false", "0", "1", "yes", "no"]
        if candidates.allSatisfy({ booleans.contains($0.lowercased()) }) { return .boolean }
        if candidates.allSatisfy({ $0.hasPrefix("{") || $0.hasPrefix("[") }) { return .json }
        return .text
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
