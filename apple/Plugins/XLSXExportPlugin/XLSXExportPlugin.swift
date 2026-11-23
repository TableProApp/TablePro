//
//  XLSXExportPlugin.swift
//  XLSXExportPlugin
//

import Combine
import Foundation
import TableProPluginKit

nonisolated final class XLSXExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "XLSX Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Excel format"
    static let formatId = "xlsx"
    static let formatDisplayName = "XLSX"
    static let defaultFileExtension = "xlsx"
    static let iconName = "tablecells"

    typealias Settings = XLSXExportOptions
    static let settingsStorageId = "xlsx"

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = XLSXExportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

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
            var columns: [String] = []
            var columnTypeNames: [String] = []
            var sheetRows = XLSXSheetRows(limit: Self.maxRowsPerSheet, headerRowCount: options.includeHeaderRow ? 1 : 0)

            // Each batch is written as it arrives: the stream already bounds a batch by rows and bytes, and the
            // writer keeps at most one flush of XML, so holding rows here would only add to both.
            func writeBatch(_ rowBatch: [[PluginCellValue]]) throws {
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
                    try writeBatch(rows)
                }
            }

            // The stream's own checks end with its last element.
            try progress.checkCancellation()

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

        try await writer.write(to: destination, progress: progress)

        progress.finalizeTable()

        var warnings: [String] = []
        if didSplitSheets {
            warnings.append("Data exceeded Excel's row limit (1,048,576) and was split across multiple sheets.")
        }
        return ExportFormatResult(warnings: warnings)
    }
}
