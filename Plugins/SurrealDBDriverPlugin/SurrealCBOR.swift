//
//  SurrealCBOR.swift
//  SurrealDBDriverPlugin
//

import Foundation

public enum SurrealCBORError: Error, Equatable {
    case truncatedInput
    case indefiniteLengthUnsupported
    case unsupportedSimpleValue(UInt8)
    case invalidUTF8
    case malformedTag(UInt64)
    case lengthOverflow
    case nestingTooDeep
}

public enum SurrealCBORTag {
    public static let none: UInt64 = 6
    public static let table: UInt64 = 7
    public static let recordId: UInt64 = 8
    public static let uuidString: UInt64 = 9
    public static let decimal: UInt64 = 10
    public static let datetimeString: UInt64 = 0
    public static let datetimeCompact: UInt64 = 12
    public static let durationString: UInt64 = 13
    public static let durationCompact: UInt64 = 14
    public static let uuidBinary: UInt64 = 37
    public static let range: UInt64 = 49
    public static let boundIncluded: UInt64 = 50
    public static let boundExcluded: UInt64 = 51
    public static let geometryPoint: UInt64 = 88
    public static let geometryCollection: UInt64 = 94
}

public enum SurrealCBOR {
    private static let maxNestingDepth = 256

    public static func decode(_ data: Data) throws -> SurrealValue {
        var cursor = Cursor(data)
        return try decodeItem(&cursor, depth: 0)
    }

    public static func encode(_ value: SurrealValue) -> Data {
        var out = Data()
        encodeItem(value, into: &out)
        return out
    }

    // MARK: - Cursor

    private struct Cursor {
        let bytes: [UInt8]
        var index: Int = 0

        init(_ data: Data) {
            self.bytes = [UInt8](data)
        }

        mutating func nextByte() throws -> UInt8 {
            guard index < bytes.count else { throw SurrealCBORError.truncatedInput }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func next(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= bytes.count - index else { throw SurrealCBORError.truncatedInput }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }
    }

    // MARK: - Decoding

    private static func readArgument(_ cursor: inout Cursor, info: UInt8) throws -> UInt64 {
        switch info {
        case 0...23:
            return UInt64(info)
        case 24:
            return UInt64(try cursor.nextByte())
        case 25:
            return try readUInt(&cursor, byteCount: 2)
        case 26:
            return try readUInt(&cursor, byteCount: 4)
        case 27:
            return try readUInt(&cursor, byteCount: 8)
        case 31:
            throw SurrealCBORError.indefiniteLengthUnsupported
        default:
            throw SurrealCBORError.truncatedInput
        }
    }

    private static func readUInt(_ cursor: inout Cursor, byteCount: Int) throws -> UInt64 {
        let raw = try cursor.next(byteCount)
        return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func checkedCount(_ argument: UInt64) throws -> Int {
        guard let count = Int(exactly: argument) else { throw SurrealCBORError.lengthOverflow }
        return count
    }

    private static func decodeItem(_ cursor: inout Cursor, depth: Int) throws -> SurrealValue {
        guard depth < maxNestingDepth else { throw SurrealCBORError.nestingTooDeep }
        let initial = try cursor.nextByte()
        let major = initial >> 5
        let info = initial & 0x1F

        switch major {
        case 0:
            let argument = try readArgument(&cursor, info: info)
            guard let value = Int64(exactly: argument) else { return .double(Double(argument)) }
            return .int(value)
        case 1:
            let argument = try readArgument(&cursor, info: info)
            guard let magnitude = Int64(exactly: argument) else { return .double(-1 - Double(argument)) }
            return .int(-1 - magnitude)
        case 2:
            let count = try checkedCount(try readArgument(&cursor, info: info))
            return .bytes(Data(try cursor.next(count)))
        case 3:
            let count = try checkedCount(try readArgument(&cursor, info: info))
            guard let text = String(bytes: try cursor.next(count), encoding: .utf8) else {
                throw SurrealCBORError.invalidUTF8
            }
            return .string(text)
        case 4:
            let count = try checkedCount(try readArgument(&cursor, info: info))
            var items: [SurrealValue] = []
            items.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                items.append(try decodeItem(&cursor, depth: depth + 1))
            }
            return .array(items)
        case 5:
            let count = try checkedCount(try readArgument(&cursor, info: info))
            var pairs: [(key: String, value: SurrealValue)] = []
            pairs.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                let key = try decodeItem(&cursor, depth: depth + 1)
                let value = try decodeItem(&cursor, depth: depth + 1)
                pairs.append((key: key.stringValue ?? Self.fallbackKey(key), value: value))
            }
            return .object(pairs)
        case 6:
            let tag = try readArgument(&cursor, info: info)
            let inner = try decodeItem(&cursor, depth: depth + 1)
            return try interpret(tag: tag, inner: inner)
        case 7:
            return try decodeSimple(&cursor, info: info)
        default:
            throw SurrealCBORError.truncatedInput
        }
    }

