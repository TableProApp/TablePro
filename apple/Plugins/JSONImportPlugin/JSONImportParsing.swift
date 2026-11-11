//
//  JSONImportParsing.swift
//  JSONImportPlugin
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

    static var unexpectedShapeError: PluginImportError {
        .importFailed("Expected a JSON array of objects or a table-keyed object")
    }

    static var noMatchingTableError: PluginImportError {
        .importFailed("The file contains multiple tables and none matches the target table")
    }

    // The values of a `.json` file that become rows, and how many there are. The file is read one
    // element at a time after a pass that finds its rows and checks its structure, so a broken file
    // fails before the first row is imported.
    static func rowElements(
        at url: URL,
        targetTable: String?,
        checkCancellation: @escaping () throws -> Void
    ) throws -> (elements: any JSONElementSequence, count: Int) {
        var reader = try JSONDocumentReader(url: url, checkCancellation: checkCancellation)
        do {
            let rows = try JSONDocumentOutline.rows(in: &reader, targetTable: targetTable) { reader, _ in
                try reader.skipValue()
            }
            switch rows {
            case .array(let offset, let count, _):
                return (try JSONStreamedElements(reader: reader, arrayAt: offset), count)
            case .singleObject(let offset):
                defer { reader.close() }
                var row: [String: PluginCellValue] = [:]
                try members(ofObjectAt: offset, in: &reader) { name, value in
                    row[name] = cellValue(from: value)
                }
                return (JSONSingleRow(row), 1)
            }
        } catch {
            reader.close()
            throw error
        }
    }

    // Each member of the object at `offset`, parsed one at a time. A parsed object keeps the first
    // of two members that share a name, so the later one is passed over.
    static func members(
        ofObjectAt offset: Int,
        in reader: inout JSONDocumentReader,
        _ body: (String, Any) throws -> Void
    ) throws {
        try reader.seek(to: offset)
        guard try reader.enterObject() else { return }
        var names: Set<String> = []
        repeat {
            let name = try reader.memberName()
            let value = try reader.readValue()
            guard names.insert(name).inserted else { continue }
            try autoreleasepool {
                try body(name, try JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed))
            }
        } while try reader.continueObject()
    }

    static func row(from element: Any) throws -> [String: PluginCellValue] {
        if let row = element as? [String: PluginCellValue] {
            return row
        }
        guard let object = element as? NSDictionary else {
            throw PluginImportError.importFailed(String(localized: "Each array element must be a JSON object"))
        }
        return convertRow(object)
    }

    static func parseElements(at url: URL, targetTable: String?) throws -> [Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try extractElements(from: object, targetTable: targetTable)
    }

    static func extractRows(from object: Any, targetTable: String?) throws -> [NSDictionary] {
        try extractElements(from: object, targetTable: targetTable).compactMap { $0 as? NSDictionary }
    }

    // A top-level array's elements come back whatever they are, so the import can report each one
    // that is not an object instead of leaving it out unseen.
    static func extractElements(from object: Any, targetTable: String?) throws -> [Any] {
        if let array = object as? [Any] {
            return array
        }

        guard let dict = object as? [String: Any] else {
            throw unexpectedShapeError
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
            return match
        }
        if tables.count == 1, let only = tables.values.first {
            return only
        }
        throw noMatchingTableError
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
        try Task.checkCancellation()
        guard isLineDelimited(url) else {
            return try detectFields(inDocumentAt: url, targetTable: targetTable)
        }
        return try detectFields(inLinesAt: url)
    }

    // Every value is parsed once, one at a time, and each array keeps a survey of its own, so the
    // target table's fields are known when the pass ends. A value that does not parse fails the
    // detection, as it fails a whole-file parse.
    static func detectFields(inDocumentAt url: URL, targetTable: String?) throws -> [PluginImportField] {
        var reader = try JSONDocumentReader(url: url)
        defer { reader.close() }
        var surveys: [Int: JSONFieldSurvey] = [:]
        let rows = try JSONDocumentOutline.rows(in: &reader, targetTable: targetTable) { reader, slot in
            let value = try reader.readValue()
            try autoreleasepool {
                let object = try JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)
                guard let slot, let row = object as? NSDictionary else { return }
                surveys[slot, default: JSONFieldSurvey()].add(row)
            }
        }
        switch rows {
        case .array(_, _, let slot):
            return surveys[slot]?.fields ?? []
        case .singleObject(let offset):
            var survey = JSONFieldSurvey()
            try members(ofObjectAt: offset, in: &reader) { name, value in
                survey.add(value, named: name)
            }
            return survey.fields
        }
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
