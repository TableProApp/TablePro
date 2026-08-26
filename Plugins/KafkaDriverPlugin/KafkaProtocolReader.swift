import Foundation

struct KafkaProtocolReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        offset = 0
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    mutating func int8() throws -> Int8 {
        try require(1)
        defer { offset += 1 }
        return Int8(bitPattern: bytes[offset])
    }

    mutating func uint8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func boolean() throws -> Bool {
        try uint8() != 0
    }

    mutating func int16() throws -> Int16 {
        Int16(bitPattern: try unsigned(UInt16.self))
    }

    mutating func int32() throws -> Int32 {
        Int32(bitPattern: try unsigned(UInt32.self))
    }

    mutating func int64() throws -> Int64 {
        Int64(bitPattern: try unsigned(UInt64.self))
    }

    mutating func uint32() throws -> UInt32 {
        try unsigned(UInt32.self)
    }

    mutating func uuid() throws -> KafkaUUID {
        try require(16)
        defer { offset += 16 }
        return KafkaUUID(bytes: Array(bytes[offset ..< offset + 16]))
    }

    /// Unsigned LEB128, the framing varint. Distinct from `varint`, which is zig-zag signed
    /// and appears only inside a record batch's records.
    mutating func unsignedVarint() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let byte = try uint8()
            guard shift <= 28 else { throw KafkaError.malformedResponse("unsigned varint overflows 32 bits") }
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func unsignedVarlong() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try uint8()
            guard shift <= 63 else { throw KafkaError.malformedResponse("unsigned varlong overflows 64 bits") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func varint() throws -> Int32 {
        let raw = try unsignedVarint()
        return Int32(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    mutating func varlong() throws -> Int64 {
        let raw = try unsignedVarlong()
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    mutating func legacyString() throws -> String {
        let length = Int(try int16())
        guard length >= 0 else { throw KafkaError.malformedResponse("non-nullable string was null") }
        return try string(length: length)
    }

    mutating func nullableLegacyString() throws -> String? {
        let length = Int(try int16())
        if length < 0 { return nil }
        return try string(length: length)
    }

    mutating func compactString() throws -> String {
        guard let value = try nullableCompactString() else {
            throw KafkaError.malformedResponse("non-nullable compact string was null")
        }
        return value
    }

    /// A compact string is length+1, and 0 means null. `0xff` is the legacy null and is not
    /// valid here; treating it as one silently consumes the following bytes.
    mutating func nullableCompactString() throws -> String? {
        let encoded = Int(try unsignedVarint())
        if encoded == 0 { return nil }
        return try string(length: encoded - 1)
    }

    mutating func nullableLegacyBytes() throws -> Data? {
        let length = Int(try int32())
        if length < 0 { return nil }
        return try data(length: length)
    }

    mutating func nullableCompactBytes() throws -> Data? {
        let encoded = Int(try unsignedVarint())
        if encoded == 0 { return nil }
        return try data(length: encoded - 1)
    }

    mutating func compactArrayCount() throws -> Int? {
        let encoded = Int(try unsignedVarint())
        if encoded == 0 { return nil }
        return encoded - 1
    }

    mutating func legacyArrayCount() throws -> Int? {
        let count = Int(try int32())
        if count < 0 { return nil }
        return count
    }

    mutating func array<T>(compact: Bool, _ element: (inout KafkaProtocolReader) throws -> T) throws -> [T] {
        let count = compact ? try compactArrayCount() : try legacyArrayCount()
        guard let count else { return [] }
        guard count <= remaining + 1 else {
            throw KafkaError.malformedResponse("array claims \(count) elements, \(remaining) bytes left")
        }
        var items: [T] = []
        items.reserveCapacity(min(count, 1024))
        for _ in 0 ..< count {
            items.append(try element(&self))
        }
        return items
    }

    /// Tagged fields close every struct in a flexible message. Unknown tags are skipped by
    /// size, which is what lets a newer broker add a field without breaking this client.
    mutating func taggedFields() throws {
        let count = Int(try unsignedVarint())
        for _ in 0 ..< count {
            _ = try unsignedVarint()
            let size = Int(try unsignedVarint())
            try skip(size)
        }
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }

    private mutating func string(length: Int) throws -> String {
        let raw = try data(length: length)
        guard let value = String(data: raw, encoding: .utf8) else {
            throw KafkaError.malformedResponse("string is not valid UTF-8")
        }
        return value
    }

    private mutating func data(length: Int) throws -> Data {
        guard length >= 0 else { throw KafkaError.malformedResponse("negative length \(length)") }
        try require(length)
        defer { offset += length }
        return Data(bytes[offset ..< offset + length])
    }

    private mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        try require(width)
        var value: T = 0
        for index in 0 ..< width {
            value = (value << 8) | T(bytes[offset + index])
        }
        offset += width
        return value
    }

    private func require(_ count: Int) throws {
        guard count >= 0, offset + count <= bytes.count else {
            throw KafkaError.truncatedResponse(needed: count, available: remaining)
        }
    }
}
