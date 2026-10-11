//
//  CassandraBoundValue.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

/// The CQL type a bind marker expects, as the prepared statement reports it.
enum CassandraParameterType: Equatable, Sendable {
    case text
    case tinyint
    case smallint
    case int
    case bigint
    case counter
    case float
    case double
    case boolean
    case uuid
    case timeuuid
    case timestamp
    case date
    case time
    case inet
    case blob
    case decimal
    case varint
    case unsupported(String)
}

/// A value converted to the Swift shape its bind marker's type needs, so nothing is sent as a string to a column
/// that reads the bytes as something else. The driver leaves a slot unset when the types disagree, and the server
/// then drops the value or rejects the key it belonged to.
enum CassandraBoundValue: Equatable, Sendable {
    case null
    case string(String)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case float(Float)
    case double(Double)
    case bool(Bool)
    case uuid(String)
    case inet(String)
    case bytes(Data)
    case varint(Data)
    case decimal(unscaled: Data, scale: Int32)
    case date(UInt32)
    case time(Int64)
}

struct CassandraValueRefusal: Error, Equatable, PluginDriverError {
    let pluginErrorMessage: String

    static func invalid(_ text: String, typeName: String) -> CassandraValueRefusal {
        let shown = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return CassandraValueRefusal(pluginErrorMessage: String(
            format: String(localized: "\"%1$@\" is not a valid %2$@ value."), shown, typeName
        ))
    }

    static func unsupported(typeName: String) -> CassandraValueRefusal {
        CassandraValueRefusal(pluginErrorMessage: String(
            format: String(localized: "A %@ value cannot be written from the grid. Use the CQL editor."), typeName
        ))
    }
}

enum CassandraValueParser {
    private static let dateEpochBias = Int64(1) << 31
    private static let secondsPerDay: Int64 = 86_400
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static func bind(_ value: PluginCellValue, as type: CassandraParameterType) throws -> CassandraBoundValue {
        switch value {
        case .null:
            return .null
        case .bytes(let data):
            return try bind(bytes: data, as: type)
        case .text(let text):
            return try parse(text, as: type)
        }
    }

    static func parse(_ text: String, as type: CassandraParameterType) throws -> CassandraBoundValue {
        switch type {
        case .text:
            return .string(text)
        case .tinyint:
            return .int8(try integer(text, type: type))
        case .smallint:
            return .int16(try integer(text, type: type))
        case .int:
            return .int32(try integer(text, type: type))
        case .bigint, .counter:
            return .int64(try integer(text, type: type))
        case .float:
            guard let parsed = Float(trimmed(text)) else { throw CassandraValueRefusal.invalid(text, typeName: type.name) }
            return .float(parsed)
        case .double:
            guard let parsed = Double(trimmed(text)) else { throw CassandraValueRefusal.invalid(text, typeName: type.name) }
            return .double(parsed)
        case .boolean:
            return .bool(try boolean(text))
        case .uuid, .timeuuid:
            guard let uuid = UUID(uuidString: trimmed(text)) else {
                throw CassandraValueRefusal.invalid(text, typeName: type.name)
            }
            return .uuid(uuid.uuidString.lowercased())
        case .timestamp:
            return .int64(try timestampMilliseconds(text))
        case .date:
            return .date(try dateDays(text))
        case .time:
            return .time(try timeNanoseconds(text))
        case .inet:
            return .inet(trimmed(text))
        case .blob:
            guard let data = hexData(trimmed(text)) else { throw CassandraValueRefusal.invalid(text, typeName: type.name) }
            return .bytes(data)
        case .varint:
            guard let bytes = CassandraVarint.bytes(fromDecimalInteger: trimmed(text)) else {
                throw CassandraValueRefusal.invalid(text, typeName: type.name)
            }
            return .varint(bytes)
        case .decimal:
            guard let decimal = CassandraVarint.decimal(fromText: trimmed(text)) else {
                throw CassandraValueRefusal.invalid(text, typeName: type.name)
            }
            return .decimal(unscaled: decimal.unscaled, scale: decimal.scale)
        case .unsupported(let name):
            throw CassandraValueRefusal.unsupported(typeName: name)
        }
    }

