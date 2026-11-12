//
//  XLSXExportPlugin.swift
//  XLSXExportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

final class XLSXExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "XLSX Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Excel format"
    static let formatId = "xlsx"
    static let formatDisplayName = "XLSX"
    static let defaultFileExtension = "xlsx"
    static let iconName = "tablecells"

    typealias Settings = XLSXExportOptions
    static let settingsStorageId = "xlsx"

    @Published var settings = XLSXExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(XLSXExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = XLSXExportOptions()
    }

    private static let maxRowsPerSheet = 1_048_576

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        // One plugin instance serves every window, so a dialog in another window can change `settings` mid-export.
        let options = settings
        let writer = XLSXWriter(databaseTypeId: dataSource.databaseTypeId)
        var didSplitSheets = false

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            var isFirstBatch = true
            var rowBatch: [[PluginCellValue]] = []
            var columns: [String] = []
            var columnTypeNames: [String] = []
            var sheetRows = XLSXSheetRows(limit: Self.maxRowsPerSheet, headerRowCount: options.includeHeaderRow ? 1 : 0)

            func writeBatch() throws {
                for chunk in sheetRows.chunks(of: rowBatch.count) {
                    if chunk.startsNewSheet {
                        try writer.continueSheet(
                            baseName: table.name,
                            columns: columns,
                            columnTypeNames: columnTypeNames,
                            includeHeader: options.includeHeaderRow,
                            convertNullToEmpty: options.convertNullToEmpty
                        )
                        didSplitSheets = true
                    }
                    try autoreleasepool {
                        try writer.addRows(Array(rowBatch[chunk.rows]), convertNullToEmpty: options.convertNullToEmpty)
                    }
                }
                for _ in 0..<rowBatch.count {
                    progress.incrementRow()
                }
                rowBatch.removeAll(keepingCapacity: true)
            }

            let stream = dataSource.streamRows(for: table)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns
                    columnTypeNames = header.columnTypeNames
                    try writer.beginSheet(
                        name: table.name,
                        columns: columns,
                        columnTypeNames: columnTypeNames,
                        includeHeader: options.includeHeaderRow,
                        convertNullToEmpty: options.convertNullToEmpty
                    )
                    sheetRows = XLSXSheetRows(limit: Self.maxRowsPerSheet, headerRowCount: options.includeHeaderRow ? 1 : 0)
                    isFirstBatch = false
                case .rows(let rows):
                    rowBatch.append(contentsOf: rows)
                    if rowBatch.count >= 5_000 {
                        try writeBatch()
                    }
                }
            }

            if !rowBatch.isEmpty {
                try writeBatch()
            }

            if !isFirstBatch {
                try writer.finishSheet()
            } else {
                try writer.beginSheet(
                    name: table.name,
                    columns: [],
                    includeHeader: false,
                    convertNullToEmpty: options.convertNullToEmpty
                )
                try writer.finishSheet()
            }
        }

        try await writer.write(to: destination)

        progress.finalizeTable()

        var warnings: [String] = []
        if didSplitSheets {
            warnings.append("Data exceeded Excel's row limit (1,048,576) and was split across multiple sheets.")
        }
        return ExportFormatResult(warnings: warnings)
    }
}
