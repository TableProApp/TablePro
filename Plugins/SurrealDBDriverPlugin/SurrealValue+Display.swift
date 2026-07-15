//
//  SurrealValue+Display.swift
//  SurrealDBDriverPlugin
//

import Foundation

public extension SurrealValue {
    static let maxSerializedLength = 10_000

    var displayText: String {
        switch self {
        case .null, .none:
            return ""
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .int(number):
            return String(number)
        case let .double(number):
            return Self.formatDouble(number)
        case let .string(text):
            return text
        case let .bytes(data):
            return data.base64EncodedString()
        case .array, .object:
            return jsonText
        case let .recordId(record):
            return record.literal
        case let .table(name):
            return name
        case let .uuid(value):
            return value.uuidString.lowercased()
        case let .decimal(text):
            return text
        case let .datetime(seconds, nanoseconds):
            return Self.formatDatetime(seconds: seconds, nanoseconds: nanoseconds)
        case let .duration(seconds, nanoseconds):
            return Self.formatDuration(seconds: seconds, nanoseconds: nanoseconds)
        case .tagged:
            return jsonText
        case let .range(from, to):
            return Self.formatRange(from: from, to: to)
        }
    }

    var jsonText: String {
        let text = Self.jsonFragment(self)
        guard (text as NSString).length > Self.maxSerializedLength else { return text }
        return String(text.prefix(Self.maxSerializedLength)) + "..."
    }

    var typeName: String {
        switch self {
        case .null:
            return "null"
        case .none:
            return "none"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .double:
            return "float"
        case .string:
            return "string"
        case .bytes:
            return "bytes"
        case .array:
            return "array"
        case .object:
            return "object"
        case .recordId:
            return "record"
        case .table:
            return "table"
        case .uuid:
            return "uuid"
        case .decimal:
            return "decimal"
        case .datetime:
            return "datetime"
        case .duration:
            return "duration"
        case .tagged(let tag, _):
            return Self.isGeometryTag(tag) ? "geometry" : "any"
        case .range:
            return "range"
        }
    }

    static func isGeometryTag(_ tag: UInt64) -> Bool {
        tag >= SurrealCBORTag.geometryPoint && tag <= SurrealCBORTag.geometryCollection
    }

    // MARK: - JSON

    private static func jsonFragment(_ value: SurrealValue) -> String {
        switch value {
        case .null, .none:
            return "null"
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .int(number):
            return String(number)
        case let .double(number):
            return formatDouble(number)
        case let .decimal(text):
            return text
        case let .array(items):
            return "[" + items.map(jsonFragment).joined(separator: ",") + "]"
        case let .object(pairs):
            let body = pairs
                .map { quoted($0.key) + ":" + jsonFragment($0.value) }
                .joined(separator: ",")
            return "{" + body + "}"
        case let .tagged(tag, inner):
            guard isGeometryTag(tag) else { return jsonFragment(inner) }
            return geometryJson(tag: tag, value: inner)
        default:
            return quoted(value.displayText)
        }
    }

    private static func geometryJson(tag: UInt64, value: SurrealValue) -> String {
        let type = geometryTypeName(tag)
        guard tag != SurrealCBORTag.geometryCollection else {
            return "{\"type\":\"GeometryCollection\",\"geometries\":" + jsonFragment(value) + "}"
        }
        return "{\"type\":" + quoted(type) + ",\"coordinates\":" + jsonFragment(value) + "}"
    }

    private static func geometryTypeName(_ tag: UInt64) -> String {
        switch tag {
        case 88: return "Point"
        case 89: return "LineString"
        case 90: return "Polygon"
        case 91: return "MultiPoint"
        case 92: return "MultiLineString"
        case 93: return "MultiPolygon"
        default: return "GeometryCollection"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                    continue
                }
                out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }

    // MARK: - Scalar formatting

    private static func formatDouble(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    static func formatDatetime(seconds: Int64, nanoseconds: UInt32) -> String {
        let secondsPerDay: Int64 = 86_400
        var days = seconds / secondsPerDay
        var remainder = seconds % secondsPerDay
        if remainder < 0 {
            remainder += secondsPerDay
            days -= 1
        }

        let civil = civilFromDays(days)
        let hour = remainder / 3600
        let minute = (remainder % 3600) / 60
        let second = remainder % 60

        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            civil.year, civil.month, civil.day, hour, minute, second
        )
        if nanoseconds > 0 {
            var fraction = String(format: "%09u", nanoseconds)
            while fraction.hasSuffix("0") {
                fraction.removeLast()
            }
            text += "." + fraction
        }
        return text + "Z"
    }

    private static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (year + (month <= 2 ? 1 : 0), month, day)
    }

    static func formatDuration(seconds: Int64, nanoseconds: UInt32) -> String {
        guard seconds != 0 || nanoseconds != 0 else { return "0ns" }

        var remaining = seconds
        var text = ""
        let units: [(Int64, String)] = [(604_800, "w"), (86_400, "d"), (3600, "h"), (60, "m"), (1, "s")]
        for (size, suffix) in units where remaining >= size {
            text += "\(remaining / size)\(suffix)"
            remaining %= size
        }

        var nanos = nanoseconds
        if nanos >= 1_000_000 {
            text += "\(nanos / 1_000_000)ms"
            nanos %= 1_000_000
        }
        if nanos >= 1000 {
            text += "\(nanos / 1000)µs"
            nanos %= 1000
        }
        if nanos > 0 {
            text += "\(nanos)ns"
        }
        return text
    }

    private static func formatRange(from: SurrealBound?, to: SurrealBound?) -> String {
        let start = from.map { $0.value.displayText } ?? ""
        let end = to.map { $0.value.displayText } ?? ""
        let separator = (from?.isInclusive ?? true) ? ".." : ">.."
        let closing = (to?.isInclusive ?? false) ? "=" : ""
        return start + separator + closing + end
    }
}

public extension SurrealRecordID {
    var literal: String {
        SurrealQL.recordLiteral(self)
    }
}