    private static func bind(bytes data: Data, as type: CassandraParameterType) throws -> CassandraBoundValue {
        switch type {
        case .blob:
            return .bytes(data)
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw CassandraValueRefusal.invalid("0x" + data.map { String(format: "%02x", $0) }.joined(), typeName: type.name)
            }
            return .string(text)
        default:
            throw CassandraValueRefusal.unsupported(typeName: type.name)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer<Value: FixedWidthInteger>(_ text: String, type: CassandraParameterType) throws -> Value {
        guard let parsed = Value(trimmed(text)) else { throw CassandraValueRefusal.invalid(text, typeName: type.name) }
        return parsed
    }

    private static func boolean(_ text: String) throws -> Bool {
        switch trimmed(text).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.boolean.name)
        }
    }

    static func timestampMilliseconds(_ text: String) throws -> Int64 {
        let value = trimmed(text)
        if let milliseconds = Int64(value) { return milliseconds }
        for candidate in timestampCandidates(value) {
            if let date = try? Date(candidate, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return Int64((date.timeIntervalSince1970 * 1_000).rounded())
            }
            if let date = try? Date(candidate, strategy: .iso8601) {
                return Int64((date.timeIntervalSince1970 * 1_000).rounded())
            }
        }
        throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.timestamp.name)
    }

    /// The grid shows `2024-01-01T00:00:00.000Z`; cqlsh shows `2024-01-01 00:00:00.000000+0000`. A value with no
    /// zone is read as UTC, the zone every Cassandra timestamp is stored in.
    private static func timestampCandidates(_ value: String) -> [String] {
        guard value.count >= 10 else { return [] }
        if value.count == 10 { return [value + "T00:00:00Z"] }
        var normalized = value.replacingOccurrences(of: " ", with: "T")
        if normalized.hasSuffix("+0000") {
            normalized = String(normalized.dropLast(5)) + "Z"
        }
        let timePart = normalized.dropFirst(11)
        let hasZone = timePart.contains("Z") || timePart.contains("+") || timePart.contains("-")
        return hasZone ? [normalized] : [normalized + "Z"]
    }

    static func dateDays(_ text: String) throws -> UInt32 {
        let parts = trimmed(text).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[1].count == 2, parts[2].count == 2
        else { throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.date.name) }

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else {
            throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.date.name)
        }
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
            throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.date.name)
        }
        let days = Int64((date.timeIntervalSince1970 / Double(secondsPerDay)).rounded(.down))
        return UInt32(days + dateEpochBias)
    }

    static func timeNanoseconds(_ text: String) throws -> Int64 {
        let value = trimmed(text)
        let clock = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = clock[0].split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let hours = Int64(fields[0]), let minutes = Int64(fields[1]), let seconds = Int64(fields[2]),
              (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds)
        else { throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.time.name) }

        var fraction: Int64 = 0
        if clock.count == 2 {
            let digits = clock[1]
            guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCII), let parsed = Int64(digits) else {
                throw CassandraValueRefusal.invalid(text, typeName: CassandraParameterType.time.name)
            }
            fraction = parsed * Int64(pow(10, Double(9 - digits.count)))
        }
        return ((hours * 60 + minutes) * 60 + seconds) * nanosecondsPerSecond + fraction
    }

    /// Every digit the value holds, in groups of three, because the text is what a save binds back: a `time`
    /// primary key shown to the millisecond would name a different row once written.
    static func timeText(nanoseconds: Int64) -> String {
        let totalSeconds = nanoseconds / nanosecondsPerSecond
        let clock = String(
            format: "%02lld:%02lld:%02lld", totalSeconds / 3_600, (totalSeconds % 3_600) / 60, totalSeconds % 60
        )
        let fraction = nanoseconds % nanosecondsPerSecond
        guard fraction > 0 else { return clock }
        if fraction.isMultiple(of: 1_000_000) {
            return clock + String(format: ".%03lld", fraction / 1_000_000)
        }
        if fraction.isMultiple(of: 1_000) {
            return clock + String(format: ".%06lld", fraction / 1_000)
        }
        return clock + String(format: ".%09lld", fraction)
    }

    private static func hexData(_ text: String) -> Data? {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("0x") else { return nil }
        let digits = Array(lowered.dropFirst(2))
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }
}

extension CassandraParameterType {
    var name: String {
        switch self {
        case .text: return "text"
        case .tinyint: return "tinyint"
        case .smallint: return "smallint"
        case .int: return "int"
        case .bigint: return "bigint"
        case .counter: return "counter"
        case .float: return "float"
        case .double: return "double"
        case .boolean: return "boolean"
        case .uuid: return "uuid"
        case .timeuuid: return "timeuuid"
        case .timestamp: return "timestamp"
        case .date: return "date"
        case .time: return "time"
        case .inet: return "inet"
        case .blob: return "blob"
        case .decimal: return "decimal"
        case .varint: return "varint"
        case .unsupported(let name): return name
        }
    }
}
