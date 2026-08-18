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

    func isApplicable(to columnType: ColumnType?, databaseType: DatabaseType? = nil) -> Bool {
        if self == .raw { return true }
        guard let columnType else { return false }

        let typeKey: String
        switch columnType {
        case .blob: typeKey = "blob"
        case .text: typeKey = "text"
        case .integer: typeKey = "integer"
        default: return false
        }

        if self == .uuid, databaseType == .mongodb, columnType.isBlobType {
            return false
        }
        return applicableColumnTypes.contains(typeKey)
    }

    /// Returns applicable formats for a given column type.
    /// Always includes `.raw` as the first option.
    static func applicableFormats(
        for columnType: ColumnType?,
        databaseType: DatabaseType? = nil
    ) -> [ValueDisplayFormat] {
        allCases.filter { $0.isApplicable(to: columnType, databaseType: databaseType) }
    }
}

enum ValueDisplayFormatColumnKey {
    static func storageKeys(for columns: [String]) -> [String] {
        let counts = columns.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var occurrences: [String: Int] = [:]

        return columns.map { name in
            let occurrence = occurrences[name, default: 0]
            occurrences[name] = occurrence + 1
            guard counts[name, default: 0] > 1 else { return name }
            return "\u{0}column:\(occurrence):\(name)"
        }
    }
}
