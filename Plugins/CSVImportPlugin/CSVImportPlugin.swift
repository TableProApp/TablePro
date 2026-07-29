//
//  CSVImportPlugin.swift
//  CSVImportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class CSVImportPlugin: ImportFormatPlugin, SettablePlugin {
    static let pluginName = "CSV Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from CSV and TSV files"
    static let formatId = "csv"
    static let formatDisplayName = "CSV"
    static let acceptedFileExtensions = ["csv", "tsv"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true

    typealias Settings = CSVImportOptions
    static let settingsStorageId = "csv-import"

    var settings = CSVImportOptions() {
        didSet { saveSettings() }
    }

    var fieldDetectionSignature: String { settings.detectionSignature }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(CSVImportOptionsView(plugin: self))
    }

    private static let detectionPrefixBytes = 1_048_576
    private static let batchSize = 500

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PluginImportError.importFailed(error.localizedDescription)
        }

        let dialect = CSVImportParsing.resolveDialect(in: data, options: settings)
        let parser = CSVStreamingParser(dialect: dialect)
        let hasHeader = settings.hasHeaderRow

        let (dataRanges, columnNames) = indexRowsAndNames(in: data, parser: parser, hasHeader: hasHeader)
        guard !columnNames.isEmpty else {
            throw PluginImportError.importFailed("No columns found in the file")
        }

        progress.setEstimatedTotal(dataRanges.count)

        let lineOffset = hasHeader ? 2 : 1
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
            guard cursor < dataRanges.count else { return nil }
            let end = min(cursor + Self.batchSize, dataRanges.count)
            let batch = self.parseBatch(
                in: data,
                parser: parser,
                ranges: dataRanges[cursor..<end],
                startIndex: cursor,
                lineOffset: lineOffset,
                columnNames: columnNames
            )
            let blankRows = (end - cursor) - batch.count
            if blankRows > 0 {
                progress.incrementStatement(by: blankRows)
            }
            cursor = end
            return batch
        }

        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: outcome.skipped,
            errors: outcome.errors
        )
    }

    private func indexRowsAndNames(
        in data: Data,
        parser: CSVStreamingParser,
        hasHeader: Bool
    ) -> ([Range<Int>], [String]) {
        data.withUnsafeBytes { raw -> ([Range<Int>], [String]) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return ([], []) }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)
            let ranges = parser.indexRows(buffer)
            guard !ranges.isEmpty else { return ([], []) }
            if hasHeader {
                let header = parser.parseRow(buffer, range: ranges[0])
                let names = CSVImportParsing.columnNames(header: header, columnCount: header.count)
                return (Array(ranges.dropFirst()), names)
            }
            let firstCount = parser.parseRow(buffer, range: ranges[0]).count
            let names = CSVImportParsing.columnNames(header: nil, columnCount: firstCount)
            return (ranges, names)
        }
    }

    private func parseBatch(
        in data: Data,
        parser: CSVStreamingParser,
        ranges: ArraySlice<Range<Int>>,
        startIndex: Int,
        lineOffset: Int,
        columnNames: [String]
    ) -> [(line: Int, row: [String: PluginCellValue])] {
        data.withUnsafeBytes { raw -> [(line: Int, row: [String: PluginCellValue])] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)
            var out: [(line: Int, row: [String: PluginCellValue])] = []
            out.reserveCapacity(ranges.count)
            for (offset, range) in ranges.enumerated() {
                let fields = parser.parseRow(buffer, range: range)
                if CSVImportParsing.isBlank(fields) { continue }
                let line = startIndex + offset + lineOffset
                out.append((line, CSVImportParsing.row(fields: fields, columnNames: columnNames, options: settings)))
            }
            return out
        }
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let data = try readDetectionPrefix(of: url)
        return CSVImportParsing.detectFields(in: data, options: settings)
    }

    private func readDetectionPrefix(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return handle.readData(ofLength: Self.detectionPrefixBytes)
    }
}
