//
//  ValueDisplayFormat.swift
//  TablePro
//
//  Semantic display formats for raw database values.
//  Enables auto-detection and per-column overrides for values like
//  UUIDs stored in BINARY(16) or Unix timestamps in INT columns.
//

import Foundation

enum ValueDisplayFormat: String, Codable, CaseIterable, Identifiable {
    case raw
    case uuid
    case unixTimestamp
    case unixTimestampMillis
    case json
    case phpSerialized

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return String(localized: "Raw Value")
        case .uuid: return String(localized: "UUID")
        case .unixTimestamp: return String(localized: "Unix Timestamp (seconds)")
        case .unixTimestampMillis: return String(localized: "Unix Timestamp (milliseconds)")
        case .json: return String(localized: "JSON")
        case .phpSerialized: return String(localized: "PHP Serialized")
        }
    }

    /// Column types this format can apply to.
    var applicableColumnTypes: Set<String> {
        switch self {
        case .raw:
            return []
        case .uuid:
            return ["blob", "text"]
        case .unixTimestamp, .unixTimestampMillis:
            return ["integer"]
        case .json, .phpSerialized:
            return ["text"]
        }
    }

    /// Returns applicable formats for a given column type.
    /// Always includes `.raw` as the first option.
    static func applicableFormats(for columnType: ColumnType?) -> [ValueDisplayFormat] {
        guard let columnType else { return [.raw] }

        let typeKey: String
        switch columnType {
        case .blob: typeKey = "blob"
        case .text: typeKey = "text"
        case .integer: typeKey = "integer"
        default: return [.raw]
        }

        var result: [ValueDisplayFormat] = [.raw]
        for format in allCases where format != .raw {
            if format.applicableColumnTypes.contains(typeKey) {
                result.append(format)
            }
        }
        return result
    }
}
