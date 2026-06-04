//
//  CSVImportPlugin.swift
//  CSVImportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class CSVImportPlugin: ImportFormatPlugin, SettablePlugin {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CSVImportPlugin")

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
    private static let maxErrors = 1_000

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()
        let useTransaction = settings.wrapInTransaction && settings.errorHandling != .skipAndContinue

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

        var inserted = 0
        var skipped = 0
        var errors: [PluginImportResult.ImportStatementError] = []

        do {
            if settings.deleteExistingRows {
                try await sink.deleteAllRowsFromTargetTable()
            }
            if useTransaction {
                try await sink.beginTransaction()
            }

            let lineOffset = hasHeader ? 2 : 1
            var index = 0
            while index < dataRanges.count {
                try progress.checkCancellation()
                let end = min(index + Self.batchSize, dataRanges.count)
                let batch = parseBatch(
                    in: data,
                    parser: parser,
                    ranges: dataRanges[index..<end],
                    startIndex: index,
                    lineOffset: lineOffset,
                    columnNames: columnNames
                )
                index = end
                try await flush(batch, into: sink, progress: progress,
                                inserted: &inserted, skipped: &skipped, errors: &errors)
            }

            if useTransaction {
                try await sink.commitTransaction()
            }
        } catch {
            if useTransaction {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    Self.logger.warning("Rollback after failed import also failed: \(error.localizedDescription)")
                }
            }
            if error is PluginImportCancellationError { throw error }
            if error is PluginImportError { throw error }
            throw PluginImportError.importFailed(error.localizedDescription)
        }

        progress.finalize()
        return PluginImportResult(
            executedStatements: inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: skipped,
            errors: errors
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

    private func flush(
        _ batch: [(line: Int, row: [String: PluginCellValue])],
        into sink: any PluginImportDataSink,
        progress: PluginImportProgress,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError]
    ) async throws {
        guard !batch.isEmpty else { return }
        do {
            try await sink.insertRows(batch.map(\.row))
            inserted += batch.count
            progress.incrementStatement(by: batch.count)
        } catch {
            switch settings.errorHandling {
            case .stopAndRollback, .stopAndCommit:
                let firstLine = batch.first?.line ?? 0
                throw PluginImportError.statementFailed(
                    statement: "rows \(firstLine)-\(batch.last?.line ?? firstLine)",
                    line: firstLine,
                    underlyingError: error
                )
            case .skipAndContinue:
                for entry in batch {
                    try await insert(entry.row, into: sink, at: entry.line, progress: progress,
                                     inserted: &inserted, skipped: &skipped, errors: &errors)
                }
            }
        }
    }

    private func insert(
        _ row: [String: PluginCellValue],
        into sink: any PluginImportDataSink,
        at line: Int,
        progress: PluginImportProgress,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError]
    ) async throws {
        do {
            try await sink.insertRow(row)
            inserted += 1
            progress.incrementStatement()
        } catch {
            switch settings.errorHandling {
            case .stopAndRollback, .stopAndCommit:
                throw PluginImportError.statementFailed(statement: "row \(line)", line: line, underlyingError: error)
            case .skipAndContinue:
                skipped += 1
                if errors.count < Self.maxErrors {
                    errors.append(.init(statement: "row \(line)", line: line, errorMessage: error.localizedDescription))
                }
                progress.incrementStatement()
            }
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
