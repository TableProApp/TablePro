//
//  JSONImportParsing.swift
//  JSONImportPlugin
//
//  Pure JSON parsing, row extraction, and field inference. Kept free of the
//  plugin's loadable-bundle and SwiftUI surface so it can be compiled into the
//  test target directly (a loadable .tableplugin cannot be linked by tests).
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

enum JSONImportParsing {
    static func isLineDelimited(_ url: URL) -> Bool {
        ["jsonl", "ndjson"].contains(url.pathExtension.lowercased())
    }

    static func parseRow(fromLine line: Data) throws -> [String: PluginCellValue]? {
        try object(fromLine: line).map(convertRow)
    }

    static func object(fromLine line: Data) throws -> NSDictionary? {
        guard !isBlank(line) else { return nil }
        let object = try JSONSerialization.jsonObject(with: line)
        guard let dict = object as? NSDictionary else {
            throw PluginImportError.importFailed("Each line must be a JSON object")
        }
        return dict
    }

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }

    static func parseRows(at url: URL, targetTable: String?) throws -> [NSDictionary] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try extractRows(from: object, targetTable: targetTable)
    }

    static func extractRows(from object: Any, targetTable: String?) throws -> [NSDictionary] {
        if let array = object as? [Any] {
            return array.compactMap { $0 as? NSDictionary }
        }

        guard let dict = object as? [String: Any] else {
            throw PluginImportError.importFailed("Expected a JSON array of objects or a table-keyed object")
        }

        let tables = dict.compactMapValues { value -> [Any]? in
            guard let array = value as? [Any] else { return nil }
            return array.allSatisfy { $0 is NSDictionary } ? array : nil
        }
        let isTableWrapper = !tables.isEmpty && tables.count == dict.count

        guard isTableWrapper else {
            return [dict as NSDictionary]
        }

        if let targetTable, let match = matchTable(in: tables, to: targetTable) {
            return match.compactMap { $0 as? NSDictionary }
        }
        if tables.count == 1, let only = tables.values.first {
            return only.compactMap { $0 as? NSDictionary }
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

    static func convertRow(_ row: NSDictionary) -> [String: PluginCellValue] {
        var converted: [String: PluginCellValue] = [:]
        converted.reserveCapacity(row.count)
        row.enumerateKeysAndObjects { key, value, _ in
            guard let name = key as? String else { return }
            converted[name] = cellValue(from: value)
        }
        return converted
    }

    static func cellValue(from json: Any) -> PluginCellValue {
        switch json {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "true" : "false")
            }
            return .text(NumberText.text(for: number))
        case let string as String:
            return .text(string)
        default:
            return .text(serialize(json))
        }
    }

    private static func serialize(_ object: Any) -> String {
        NumberText.json(from: object) ?? String(describing: object)
    }

    // MARK: - Source introspection

    static func detectFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        guard isLineDelimited(url) else {
            return try detectFields(in: try parseRows(at: url, targetTable: targetTable))
        }
        return try detectFields(inLinesAt: url)
    }

    static func detectFields(inLinesAt url: URL) throws -> [PluginImportField] {
        var survey = JSONFieldSurvey()
        var lines = try JSONLineReader(url: url)
        defer { lines.close() }
        while let line = try lines.next() {
            autoreleasepool {
                guard let row = try? object(fromLine: line) else { return }
                survey.add(row)
            }
        }
        return survey.fields
    }

    static func detectFields(in rows: [NSDictionary]) throws -> [PluginImportField] {
        var survey = JSONFieldSurvey()
        for row in rows {
            try Task.checkCancellation()
            survey.add(row)
        }
        return survey.fields
    }

    static func sampleString(_ value: Any) -> String {
        switch cellValue(from: value) {
        case .text(let string): return String(string.prefix(80))
        case .bytes, .null: return ""
        }
    }
}
