//
//  ParquetExportPlugin.swift
//  ParquetExportPlugin
//

import CDuckDB
import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit

/// Writes Parquet by staging rows in an in-memory DuckDB and letting it do the encoding.
///
/// Parquet is not a text format: it is Thrift-encoded metadata over dictionary and RLE encoded
/// column chunks, with per-column compression. Hand-writing that means owning an encoder whose
/// correctness nothing local can check. DuckDB already ships one that every Parquet reader agrees
/// with, and the library is already built for this app.
final class ParquetExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "Parquet Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Apache Parquet"
    static let formatId = "parquet"
    static let formatDisplayName = "Parquet"
    static let defaultFileExtension = "parquet"
    static let iconName = "square.grid.3x3"

    /// Parquet holds one table per file, so a multi-table export writes one file each rather than
    /// concatenating tables into something no reader would understand.
    static let supportedObjectKinds: [PluginExportObjectKind] = [.table, .foreignTable, .view, .materializedView]

    typealias Settings = ParquetExportOptions
    static let settingsStorageId = "parquet"

    // Bounds how many rows are held in Swift between appender flushes.
    private static let stagingBatchSize = 2_000

    @Published var settings = ParquetExportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ParquetExportPlugin")

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(ParquetExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = ParquetExportOptions()
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        guard !tables.isEmpty else { return ExportFormatResult() }
        var warnings: [String] = []

        try await ParquetTableFiles.write(tables, destination: destination, progress: progress) { table, fileURL in
            warnings += try await writeTable(table, dataSource: dataSource, to: fileURL, progress: progress)
        }

        if tables.count > 1 {
            warnings.append(String(
                format: String(localized: "Parquet holds one table per file, so %lld files were written."),
                Int64(tables.count)))
        }
        progress.finalizeTable()
        return ExportFormatResult(warnings: warnings)
    }

    private func writeTable(
        _ table: PluginExportTable,
        dataSource: any PluginExportDataSource,
        to fileURL: URL,
        progress: PluginExportProgress
    ) async throws -> [String] {
        let columnInfo = (try? await dataSource.fetchColumns(
            table: table.name, databaseName: table.databaseName)) ?? []
        let declaredTypes = Dictionary(
            columnInfo.map { ($0.name, $0.typeNameForClassification) }, uniquingKeysWith: { first, _ in first })

        let staging = try DuckDBStagingDatabase()
        var columns: [String] = []
        var batch: [[PluginCellValue]] = []
        var created = false

        for try await element in dataSource.streamRows(for: table) {
            try progress.checkCancellation()
            switch element {
            case .header(let header):
                columns = header.columns
                let types = columns.enumerated().map { index, column in
                    let streamed = index < header.columnTypeNames.count ? header.columnTypeNames[index] : ""
                    return ParquetTypeMapper.duckDBType(
                        forColumnType: declaredTypes[column] ?? streamed, databaseTypeId: dataSource.databaseTypeId)
                }
                try staging.createTable(columns: columns, types: types)
                created = true
            case .rows(let rows):
                guard created else { continue }
                for row in rows {
                    batch.append(row)
                    progress.incrementRow()
                    guard batch.count >= Self.stagingBatchSize else { continue }
                    try staging.insert(rows: batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }

        guard created else {
            throw PluginExportError.exportFailed(
                String(format: String(localized: "%@ returned no columns."), table.name))
        }
        if !batch.isEmpty {
            try staging.insert(rows: batch)
        }
        let fallbacks = try staging.copyToParquet(
            fileURL: fileURL,
            compression: settings.compression.duckDBValue,
            rowGroupSize: settings.rowGroupSize
        )
        return fallbacks.map { fallback in
            String(
                format: String(localized: "%1$@.%2$@ was written as text: %3$lld values do not fit %4$@."),
                table.name, fallback.column, Int64(fallback.valueCount), fallback.type)
        }
    }
}
