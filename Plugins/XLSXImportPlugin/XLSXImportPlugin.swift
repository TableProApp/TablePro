//
//  XLSXImportPlugin.swift
//  XLSXImportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class XLSXImportPlugin: ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "XLSX Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from Excel workbooks"
    static let formatId = "xlsx"
    static let formatDisplayName = "XLSX"
    static let acceptedFileExtensions = ["xlsx"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true

    typealias Settings = XLSXImportOptions
    static let settingsStorageId = "xlsximport"

    private static let batchSize = 500

    /// How many rows are read to guess a column's type in the mapping sheet. The whole sheet is
    /// already in memory by then, so this only bounds the inference work.
    private static let detectionSampleRows = 200

    var settings = XLSXImportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "XLSXImportPlugin")

    required init() { loadSettings() }

    var fieldDetectionSignature: String { settings.detectionSignature }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(XLSXImportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = XLSXImportOptions()
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let sheet = try readSheet(at: url)
        guard let header = sheet.header else { return [] }
        let sample = Array(sheet.rows.prefix(Self.detectionSampleRows))
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
        let sheet = try readSheet(at: source.fileURL())
        guard let header = sheet.header else {
            throw PluginImportError.importFailed(
                String(localized: "The first sheet has no header row to map columns from."))
        }

        progress.setEstimatedTotal(max(1, sheet.rows.count))
        var cursor = 0
        let outcome = try await RowImportRunner.run(
            configuration: RowImportRunner.Configuration(
                errorHandling: settings.errorHandling,
                wrapInTransaction: settings.wrapInTransaction,
                deleteExistingRows: settings.deleteExistingRows
            ),
            sink: sink,
            progress: progress
        ) {
            guard cursor < sheet.rows.count else { return nil }
            let end = min(cursor + Self.batchSize, sheet.rows.count)
            let batch = (cursor ..< end).map { index -> RowImportRunner.Entry in
                /// The line number counts the header, so it matches what the user sees in Excel.
                (line: index + 2, row: self.row(sheet.rows[index], header: header))
            }
            cursor = end
            return batch
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(started),
            skippedStatements: outcome.skipped,
            errors: outcome.errors
        )
    }

    // MARK: - Private

    private struct Sheet {
        let header: [String]?
        let rows: [[String?]]
    }

    private func row(_ values: [String?], header: [String]) -> [String: PluginCellValue] {
        var mapped: [String: PluginCellValue] = [:]
        for (index, column) in header.enumerated() {
            let raw = values[safe: index] ?? nil
            guard let raw else {
                mapped[column] = .null
                continue
            }
            let trimmed = settings.trimWhitespace
                ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                : raw
            if settings.emptyAsNull, trimmed.isEmpty {
                mapped[column] = .null
            } else {
                mapped[column] = .text(trimmed)
            }
        }
        return mapped
    }

    /// The workbook is read whole. A sheet's rows are interleaved with the shared string table it
    /// refers to, so a streaming read would have to hold that table anyway, and the format has no
    /// way to say how large it is before parsing.
    private func readSheet(at url: URL) throws -> Sheet {
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try ZipReader.entries(in: archive)

        guard let worksheetPath = XLSXSheetParser.firstWorksheetPath(in: Array(entries.keys)),
              let worksheet = entries[worksheetPath] else {
            throw XLSXSheetParser.ParseError.noWorksheet
        }

        var strings: [String] = []
        if let sharedEntry = entries["xl/sharedStrings.xml"] {
            strings = XLSXSheetParser.sharedStrings(
                from: try ZipReader.data(for: sharedEntry, in: archive))
        }

        var rows = XLSXSheetParser.rows(
            from: try ZipReader.data(for: worksheet, in: archive),
            sharedStrings: strings
        )

        guard settings.hasHeaderRow else {
            let width = rows.first?.count ?? 0
            return Sheet(
                header: (0 ..< width).map { "column\($0 + 1)" },
                rows: rows
            )
        }
        guard !rows.isEmpty else { return Sheet(header: nil, rows: []) }
        let headerRow = rows.removeFirst()
        let header = headerRow.enumerated().map { index, value -> String in
            let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "column\(index + 1)" : name
        }
        return Sheet(header: header, rows: rows)
    }

    /// Every value arrives as text, so the type is inferred from what the values look like. The
    /// sink casts on the way in, so this only drives what the mapping sheet shows.
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
