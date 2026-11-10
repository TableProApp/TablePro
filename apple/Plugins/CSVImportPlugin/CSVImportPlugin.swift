//
//  CSVImportPlugin.swift
//  CSVImportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit
import TableProTabularIO

final class CSVImportPlugin: ObservableObject, ImportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "CSV Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from CSV and TSV files"
    static let formatId = "csv"
    static let formatDisplayName = "CSV"
    static let acceptedFileExtensions = ["csv", "tsv"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true
    static let sourceFieldsFollowFileOrder = true

    typealias Settings = CSVImportOptions
    static let settingsStorageId = "csv-import"

    @Published var settings = CSVImportOptions() {
        didSet { saveSettings() }
    }

    var fieldDetectionSignature: String { settings.detectionSignature }

    var rowImportConfiguration: RowImportRunner.Configuration? { runConfiguration }

    private var runConfiguration: RowImportRunner.Configuration {
        RowImportRunner.Configuration(
            errorHandling: settings.errorHandling,
            wrapInTransaction: settings.wrapInTransaction,
            deleteExistingRows: settings.deleteExistingRows
        )
    }

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(CSVImportOptionsView(plugin: self))
    }

    private typealias MalformedRow = (line: Int, error: CSVImportParsing.RowShapeError)

    private static let detectionPrefixBytes = 1_048_576
    private static let batchSize = 500

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()

        let text: CSVImportText
        do {
            text = try CSVImportText.contents(of: url, encoding: settings.encoding, isCancelled: { progress.isCancelled })
        } catch is TabularCancellation {
            throw PluginImportCancellationError()
        } catch {
            throw PluginImportError.importFailed(error.localizedDescription)
        }
        defer { text.removeTemporaryFile() }
        if let line = text.firstUndecodableLine {
            throw PluginImportError.importFailed(String(
                format: String(
                    localized: "Line %@ is not valid %@ text. Choose the file's encoding in the import options, then import again.",
                    bundle: .main
                ),
                line.formatted(),
                text.encoding.displayName
            ))
        }
        let data = text.data

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
        let configuration = runConfiguration
        var pendingFailure: PluginImportError?
        var malformedCount = 0
        var malformedErrors: [PluginImportResult.ImportStatementError] = []
        let outcome = try await RowImportRunner.run(
            configuration: configuration,
            sink: sink,
            progress: progress
        ) {
            if let pendingFailure { throw pendingFailure }
            guard cursor < dataRanges.count else { return nil }
            let end = min(cursor + Self.batchSize, dataRanges.count)
            let parsed = self.parseBatch(
                in: data,
                parser: parser,
                ranges: dataRanges[cursor..<end],
                startIndex: cursor,
                lineOffset: lineOffset,
                columnNames: columnNames
            )
            var batch = parsed.rows
            let malformed = parsed.malformed
            let blankRows = (end - cursor) - batch.count
            if blankRows > 0 {
                progress.incrementStatement(by: blankRows)
            }
            cursor = end
            guard let first = malformed.first else { return batch }
            guard configuration.errorHandling == .skipAndContinue else {
                // The rows above the malformed one go in first, as they do when the database refuses a row.
                batch.removeAll { $0.line > first.line }
                pendingFailure = .statementFailed(
                    statement: "row \(first.line)", line: first.line, underlyingError: first.error)
                return batch
            }
            malformedCount += malformed.count
            for entry in malformed where malformedErrors.count < configuration.maxRecordedErrors {
                malformedErrors.append(.init(
                    statement: "row \(entry.line)", line: entry.line, errorMessage: entry.error.localizedDescription))
            }
            return batch
        }

        let errors = (outcome.errors + malformedErrors).sorted { $0.line < $1.line }
        return PluginImportResult(
            executedStatements: outcome.inserted,
            executionTime: Date().timeIntervalSince(startTime),
            skippedStatements: outcome.skipped + malformedCount,
            errors: Array(errors.prefix(configuration.maxRecordedErrors))
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
    ) -> (rows: [RowImportRunner.Entry], malformed: [MalformedRow]) {
        data.withUnsafeBytes { raw -> (rows: [RowImportRunner.Entry], malformed: [MalformedRow]) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return ([], []) }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)
            var out: [RowImportRunner.Entry] = []
            var malformed: [MalformedRow] = []
            out.reserveCapacity(ranges.count)
            for (offset, range) in ranges.enumerated() {
                let fields = parser.parseRow(buffer, range: range)
                if CSVImportParsing.isBlank(fields) { continue }
                let line = startIndex + offset + lineOffset
                if let error = CSVImportParsing.shapeError(
                    fields: fields, columnCount: columnNames.count, options: settings
                ) {
                    malformed.append((line, error))
                    continue
                }
                out.append((line, CSVImportParsing.row(fields: fields, columnNames: columnNames, options: settings)))
            }
            return (out, malformed)
        }
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        let text = try CSVImportText.prefix(of: url, length: Self.detectionPrefixBytes, encoding: settings.encoding)
        return CSVImportParsing.detectFields(in: text.data, options: settings)
    }
}
