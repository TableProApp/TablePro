//
//  HTMLExportPlugin.swift
//  HTMLExportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class HTMLExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "HTML Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to an HTML table"
    static let formatId = "html"
    static let formatDisplayName = "HTML"
    static let defaultFileExtension = "html"
    static let iconName = "chevron.left.forwardslash.chevron.right"

    typealias Settings = HTMLExportOptions
    static let settingsStorageId = "html"

    var settings = HTMLExportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "HTMLExportPlugin")

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(HTMLExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = HTMLExportOptions()
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

        if settings.writesFullDocument {
            try fileHandle.write(contentsOf: Self.documentHeader.toUTF8Data())
        }

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            if settings.includesTableNames {
                try fileHandle.write(
                    contentsOf: "<h2>\(HTMLEscaping.text(table.qualifiedName))</h2>\n".toUTF8Data())
            }
            try await writeTable(table, dataSource: dataSource, to: fileHandle, progress: progress)
        }

        if settings.writesFullDocument {
            try fileHandle.write(contentsOf: Self.documentFooter.toUTF8Data())
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
        try fileHandle.write(contentsOf: "<table>\n".toUTF8Data())
        var wroteHeader = false
        var wroteBody = false

        for try await element in dataSource.streamRows(for: table) {
            try progress.checkCancellation()
            switch element {
            case .header(let header):
                let cells = header.columns
                    .map { "<th>\(HTMLEscaping.text($0))</th>" }
                    .joined()
                try fileHandle.write(contentsOf: "<thead><tr>\(cells)</tr></thead>\n".toUTF8Data())
                wroteHeader = true
            case .rows(let rows):
                if !wroteBody {
                    try fileHandle.write(contentsOf: "<tbody>\n".toUTF8Data())
                    wroteBody = true
                }
                for row in rows {
                    let cells = row.map { cellMarkup($0) }.joined()
                    try fileHandle.write(contentsOf: "<tr>\(cells)</tr>\n".toUTF8Data())
                    progress.incrementRow()
                }
            }
        }

        if wroteBody {
            try fileHandle.write(contentsOf: "</tbody>\n".toUTF8Data())
        }
        if !wroteHeader, !wroteBody {
            try fileHandle.write(contentsOf: "<tbody></tbody>\n".toUTF8Data())
        }
        try fileHandle.write(contentsOf: "</table>\n".toUTF8Data())
    }

    private func cellMarkup(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return settings.marksNulls ? "<td class=\"null\">NULL</td>" : "<td></td>"
        case .bytes(let data):
            return "<td>0x\(data.map { String(format: "%02X", $0) }.joined())</td>"
        case .text(let text):
            return "<td>\(HTMLEscaping.text(text))</td>"
        }
    }

    /// `charset` first, because a browser that guesses an encoding before reaching it renders every
    /// non-ASCII value wrong. The stylesheet is inline so the file is one thing the user can send.
    private static let documentHeader = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Export</title>
        <style>
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 24px; color: #1d1d1f; }
        h2 { font-size: 15px; margin: 24px 0 8px; }
        table { border-collapse: collapse; margin-bottom: 24px; }
        th, td { border: 1px solid #d2d2d7; padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; font-weight: 600; }
        td.null { color: #86868b; font-style: italic; }
        @media (prefers-color-scheme: dark) {
          body { background: #1d1d1f; color: #f5f5f7; }
          th, td { border-color: #424245; }
          th { background: #2c2c2e; }
          td.null { color: #98989d; }
        }
        </style>
        </head>
        <body>

        """

    private static let documentFooter = """
        </body>
        </html>

        """
}
