//
//  JSONImportPlugin.swift
//  JSONImportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class JSONImportPlugin: ImportFormatPlugin, SettablePlugin {
    private static let logger = Logger(subsystem: "com.TablePro", category: "JSONImportPlugin")

    static let pluginName = "JSON Import"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Import data from JSON files"
    static let formatId = "json"
    static let formatDisplayName = "JSON"
    static let acceptedFileExtensions = ["json", "jsonl", "ndjson"]
    static let iconName = "curlybraces"
    static let requiresTargetTable = true

    typealias Settings = JSONImportOptions
    static let settingsStorageId = "json-import"

    var settings = JSONImportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(JSONImportOptionsView(plugin: self))
    }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        let startTime = Date()
        let url = source.fileURL()
        let useTransaction = settings.wrapInTransaction && settings.errorHandling != .skipAndContinue

        progress.setEstimatedTotal(max(1, Int(source.fileSizeBytes() / 256)))

        var inserted = 0
        var skipped = 0
        var errors: [PluginImportResult.ImportStatementError] = []
        let maxErrors = 1_000

        do {
            if settings.deleteExistingRows {
                try await sink.deleteAllRowsFromTargetTable()
            }
            if useTransaction {
                try await sink.beginTransaction()
            }

            if Self.isLineDelimited(url) {
                var lineNumber = 0
                for try await line in url.lines {
                    try progress.checkCancellation()
                    lineNumber += 1
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let row = try Self.parseRow(fromLine: trimmed)
                    try await insert(row, into: sink, at: lineNumber, progress: progress,
                                     inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)
                }
            } else {
                let rows = try Self.parseRows(at: url, targetTable: sink.targetTable)
                for (index, row) in rows.enumerated() {
                    try progress.checkCancellation()
                    try await insert(row, into: sink, at: index + 1, progress: progress,
                                     inserted: &inserted, skipped: &skipped, errors: &errors, maxErrors: maxErrors)
                }
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

    private func insert(
        _ row: [String: PluginCellValue],
        into sink: any PluginImportDataSink,
        at line: Int,
        progress: PluginImportProgress,
        inserted: inout Int,
        skipped: inout Int,
        errors: inout [PluginImportResult.ImportStatementError],
        maxErrors: Int
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
                if errors.count < maxErrors {
                    errors.append(.init(statement: "row \(line)", line: line, errorMessage: error.localizedDescription))
                }
                progress.incrementStatement()
            }
        }
    }

    // MARK: - Parsing

    static func isLineDelimited(_ url: URL) -> Bool {
        ["jsonl", "ndjson"].contains(url.pathExtension.lowercased())
    }

    static func parseRow(fromLine line: String) throws -> [String: PluginCellValue] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        guard let dict = object as? [String: Any] else {
            throw PluginImportError.importFailed("Each line must be a JSON object")
        }
        return convertRow(dict)
    }

    static func parseRows(at url: URL, targetTable: String?) throws -> [[String: PluginCellValue]] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try extractRows(from: object, targetTable: targetTable).map(convertRow)
    }

    static func extractRows(from object: Any, targetTable: String?) throws -> [[String: Any]] {
        if let array = object as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }

        guard let dict = object as? [String: Any] else {
            throw PluginImportError.importFailed("Expected a JSON array of objects or a table-keyed object")
        }

        let tables = dict.compactMapValues { value -> [Any]? in
            guard let array = value as? [Any] else { return nil }
            return array.allSatisfy { $0 is [String: Any] } ? array : nil
        }
        let isTableWrapper = !tables.isEmpty && tables.count == dict.count

        guard isTableWrapper else {
            return [dict]
        }

        if let targetTable, let match = matchTable(in: tables, to: targetTable) {
            return match.compactMap { $0 as? [String: Any] }
        }
        if tables.count == 1, let only = tables.values.first {
            return only.compactMap { $0 as? [String: Any] }
        }
        throw PluginImportError.importFailed("The file contains multiple tables and none matches the target table")
    }

    private static func matchTable(in tables: [String: [Any]], to target: String) -> [Any]? {
        if let exact = tables.first(where: { $0.key.caseInsensitiveCompare(target) == .orderedSame }) {
            return exact.value
        }
        let suffix = tables.first { key, _ in
            key.split(separator: ".").last.map { $0.caseInsensitiveCompare(target) == .orderedSame } ?? false
        }
        return suffix?.value
    }

    static func convertRow(_ row: [String: Any]) -> [String: PluginCellValue] {
        row.mapValues(cellValue(from:))
    }

    static func cellValue(from json: Any) -> PluginCellValue {
        switch json {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "true" : "false")
            }
            return .text(number.stringValue)
        case let string as String:
            return .text(string)
        default:
            return .text(serialize(json))
        }
    }

    private static func serialize(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: object)
        }
        return string
    }
}