    private static func fallbackKey(_ value: SurrealValue) -> String {
        switch value {
        case let .int(number):
            return String(number)
        case let .bool(flag):
            return String(flag)
        default:
            return ""
        }
    }

    private static func decodeSimple(_ cursor: inout Cursor, info: UInt8) throws -> SurrealValue {
        switch info {
        case 20:
            return .bool(false)
        case 21:
            return .bool(true)
        case 22:
            return .null
        case 23:
            return .none
        case 25:
            return .double(halfToDouble(UInt16(try readUInt(&cursor, byteCount: 2))))
        case 26:
            let raw = UInt32(try readUInt(&cursor, byteCount: 4))
            return .double(Double(Float(bitPattern: raw)))
        case 27:
            let raw = try readUInt(&cursor, byteCount: 8)
            return .double(Double(bitPattern: raw))
        default:
            throw SurrealCBORError.unsupportedSimpleValue(info)
        }
    }

    private static func halfToDouble(_ raw: UInt16) -> Double {
        let sign = (raw & 0x8000) != 0 ? -1.0 : 1.0
        let exponent = Int((raw & 0x7C00) >> 10)
        let fraction = Double(raw & 0x03FF)

        if exponent == 0 {
            return sign * pow(2.0, -14) * (fraction / 1024)
        }
        if exponent == 0x1F {
            return fraction == 0 ? sign * Double.infinity : Double.nan
        }
        return sign * pow(2.0, Double(exponent - 15)) * (1 + fraction / 1024)
    }

    private static func interpret(tag: UInt64, inner: SurrealValue) throws -> SurrealValue {
        switch tag {
        case SurrealCBORTag.none:
            return .none
        case SurrealCBORTag.table:
            guard let name = inner.stringValue else { throw SurrealCBORError.malformedTag(tag) }
            return .table(name)
        case SurrealCBORTag.recordId:
            return try decodeRecordId(inner, tag: tag)
        case SurrealCBORTag.uuidString:
            guard let text = inner.stringValue, let value = UUID(uuidString: text) else {
                throw SurrealCBORError.malformedTag(tag)
            }
            return .uuid(value)
        case SurrealCBORTag.uuidBinary:
            return try decodeBinaryUUID(inner, tag: tag)
        case SurrealCBORTag.decimal:
            guard let text = inner.stringValue else { throw SurrealCBORError.malformedTag(tag) }
            return .decimal(text)
        case SurrealCBORTag.datetimeString:
            guard let text = inner.stringValue else { throw SurrealCBORError.malformedTag(tag) }
            return .string(text)
        case SurrealCBORTag.datetimeCompact:
            let parts = try secondsAndNanos(inner, tag: tag)
            return .datetime(seconds: parts.seconds, nanoseconds: parts.nanoseconds)
        case SurrealCBORTag.durationString:
            guard let text = inner.stringValue else { throw SurrealCBORError.malformedTag(tag) }
            return .string(text)
        case SurrealCBORTag.durationCompact:
            let parts = try secondsAndNanos(inner, tag: tag)
            return .duration(seconds: parts.seconds, nanoseconds: parts.nanoseconds)
        case SurrealCBORTag.range:
            return try decodeRange(inner, tag: tag)
        case SurrealCBORTag.boundIncluded, SurrealCBORTag.boundExcluded:
            return .tagged(tag: tag, value: inner)
        case SurrealCBORTag.geometryPoint...SurrealCBORTag.geometryCollection:
            return .tagged(tag: tag, value: inner)
        default:
            return inner
        }
    }

    private static func decodeRecordId(_ inner: SurrealValue, tag: UInt64) throws -> SurrealValue {
        guard let parts = inner.arrayValues, parts.count == 2, let table = parts[0].stringValue else {
            throw SurrealCBORError.malformedTag(tag)
        }
        return .recordId(SurrealRecordID(table: table, id: parts[1]))
    }

    private static func decodeBinaryUUID(_ inner: SurrealValue, tag: UInt64) throws -> SurrealValue {
        if let text = inner.stringValue, let value = UUID(uuidString: text) {
            return .uuid(value)
        }
        guard case let .bytes(data) = inner, data.count == 16 else {
            throw SurrealCBORError.malformedTag(tag)
        }
        let bytes = [UInt8](data)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return .uuid(uuid)
    }

    private static func secondsAndNanos(
        _ inner: SurrealValue,
        tag: UInt64
    ) throws -> (seconds: Int64, nanoseconds: UInt32) {
        guard let parts = inner.arrayValues else { throw SurrealCBORError.malformedTag(tag) }
        let seconds = parts.count > 0 ? (parts[0].intValue ?? 0) : 0
        let nanos = parts.count > 1 ? (parts[1].intValue ?? 0) : 0
        return (seconds, UInt32(clamping: nanos))
    }

