//
//  MongoDBFilterValue.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

/// Renders a typed filter value as Extended JSON.
///
/// MongoDB compares only within a BSON type (type bracketing), so a Date field compared against
/// the string `"2024-01-01T00:00:00Z"` matches nothing and reports no error. The column's sampled
/// kind is what tells us to wrap the text in `$date`, `$oid` or `$numberDecimal` instead.
enum MongoDBFilterValue {
    static func json(_ value: String, kind: BsonValueKind?) -> String {
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) { return binary }

        switch kind {
        case .date:
            return dateJson(value) ?? untypedJson(value)
        case .objectId:
            return objectIdJson(value) ?? untypedJson(value)
        case .decimal128:
            guard MongoDBJsonNumber.isValid(value) else { return untypedJson(value) }
            return "{\"$numberDecimal\": \"\(MongoDBQueryBuilder.escapeJsonString(value))\"}"
        case .string:
            return "\"\(MongoDBQueryBuilder.escapeJsonString(value))\""
        default:
            return untypedJson(value)
        }
    }

    /// A value whose column kind says nothing useful, typed by its own spelling.
    static func untypedJson(_ value: String) -> String {
        if value == "true" || value == "false" { return value }
        if value == "null" { return value }
        if MongoDBJsonNumber.isValid(value) { return value }
        if let binary = MongoDBUuidCodec.extendedJsonFromWrapper(value) { return binary }
        return "\"\(MongoDBQueryBuilder.escapeJsonString(value))\""
    }

    static func objectIdJson(_ value: String) -> String? {
        guard (value as NSString).length == 24, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return "{\"$oid\": \"\(value)\"}"
    }

    /// Only a string field can match a regex, so an ignore-case request on any other kind would
    /// turn a working comparison into one that matches nothing.
    static func supportsRegexMatching(_ kind: BsonValueKind?) -> Bool {
        switch kind {
        case .none, .string, .null:
            return true
        default:
            return false
        }
    }

    static func dateJson(_ value: String) -> String? {
        guard let millis = epochMilliseconds(value) else { return nil }
        return "{\"$date\": {\"$numberLong\": \"\(millis)\"}}"
    }

    static func epochMilliseconds(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let millis = Int64(trimmed) { return millis }

        for options in isoOptions {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded())
            }
        }
        for format in plainFormats {
            if let date = plainFormatter(format).date(from: trimmed) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded())
            }
        }
        return nil
    }

    private static let isoOptions: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime, .withFractionalSeconds],
        [.withInternetDateTime],
    ]

    private static let plainFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    private static func plainFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
