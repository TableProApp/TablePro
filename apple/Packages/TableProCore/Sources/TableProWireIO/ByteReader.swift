import Foundation

public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = min(max(offset, 0), bytes.count)
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func u8() throws(WireIOError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws(WireIOError) -> UInt16 {
        try bigEndian(UInt16.self)
    }

    public mutating func u32() throws(WireIOError) -> UInt32 {
        try bigEndian(UInt32.self)
    }

    public mutating func u64() throws(WireIOError) -> UInt64 {
        try bigEndian(UInt64.self)
    }

    public mutating func take(_ count: some BinaryInteger) throws(WireIOError) -> [UInt8] {
        let length = try checkedCount(count)
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    public mutating func skip(_ count: some BinaryInteger) throws(WireIOError) {
        offset += try checkedCount(count)
    }

    // A declared element count can only be honest if the bytes left could hold that many elements.
    public func elementCount(_ declared: some BinaryInteger, minimumElementSize: Int) throws(WireIOError) -> Int {
        let ceiling = remaining / max(minimumElementSize, 1)
        return try WireLength.checked(declared, limit: ceiling)
    }

    private func require(_ count: Int) throws(WireIOError) {
        guard remaining >= count else { throw .truncated(needed: count, available: remaining) }
    }

    private func checkedCount(_ count: some BinaryInteger) throws(WireIOError) -> Int {
        guard let length = Int(exactly: count), length >= 0 else {
            throw .lengthOutOfRange(String(count), limit: remaining)
        }
        try require(length)
        return length
    }

    private mutating func bigEndian<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type) throws(WireIOError) -> Value {
        let width = MemoryLayout<Value>.size
        try require(width)
        var value: Value = 0
        for index in offset..<(offset + width) {
            value = value << 8 | Value(bytes[index])
        }
        offset += width
        return value
    }
}