    private static func decodeRange(_ inner: SurrealValue, tag: UInt64) throws -> SurrealValue {
        guard let parts = inner.arrayValues, parts.count == 2 else { throw SurrealCBORError.malformedTag(tag) }
        return .range(from: bound(from: parts[0]), to: bound(from: parts[1]))
    }

    private static func bound(from value: SurrealValue) -> SurrealBound? {
        guard case let .tagged(tag, inner) = value else { return nil }
        switch tag {
        case SurrealCBORTag.boundIncluded:
            return SurrealBound(value: inner, isInclusive: true)
        case SurrealCBORTag.boundExcluded:
            return SurrealBound(value: inner, isInclusive: false)
        default:
            return nil
        }
    }

    // MARK: - Encoding

    private static func encodeItem(_ value: SurrealValue, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xF6)
        case .none:
            encodeHead(major: 6, argument: SurrealCBORTag.none, into: &out)
            out.append(0xF6)
        case let .bool(flag):
            out.append(flag ? 0xF5 : 0xF4)
        case let .int(number):
            encodeInt(number, into: &out)
        case let .double(number):
            out.append(0xFB)
            appendBigEndian(number.bitPattern, byteCount: 8, into: &out)
        case let .string(text):
            let utf8 = Array(text.utf8)
            encodeHead(major: 3, argument: UInt64(utf8.count), into: &out)
            out.append(contentsOf: utf8)
        case let .bytes(data):
            encodeHead(major: 2, argument: UInt64(data.count), into: &out)
            out.append(data)
        case let .array(items):
            encodeHead(major: 4, argument: UInt64(items.count), into: &out)
            for item in items {
                encodeItem(item, into: &out)
            }
        case let .object(pairs):
            encodeHead(major: 5, argument: UInt64(pairs.count), into: &out)
            for pair in pairs {
                encodeItem(.string(pair.key), into: &out)
                encodeItem(pair.value, into: &out)
            }
        case let .recordId(record):
            encodeHead(major: 6, argument: SurrealCBORTag.recordId, into: &out)
            encodeItem(.array([.string(record.table), record.id]), into: &out)
        case let .table(name):
            encodeHead(major: 6, argument: SurrealCBORTag.table, into: &out)
            encodeItem(.string(name), into: &out)
        case let .uuid(value):
            encodeHead(major: 6, argument: SurrealCBORTag.uuidString, into: &out)
            encodeItem(.string(value.uuidString.lowercased()), into: &out)
        case let .decimal(text):
            encodeHead(major: 6, argument: SurrealCBORTag.decimal, into: &out)
            encodeItem(.string(text), into: &out)
        case let .datetime(seconds, nanoseconds):
            encodeHead(major: 6, argument: SurrealCBORTag.datetimeCompact, into: &out)
            encodeItem(.array([.int(seconds), .int(Int64(nanoseconds))]), into: &out)
        case let .duration(seconds, nanoseconds):
            encodeHead(major: 6, argument: SurrealCBORTag.durationCompact, into: &out)
            encodeItem(.array([.int(seconds), .int(Int64(nanoseconds))]), into: &out)
        case let .tagged(tag, inner):
            encodeHead(major: 6, argument: tag, into: &out)
            encodeItem(inner, into: &out)
        case let .range(from, to):
            encodeHead(major: 6, argument: SurrealCBORTag.range, into: &out)
            encodeHead(major: 4, argument: 2, into: &out)
            encodeBound(from, into: &out)
            encodeBound(to, into: &out)
        }
    }

    private static func encodeBound(_ bound: SurrealBound?, into out: inout Data) {
        guard let bound else {
            out.append(0xF6)
            return
        }
        let tag = bound.isInclusive ? SurrealCBORTag.boundIncluded : SurrealCBORTag.boundExcluded
        encodeHead(major: 6, argument: tag, into: &out)
        encodeItem(bound.value, into: &out)
    }

    private static func encodeInt(_ value: Int64, into out: inout Data) {
        if value >= 0 {
            encodeHead(major: 0, argument: UInt64(value), into: &out)
            return
        }
        let magnitude = UInt64(bitPattern: Int64(-1) - value)
        encodeHead(major: 1, argument: magnitude, into: &out)
    }

    private static func encodeHead(major: UInt8, argument: UInt64, into out: inout Data) {
        let prefix = major << 5
        switch argument {
        case 0...23:
            out.append(prefix | UInt8(argument))
        case 24...UInt64(UInt8.max):
            out.append(prefix | 24)
            out.append(UInt8(argument))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            out.append(prefix | 25)
            appendBigEndian(argument, byteCount: 2, into: &out)
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            out.append(prefix | 26)
            appendBigEndian(argument, byteCount: 4, into: &out)
        default:
            out.append(prefix | 27)
            appendBigEndian(argument, byteCount: 8, into: &out)
        }
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, into out: inout Data) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
