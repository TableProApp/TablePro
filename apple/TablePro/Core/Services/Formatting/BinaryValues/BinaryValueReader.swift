//
//  BinaryValueReader.swift
//  TablePro
//

import Foundation

internal struct BinaryValueDecodeError: Error, Equatable, Sendable {
    internal enum Kind: Equatable, Sendable {
        case unexpectedEnd
        case invalidByte(UInt8)
        case trailingBytes(Int)
        case nestingTooDeep
        case tooLarge
        case integerOutOfRange
        case invalidField
        case unmatchedGroupEnd
        case unknownVersion(UInt32)
        case unknownReference(Int)
        case indexOutOfRange(Int)
        case invalidLength
        case schemaMissing
    }

    let kind: Kind
    let offset: Int

    var reason: String {
        switch kind {
        case .unexpectedEnd:
            return String(format: String(localized: "The value ends early, at byte %lld."), offset)
        case .invalidByte(let byte):
            return String(
                format: String(localized: "Byte 0x%@ at offset %lld is not valid here."),
                String(format: "%02X", byte),
                offset
            )
        case .trailingBytes(let count):
            return String(format: String(localized: "%lld bytes follow the end of the value."), count)
        case .nestingTooDeep:
            return String(localized: "The value is nested too deeply to show.")
        case .tooLarge:
            return String(localized: "The value is too large to decode.")
        case .integerOutOfRange:
            return String(format: String(localized: "The integer at byte %lld is out of range."), offset)
        case .invalidField:
            return String(format: String(localized: "Byte %lld does not start a valid field."), offset)
        case .unmatchedGroupEnd:
            return String(format: String(localized: "The group end at byte %lld matches no group start."), offset)
        case .unknownVersion(let version):
            return String(format: String(localized: "The header names version %lld, which this format does not have."), Int(version))
        case .unknownReference(let index):
            return String(
                format: String(localized: "Byte %lld refers back to item %lld, which comes later or not at all."),
                offset,
                index
            )
        case .indexOutOfRange(let index):
            return String(format: String(localized: "Byte %lld picks entry %lld, which the schema does not have."), offset, index)
        case .invalidLength:
            return String(format: String(localized: "The length at byte %lld is negative."), offset)
        case .schemaMissing:
            return String(localized: "The Avro schema for this column is missing. Choose the schema file again.")
        }
    }
}

internal struct BinaryValueReader {
    private let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
        end = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, end: Int) {
        self.bytes = bytes
        self.offset = offset
        self.end = end
    }

    var remaining: Int { end - offset }
    var isAtEnd: Bool { offset >= end }

    func peekByte() -> UInt8? {
        offset < end ? bytes[offset] : nil
    }

    // Offsets stay in whole-value terms, so an error inside a nested field names its real byte.
    func window(_ count: Int) throws -> BinaryValueReader {
        try require(count)
        return BinaryValueReader(bytes: bytes, offset: offset, end: offset + count)
    }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    func error(_ kind: BinaryValueDecodeError.Kind) -> BinaryValueDecodeError {
        BinaryValueDecodeError(kind: kind, offset: kind == .unexpectedEnd ? end : offset)
    }

    mutating func readByte() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        try require(count)
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(truncatingIfNeeded: try readBigEndian(2))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readBigEndian(4))
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBigEndian(8)
    }

    mutating func readUInt32LittleEndian() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readLittleEndian(4))
    }

    mutating func readUInt64LittleEndian() throws -> UInt64 {
        try readLittleEndian(8)
    }

    // A tenth byte may carry only bit 63.
    mutating func readVarint() throws -> UInt64 {
        let start = offset
        var result: UInt64 = 0
        for index in 0..<10 {
            let byte = try readByte()
            if index == 9, byte > 1 {
                throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start)
            }
            result |= UInt64(byte & 0x7F) << (7 * UInt64(index))
            if byte & 0x80 == 0 { return result }
        }
        throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start)
    }

    private mutating func readBigEndian(_ count: Int) throws -> UInt64 {
        try require(count)
        var value: UInt64 = 0
        for index in offset..<(offset + count) {
            value = value << 8 | UInt64(bytes[index])
        }
        offset += count
        return value
    }

    private mutating func readLittleEndian(_ count: Int) throws -> UInt64 {
        try require(count)
        var value: UInt64 = 0
        for index in (offset..<(offset + count)).reversed() {
            value = value << 8 | UInt64(bytes[index])
        }
        offset += count
        return value
    }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw error(.unexpectedEnd) }
    }
}

internal extension Data {
    func uppercaseHex(maxBytes: Int = .max) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(Swift.min(count, maxBytes) * 2)
        for byte in prefix(maxBytes) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return String(bytes: hex, encoding: .ascii) ?? ""
    }
}

internal extension String {
    func scalarPrefix(_ count: Int) -> String {
        let scalars = unicodeScalars
        guard let end = scalars.index(scalars.startIndex, offsetBy: Swift.max(count, 0), limitedBy: scalars.endIndex),
              end < scalars.endIndex else { return self }
        return String(scalars[..<end])
    }
}
