import Foundation

public indirect enum PackStreamValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case bytes(Data)
    case string(String)
    case list([PackStreamValue])
    case map([String: PackStreamValue])
    case structure(tag: UInt8, fields: [PackStreamValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var listValue: [PackStreamValue]? {
        if case .list(let value) = self { return value }
        return nil
    }

    public var mapValue: [String: PackStreamValue]? {
        if case .map(let value) = self { return value }
        return nil
    }
}

public enum PackStreamError: Error, Equatable, Sendable {
    case truncated
    case unknownMarker(UInt8)
    case invalidString
    case nonStringKey
    case nestedTooDeeply
}

public enum PackStreamEncoder {
    public static func encode(_ value: PackStreamValue) -> Data {
        var data = Data()
        write(value, into: &data)
        return data
    }

    public static func write(_ value: PackStreamValue, into data: inout Data) {
        switch value {
        case .null:
            data.append(0xC0)
        case .bool(let flag):
            data.append(flag ? 0xC3 : 0xC2)
        case .int(let number):
            writeInt(number, into: &data)
        case .float(let number):
            data.append(0xC1)
            appendBigEndian(number.bitPattern, into: &data)
        case .bytes(let bytes):
            writeHeader(count: bytes.count, tiny: nil, markers: (0xCC, 0xCD, 0xCE), into: &data)
            data.append(bytes)
        case .string(let text):
            let utf8 = Data(text.utf8)
            writeHeader(count: utf8.count, tiny: 0x80, markers: (0xD0, 0xD1, 0xD2), into: &data)
            data.append(utf8)
        case .list(let items):
            writeHeader(count: items.count, tiny: 0x90, markers: (0xD4, 0xD5, 0xD6), into: &data)
            for item in items { write(item, into: &data) }
        case .map(let entries):
            writeHeader(count: entries.count, tiny: 0xA0, markers: (0xD8, 0xD9, 0xDA), into: &data)
            for key in entries.keys.sorted() {
                write(.string(key), into: &data)
                write(entries[key] ?? .null, into: &data)
            }
        case .structure(let tag, let fields):
            precondition(fields.count < 16, "Bolt has no marker for a structure over 15 fields")
            data.append(0xB0 | UInt8(fields.count))
            data.append(tag)
            for field in fields { write(field, into: &data) }
        }
    }

    private static func writeInt(_ number: Int64, into data: inout Data) {
        switch number {
        case -16 ... 127:
            data.append(UInt8(bitPattern: Int8(number)))
        case Int64(Int8.min) ... Int64(Int8.max):
            data.append(0xC8)
            data.append(UInt8(bitPattern: Int8(number)))
        case Int64(Int16.min) ... Int64(Int16.max):
            data.append(0xC9)
            appendBigEndian(UInt16(bitPattern: Int16(number)), into: &data)
        case Int64(Int32.min) ... Int64(Int32.max):
            data.append(0xCA)
            appendBigEndian(UInt32(bitPattern: Int32(number)), into: &data)
        default:
            data.append(0xCB)
            appendBigEndian(UInt64(bitPattern: number), into: &data)
        }
    }

    private static func writeHeader(
        count: Int,
        tiny: UInt8?,
        markers: (UInt8, UInt8, UInt8),
        into data: inout Data
    ) {
        if let tiny, count < 16 {
            data.append(tiny | UInt8(count))
        } else if count <= Int(UInt8.max) {
            data.append(markers.0)
            data.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(markers.1)
            appendBigEndian(UInt16(count), into: &data)
        } else {
            data.append(markers.2)
            appendBigEndian(UInt32(count), into: &data)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

public struct PackStreamDecoder {
    // Each level is a stack frame, so a server cannot overflow the stack with a deeply nested list.
    public static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var isAtEnd: Bool { index >= bytes.count }

    public static func decode(_ data: Data) throws -> PackStreamValue {
        var decoder = PackStreamDecoder(data)
        return try decoder.next()
    }

    public mutating func next() throws -> PackStreamValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw PackStreamError.nestedTooDeeply }
        let marker = try byte()
        switch marker {
        case 0x00 ... 0x7F:
            return .int(Int64(marker))
        case 0xF0 ... 0xFF:
            return .int(Int64(Int8(bitPattern: marker)))
        case 0x80 ... 0x8F:
            return try string(count: Int(marker & 0x0F))
        case 0x90 ... 0x9F:
            return try list(count: Int(marker & 0x0F))
        case 0xA0 ... 0xAF:
            return try map(count: Int(marker & 0x0F))
        case 0xB0 ... 0xBF:
            let tag = try byte()
            var fields: [PackStreamValue] = []
            for _ in 0 ..< Int(marker & 0x0F) { fields.append(try next()) }
            return .structure(tag: tag, fields: fields)
        case 0xC0:
            return .null
        case 0xC1:
            return .float(Double(bitPattern: try integer(UInt64.self)))
        case 0xC2:
            return .bool(false)
        case 0xC3:
            return .bool(true)
        case 0xC8:
            return .int(Int64(Int8(bitPattern: try byte())))
        case 0xC9:
            return .int(Int64(Int16(bitPattern: try integer(UInt16.self))))
        case 0xCA:
            return .int(Int64(Int32(bitPattern: try integer(UInt32.self))))
        case 0xCB:
            return .int(Int64(bitPattern: try integer(UInt64.self)))
        case 0xCC:
            return .bytes(Data(try take(Int(try byte()))))
        case 0xCD:
            return .bytes(Data(try take(Int(try integer(UInt16.self)))))
        case 0xCE:
            return .bytes(Data(try take(Int(try integer(UInt32.self)))))
        case 0xD0:
            return try string(count: Int(try byte()))
        case 0xD1:
            return try string(count: Int(try integer(UInt16.self)))
        case 0xD2:
            return try string(count: Int(try integer(UInt32.self)))
        case 0xD4:
            return try list(count: Int(try byte()))
        case 0xD5:
            return try list(count: Int(try integer(UInt16.self)))
        case 0xD6:
            return try list(count: Int(try integer(UInt32.self)))
        case 0xD8:
            return try map(count: Int(try byte()))
        case 0xD9:
            return try map(count: Int(try integer(UInt16.self)))
        case 0xDA:
            return try map(count: Int(try integer(UInt32.self)))
        default:
            throw PackStreamError.unknownMarker(marker)
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard index < bytes.count else { throw PackStreamError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, bytes.count - index >= count else { throw PackStreamError.truncated }
        defer { index += count }
        return bytes[index ..< index + count]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try take(MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T($1) }
    }

    private mutating func string(count: Int) throws -> PackStreamValue {
        guard let text = String(bytes: try take(count), encoding: .utf8) else {
            throw PackStreamError.invalidString
        }
        return .string(text)
    }

    private mutating func list(count: Int) throws -> PackStreamValue {
        var items: [PackStreamValue] = []
        items.reserveCapacity(min(count, 1_024))
        for _ in 0 ..< count { items.append(try next()) }
        return .list(items)
    }

    private mutating func map(count: Int) throws -> PackStreamValue {
        var entries: [String: PackStreamValue] = [:]
        for _ in 0 ..< count {
            guard case .string(let key) = try next() else { throw PackStreamError.nonStringKey }
            entries[key] = try next()
        }
        return .map(entries)
    }
}
