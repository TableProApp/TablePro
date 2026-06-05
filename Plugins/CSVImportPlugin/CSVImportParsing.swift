//
//  CSVImportParsing.swift
//  CSVImportPlugin
//
//  Pure CSV row extraction, NULL handling, and field inference. Kept free of the
//  plugin's loadable-bundle and SwiftUI surface so it can be compiled into the
//  test target directly (a loadable .tableplugin cannot be linked by tests).
//  The RFC 4180 tokenizer itself lives in TableProPluginKit (CSVStreamingParser),
//  shared with the CSV inspector.
//

import Foundation
import TableProPluginKit

enum CSVImportParsing {
    static let detectionSampleLimit = 200

    static func resolveDialect(in data: Data, options: CSVImportOptions) -> CSVDialect {
        var dialect = CSVDialect.detect(from: data)
        if let byte = options.delimiter.byte {
            dialect.delimiter = byte
        }
        dialect.quoteChar = options.quoteCharacter.byte
        if let forced = options.encoding.stringEncoding {
            dialect.encoding = forced
        }
        return dialect
    }

    static func defaultColumnName(_ index: Int) -> String {
        "Column \(index + 1)"
    }

    static func columnNames(header: [String]?, columnCount: Int) -> [String] {
        var names: [String] = []
        names.reserveCapacity(columnCount)
        var used = Set<String>()
        for index in 0..<columnCount {
            let raw = header.flatMap { index < $0.count ? $0[index] : nil } ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? defaultColumnName(index) : trimmed
            var unique = base
            var suffix = 2
            while !used.insert(unique).inserted {
                unique = "\(base) \(suffix)"
                suffix += 1
            }
            names.append(unique)
        }
        return names
    }

    static func cellValue(from raw: String, options: CSVImportOptions) -> PluginCellValue {
        var value = raw
        if options.trimWhitespace {
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if options.emptyAsNull, value.isEmpty {
            return .null
        }
        if !options.nullString.isEmpty, value == options.nullString {
            return .null
        }
        return .text(value)
    }

    static func sampleText(from raw: String, options: CSVImportOptions) -> String? {
        guard case .text(let value) = cellValue(from: raw, options: options), !value.isEmpty else { return nil }
        return value
    }

    static func row(fields: [String], columnNames: [String], options: CSVImportOptions) -> [String: PluginCellValue] {
        var row: [String: PluginCellValue] = [:]
        row.reserveCapacity(columnNames.count)
        for (index, name) in columnNames.enumerated() {
            let raw = index < fields.count ? fields[index] : ""
            row[name] = cellValue(from: raw, options: options)
        }
        return row
    }

    static func importFieldType(for type: CSVTypeInferrer.InferredType) -> PluginImportFieldType {
        switch type {
        case .integer: return .integer
        case .real: return .real
        case .boolean: return .boolean
        case .date: return .text
        case .text: return .text
        @unknown default: return .text
        }
    }

    static func isBlank(_ fields: [String]) -> Bool {
        fields.allSatisfy { $0.isEmpty }
    }

    static func detectFields(
        in data: Data,
        options: CSVImportOptions,
        limit: Int = detectionSampleLimit
    ) -> [PluginImportField] {
        let dialect = resolveDialect(in: data, options: options)
        let parser = CSVStreamingParser(dialect: dialect)

        return data.withUnsafeBytes { raw -> [PluginImportField] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)
            let ranges = parser.indexRows(buffer)
            guard !ranges.isEmpty else { return [] }

            var dataRanges = ranges[...]
            var header: [String]?
            if options.hasHeaderRow {
                header = parser.parseRow(buffer, range: ranges[0])
                dataRanges = ranges.dropFirst()
            }

            let columnCount = header?.count
                ?? dataRanges.first.map { parser.parseRow(buffer, range: $0).count }
                ?? 0
            guard columnCount > 0 else { return [] }

            let names = columnNames(header: header, columnCount: columnCount)
            var samples: [[String]] = Array(repeating: [], count: columnCount)
            var firstValues: [String?] = Array(repeating: nil, count: columnCount)
            var sampled = 0

            for range in dataRanges {
                if sampled >= limit { break }
                let fields = parser.parseRow(buffer, range: range)
                if isBlank(fields) { continue }
                for column in 0..<columnCount {
                    let raw = column < fields.count ? fields[column] : ""
                    guard let value = sampleText(from: raw, options: options) else { continue }
                    samples[column].append(value)
                    if firstValues[column] == nil { firstValues[column] = value }
                }
                sampled += 1
            }

            return (0..<columnCount).map { column in
                PluginImportField(
                    name: names[column],
                    sampleValue: firstValues[column].map { String($0.prefix(80)) },
                    inferredType: importFieldType(for: CSVTypeInferrer.infer(column: samples[column]))
                )
            }
        }
    }
}
