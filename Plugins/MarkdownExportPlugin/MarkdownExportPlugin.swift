//
//  MarkdownExportPlugin.swift
//  MarkdownExportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class MarkdownExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "Markdown Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Markdown tables"
    static let formatId = "md"
    static let formatDisplayName = "Markdown"
    static let defaultFileExtension = "md"
    static let iconName = "text.alignleft"

    typealias Settings = MarkdownExportOptions
    static let settingsStorageId = "md"

    /// The widths are taken from the header and the first page of rows. Reading every row first
    /// would mean holding the whole table in memory to decide a column width.
    private static let alignmentSampleRows = 200

    var settings = MarkdownExportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MarkdownExportPlugin")

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(MarkdownExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = MarkdownExportOptions()
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed { PluginExportUtilities.rollbackAtomicWrite(at: tempURL) }
        }

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            if settings.includesTableNames {
                try fileHandle.write(contentsOf: "## \(table.qualifiedName)\n\n".toUTF8Data())
            }
            try await writeTable(table, dataSource: dataSource, to: fileHandle, progress: progress)
            try fileHandle.write(contentsOf: "\n".toUTF8Data())
        }

        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    private func writeTable(
        _ table: PluginExportTable,
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) async throws {
        var columns: [String] = []
        var buffered: [[String]] = []
        var widths: [Int]?
        var wroteHeader = false

        for try await element in dataSource.streamRows(for: table) {
            try progress.checkCancellation()
            switch element {
            case .header(let header):
                columns = header.columns
            case .rows(let rows):
                for row in rows {
                    let cells = row.map { cellText($0) }
                    progress.incrementRow()
                    guard settings.alignsColumns, !wroteHeader else {
                        if !wroteHeader {
                            try writeHeader(columns, widths: nil, to: fileHandle)
                            wroteHeader = true
                        }
                        try fileHandle.write(
                            contentsOf: (MarkdownTableRenderer.row(cells, widths: widths) + "\n").toUTF8Data())
                        continue
                    }
                    buffered.append(cells)
                    guard buffered.count >= Self.alignmentSampleRows else { continue }
                    widths = MarkdownTableRenderer.widths(header: columns, sample: buffered)
                    try writeHeader(columns, widths: widths, to: fileHandle)
                    wroteHeader = true
                    for buffedRow in buffered {
                        try fileHandle.write(
                            contentsOf: (MarkdownTableRenderer.row(buffedRow, widths: widths) + "\n").toUTF8Data())
                    }
                    buffered.removeAll(keepingCapacity: true)
                }
            }
        }

        if !wroteHeader {
            widths = settings.alignsColumns
                ? MarkdownTableRenderer.widths(header: columns, sample: buffered)
                : nil
            try writeHeader(columns, widths: widths, to: fileHandle)
        }
        for row in buffered {
            try fileHandle.write(
                contentsOf: (MarkdownTableRenderer.row(row, widths: widths) + "\n").toUTF8Data())
        }
    }

    private func writeHeader(
        _ columns: [String],
        widths: [Int]?,
        to fileHandle: FileHandle
    ) throws {
        let header = columns.map { MarkdownTableRenderer.cell($0) }
        try fileHandle.write(contentsOf: (MarkdownTableRenderer.row(header, widths: widths) + "\n").toUTF8Data())
        try fileHandle.write(contentsOf: (
            MarkdownTableRenderer.separator(columnCount: columns.count, widths: widths) + "\n"
        ).toUTF8Data())
    }

    private func cellText(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return MarkdownTableRenderer.cell(settings.nullPlaceholder)
        case .bytes(let data):
            return MarkdownTableRenderer.cell("0x\(data.map { String(format: "%02X", $0) }.joined())")
        case .text(let text):
            return MarkdownTableRenderer.cell(text)
        }
    }
}
