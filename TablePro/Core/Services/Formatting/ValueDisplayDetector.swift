//
//  ValueDisplayDetector.swift
//  TablePro
//
//  Heuristic auto-detection of semantic value formats.
//  Examines column types, names, and sample values to suggest
//  display formats like UUID or Unix timestamp.
//

import Foundation
import TableProPluginKit

@MainActor
enum ValueDisplayDetector {
    static func detect(
        columns: [String],
        columnTypes: [ColumnType],
        sampleValues: [[PluginCellValue]]?
    ) -> [ValueDisplayFormat?] {
        var results = [ValueDisplayFormat?](repeating: nil, count: columns.count)

        for i in 0..<columns.count {
            let columnType = i < columnTypes.count ? columnTypes[i] : nil
            let columnName = columns[i]
            let sampleValue = firstNonNilSample(at: i, from: sampleValues)

            if let format = detectUuid(columnType: columnType, columnName: columnName) {
                results[i] = format
            } else if let format = detectTimestamp(columnType: columnType, columnName: columnName, sampleValue: sampleValue) {
                results[i] = format
            }
        }

        return results
    }

    // MARK: - UUID Detection

    private static func detectUuid(columnType: ColumnType?, columnName: String) -> ValueDisplayFormat? {
        guard let columnType else { return nil }
        let nameLower = columnName.lowercased()
        let nameHint = nameLower.contains("uuid") || nameLower.contains("guid")
            || nameLower.hasSuffix("_id") || nameLower == "id"

        switch columnType {
        case .blob(let rawType):
            // BINARY(16) requires name hint to avoid false positives on arbitrary 16-byte data
            guard let raw = rawType?.uppercased() else { return nil }
            if raw.contains("BINARY") && raw.contains("(16)") && nameHint {
                return .uuid
            }
        case .text(let rawType):
            guard let raw = rawType?.uppercased() else { return nil }
            let isCharLike = (raw.contains("CHAR") || raw.contains("VARCHAR"))
                && (raw.contains("(32)") || raw.contains("(36)"))
            if isCharLike && (nameLower.contains("uuid") || nameLower.contains("guid")) {
                return .uuid
            }
        default:
            break
        }

        return nil
    }

    // MARK: - Timestamp Detection

    private static func detectTimestamp(
        columnType: ColumnType?,
        columnName: String,
        sampleValue: String?
    ) -> ValueDisplayFormat? {
        guard let columnType else { return nil }

        switch columnType {
        case .integer:
            break
        default:
            return nil
        }

        let nameLower = columnName.lowercased()
        let nameMatches = nameLower.hasSuffix("_at")
            || nameLower.hasSuffix("_time")
            || nameLower.hasSuffix("_timestamp")
            || nameLower == "created"
            || nameLower == "updated"
            || nameLower == "modified"
            || nameLower == "timestamp"

        guard nameMatches else { return nil }

        // Validate with sample value if available
        if let sample = sampleValue, let numericValue = Double(sample) {
            // Millisecond timestamps are > 10 billion
            if numericValue > 10_000_000_000 {
                let seconds = numericValue / 1_000
                guard seconds >= 946_684_800 && seconds <= 4_102_444_800 else { return nil }
                return .unixTimestampMillis
            }
            guard numericValue >= 946_684_800 && numericValue <= 4_102_444_800 else { return nil }
            return .unixTimestamp
        }

        // No sample to validate against; default to seconds
        return .unixTimestamp
    }

    // MARK: - Helpers

    private static func firstNonNilSample(at columnIndex: Int, from sampleValues: [[PluginCellValue]]?) -> String? {
        guard let samples = sampleValues else { return nil }
        for row in samples {
            if columnIndex < row.count, let value = row[columnIndex].asText, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
