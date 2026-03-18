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
    ) async throws {
        let writer = XLSXWriter()

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            let batchSize = 5_000
            var offset = 0
            var columns: [String] = []
            var isFirstBatch = true

            while true {
                try progress.checkCancellation()

                let result = try await dataSource.fetchRows(
                    table: table.name,
                    databaseName: table.databaseName,
                    offset: offset,
                    limit: batchSize
                )

                if result.rows.isEmpty { break }

                if isFirstBatch {
                    columns = result.columns
                    writer.beginSheet(
                        name: table.name,
                        columns: columns,
                        includeHeader: settings.includeHeaderRow,
                        convertNullToEmpty: settings.convertNullToEmpty
                    )
                    isFirstBatch = false
                }

                autoreleasepool {
                    writer.addRows(result.rows, convertNullToEmpty: settings.convertNullToEmpty)
                }

                for _ in result.rows {
                    progress.incrementRow()
                }

                offset += batchSize
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
    }
}
