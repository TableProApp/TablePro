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

    private static let maxRowsPerSheet = 1_048_576

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let writer = XLSXWriter()
        var didSplitSheets = false

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            var isFirstBatch = true
            var rowBatch: [[String?]] = []
            var currentSheetRowCount = 0
            var columns: [String] = []
            let headerRowCount = settings.includeHeaderRow ? 1 : 0

            let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns
                    writer.beginSheet(
                        name: table.name,
                        columns: columns,
                        includeHeader: settings.includeHeaderRow,
                        convertNullToEmpty: settings.convertNullToEmpty
                    )
                    currentSheetRowCount = headerRowCount
                    isFirstBatch = false
                case .rows(let rows):
                    for row in rows {
                        rowBatch.append(row)
                    }
                    if rowBatch.count >= 5_000 {
                        let remaining = Self.maxRowsPerSheet - currentSheetRowCount
                        if rowBatch.count <= remaining {
                            autoreleasepool {
                                writer.addRows(rowBatch, convertNullToEmpty: settings.convertNullToEmpty)
                            }
                            currentSheetRowCount += rowBatch.count
                        } else {
                            let fitting = Array(rowBatch.prefix(remaining))
                            let overflow = Array(rowBatch.dropFirst(remaining))
                            if !fitting.isEmpty {
                                autoreleasepool {
                                    writer.addRows(fitting, convertNullToEmpty: settings.convertNullToEmpty)
                                }
                                currentSheetRowCount += fitting.count
                            }
                            writer.continueSheet(
                                baseName: table.name,
                                columns: columns,
                                includeHeader: settings.includeHeaderRow,
                                convertNullToEmpty: settings.convertNullToEmpty
                            )
                            didSplitSheets = true
                            currentSheetRowCount = headerRowCount
                            if !overflow.isEmpty {
                                autoreleasepool {
                                    writer.addRows(overflow, convertNullToEmpty: settings.convertNullToEmpty)
                                }
                                currentSheetRowCount += overflow.count
                            }
                        }
                        for _ in rowBatch {
                            progress.incrementRow()
                        }
                        rowBatch.removeAll(keepingCapacity: true)
                    }
                }
            }

            if !rowBatch.isEmpty {
                let remaining = Self.maxRowsPerSheet - currentSheetRowCount
                if rowBatch.count <= remaining {
                    autoreleasepool {
                        writer.addRows(rowBatch, convertNullToEmpty: settings.convertNullToEmpty)
                    }
                    currentSheetRowCount += rowBatch.count
                } else {
                    let fitting = Array(rowBatch.prefix(remaining))
                    let overflow = Array(rowBatch.dropFirst(remaining))
                    if !fitting.isEmpty {
                        autoreleasepool {
                            writer.addRows(fitting, convertNullToEmpty: settings.convertNullToEmpty)
                        }
                    }
                    writer.continueSheet(
                        baseName: table.name,
                        columns: columns,
                        includeHeader: settings.includeHeaderRow,
                        convertNullToEmpty: settings.convertNullToEmpty
                    )
                    didSplitSheets = true
                    currentSheetRowCount = headerRowCount
                    if !overflow.isEmpty {
                        autoreleasepool {
                            writer.addRows(overflow, convertNullToEmpty: settings.convertNullToEmpty)
                        }
                        currentSheetRowCount += overflow.count
                    }
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

        }

        try await Task.detached(priority: .userInitiated) {
            try writer.write(to: destination)
        }.value

        progress.finalizeTable()

        var warnings: [String] = []
        if didSplitSheets {
            warnings.append("Data exceeded Excel's row limit (1,048,576) and was split across multiple sheets.")
        }
        return ExportFormatResult(warnings: warnings)
    }
}
