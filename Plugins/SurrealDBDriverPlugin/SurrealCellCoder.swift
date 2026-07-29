//
//  SurrealCellCoder.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public enum SurrealCellCoder {
    private static let magic: [UInt8] = [0x53, 0x44, 0x42, 0x56]

    public static func parameter(_ value: SurrealValue) -> PluginCellValue {
        var payload = Data(magic)
        payload.append(SurrealCBOR.encode(value))
        return .bytes(payload)
    }

    public static func value(from cell: PluginCellValue) -> SurrealValue {
        switch cell {
        case .null:
            return .null
        case let .text(text):
            return .string(text)
        case let .bytes(data):
            guard data.count > magic.count, [UInt8](data.prefix(magic.count)) == magic else {
                return .bytes(data)
            }
            let payload = data.dropFirst(magic.count)
            guard let decoded = try? SurrealCBOR.decode(Data(payload)) else { return .bytes(data) }
            return decoded
        }
    }

    public static func value(from cell: PluginCellValue, kind: SurrealFieldKind?) -> SurrealValue {
        switch cell {
        case .null:
            return (kind?.isOptional ?? true) ? .none : .null
        case let .bytes(data):
            return .bytes(data)
        case let .text(text):
            return value(fromText: text, kind: kind)
        }
    }

    // MARK: - Text coercion

    private static func value(fromText text: String, kind: SurrealFieldKind?) -> SurrealValue {
        guard let kind else { return inferred(from: text) }

        if text.isEmpty, kind.base != .string, kind.base != .any {
            return kind.isOptional ? .none : .null
        }

        switch kind.base {
        case .int:
            guard let number = Int64(text.trimmingCharacters(in: .whitespaces)) else { return .string(text) }
            return .int(number)
        case .float, .number:
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { return .string(text) }
            return .double(number)
        case .decimal:
            return .decimal(text.trimmingCharacters(in: .whitespaces))
        case .bool:
            switch text.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "1", "yes":
                return .bool(true)
            case "false", "0", "no":
                return .bool(false)
            default:
                return .string(text)
            }
        case .datetime:
            return datetime(from: text) ?? .string(text)
        case .duration:
            return duration(from: text) ?? .string(text)
        case .uuid:
            guard let value = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else { return .string(text) }
            return .uuid(value)
        case .record:
            guard let record = SurrealQL.parseRecordId(text, fallbackTable: kind.recordTable) else {
                return .string(text)
            }
            return .recordId(record)
        case .object, .array, .set, .geometry:
            return json(from: text) ?? .string(text)
        case .string:
            return .string(text)
        case .bytes:
            guard let data = Data(base64Encoded: text) else { return .string(text) }
            return .bytes(data)
        case .any:
            return inferred(from: text)
        }
    }

    private static func inferred(from text: String) -> SurrealValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .string(text) }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let value = json(from: trimmed) { return value }
        }
        if let integer = Int64(trimmed), String(integer) == trimmed {
            return .int(integer)
        }
        switch trimmed.lowercased() {
        case "true":
            return .bool(true)
        case "false":
            return .bool(false)
        default:
            return .string(text)
        }
    }

    public static func json(from text: String) -> SurrealValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return surreal(fromJson: object)
    }

    private static func surreal(fromJson object: Any) -> SurrealValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let integer = Int64(exactly: number) {
                return .int(integer)
            }
            return .double(number.doubleValue)
        case let text as String:
            return .string(text)
        case let items as [Any]:
            return .array(items.map(surreal(fromJson:)))
        case let map as [String: Any]:
            let pairs = map
                .sorted { $0.key < $1.key }
                .map { (key: $0.key, value: surreal(fromJson: $0.value)) }
            return .object(pairs)
        default:
            return .null
        }
    }

    public static func datetime(from text: String) -> SurrealValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let split = splitFraction(trimmed)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: split.whole) else { return nil }

        return .datetime(seconds: Int64(date.timeIntervalSince1970.rounded()), nanoseconds: split.nanoseconds)
    }

    private static func splitFraction(_ text: String) -> (whole: String, nanoseconds: UInt32) {
        guard let dot = text.firstIndex(of: ".") else { return (text, 0) }

        var digits = ""
        var index = text.index(after: dot)
        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard !digits.isEmpty else { return (text, 0) }

        let padded = digits.count >= 9
            ? String(digits.prefix(9))
            : digits + String(repeating: "0", count: 9 - digits.count)
        let whole = String(text[text.startIndex..<dot]) + String(text[index...])
        return (whole, UInt32(padded) ?? 0)
    }

    public static func duration(from text: String) -> SurrealValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let units: [(suffix: String, seconds: Int64, nanos: Int64)] = [
            ("ns", 0, 1),
            ("µs", 0, 1000),
            ("us", 0, 1000),
            ("ms", 0, 1_000_000),
            ("w", 604_800, 0),
            ("d", 86_400, 0),
            ("h", 3600, 0),
            ("m", 60, 0),
            ("s", 1, 0)
        ]

        var totalSeconds: Int64 = 0
        var totalNanos: Int64 = 0
        var number = ""
        var index = trimmed.startIndex
        var matchedAny = false

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber {
                number.append(character)
                index = trimmed.index(after: index)
                continue
            }

            guard let amount = Int64(number) else { return nil }
            let remainder = trimmed[index...]
            guard let unit = units.first(where: { remainder.hasPrefix($0.suffix) }) else { return nil }

            totalSeconds += amount * unit.seconds
            totalNanos += amount * unit.nanos
            number = ""
            matchedAny = true
            index = trimmed.index(index, offsetBy: unit.suffix.count)
        }

        guard matchedAny, number.isEmpty else { return nil }
        totalSeconds += totalNanos / 1_000_000_000
        totalNanos %= 1_000_000_000
        return .duration(seconds: totalSeconds, nanoseconds: UInt32(clamping: totalNanos))
    }
}
