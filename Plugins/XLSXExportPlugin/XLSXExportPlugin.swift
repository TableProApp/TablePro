//
//  XLSXExportPlugin.swift
//  XLSXExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class XLSXExportPlugin: ExportFormatPlugin, SettablePlugin {
    static let pluginName = "XLSX Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Excel format"
    static let formatId = "xlsx"
    static let formatDisplayName = "XLSX"
    static let defaultFileExtension = "xlsx"
    static let iconName = "tablecells"

    typealias Settings = XLSXExportOptions
    static let settingsStorageId = "xlsx"

    var settings = XLSXExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(XLSXExportOptionsView(plugin: self))
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let writer = XLSXWriter()

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            var isFirstBatch = true
            var rowBatch: [[String?]] = []

            let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    writer.beginSheet(
                        name: table.name,
                        columns: header.columns,
                        includeHeader: settings.includeHeaderRow,
                        convertNullToEmpty: settings.convertNullToEmpty
                    )
                    isFirstBatch = false
                case .row(let row):
                    rowBatch.append(row)
                    if rowBatch.count >= 5_000 {
                        autoreleasepool {
                            writer.addRows(rowBatch, convertNullToEmpty: settings.convertNullToEmpty)
                        }
                        for _ in rowBatch {
                            progress.incrementRow()
                        }
                        rowBatch.removeAll(keepingCapacity: true)
                    }
                }
            }

            if !rowBatch.isEmpty {
                autoreleasepool {
                    writer.addRows(rowBatch, convertNullToEmpty: settings.convertNullToEmpty)
                }
                for _ in rowBatch {
                    progress.incrementRow()
                }
            }

            if !isFirstBatch {
                writer.finishSheet()
            } else {
                writer.beginSheet(
                    name: table.name,
                    columns: [],
                    includeHeader: false,
                    convertNullToEmpty: settings.convertNullToEmpty
                )
                writer.finishSheet()
            }

            progress.finalizeTable()
        }

        try await Task.detached(priority: .userInitiated) {
            try writer.write(to: destination)
        }.value
        return ExportFormatResult()
    }
}
