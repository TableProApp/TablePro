//
//  MessagePackDecoder.swift
//  TablePro
//

import Foundation

internal struct MessagePackPair: Equatable, Sendable {
    let key: MessagePackValue
    let value: MessagePackValue
}

internal indirect enum MessagePackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([MessagePackPair])
    case ext(type: Int8, data: Data)
    case timestamp(seconds: Int64, nanoseconds: UInt32)
    case truncated
}

// https://github.com/msgpack/msgpack/blob/master/spec.md
internal enum MessagePackDecoder {
    static let maxDepth = 256
    static let timestampType: Int8 = -1

    static func decode(_ data: Data, maxValues: Int = .max) throws -> MessagePackValue {
        var parser = Parser(reader: BinaryValueReader(data), budget: maxValues)
        let value = try parser.value(depth: 0)
        if !parser.isTruncated, !parser.reader.isAtEnd {
            throw parser.reader.error(.trailingBytes(parser.reader.remaining))
        }
        return value
    }

    private struct Parser {
        var reader: BinaryValueReader
        var budget: Int
        var isTruncated = false

        mutating func value(depth: Int) throws -> MessagePackValue {
            guard depth <= MessagePackDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            guard budget > 0 else {
                isTruncated = true
                return .truncated
            }
            budget -= 1
            let start = reader.offset
            let byte = try reader.readByte()
            switch byte {
            case 0x00...0x7F:
                return .uint(UInt64(byte))
            case 0x80...0x8F:
                return try map(count: Int(byte & 0x0F), depth: depth)
            case 0x90...0x9F:
                return try array(count: Int(byte & 0x0F), depth: depth)
            case 0xA0...0xBF:
                return try string(count: Int(byte & 0x1F))
            case 0xC0:
                return .null
            case 0xC2:
                return .bool(false)
            case 0xC3:
                return .bool(true)
            case 0xC4:
                return .binary(try reader.readBytes(Int(try reader.readByte())))
            case 0xC5:
                return .binary(try reader.readBytes(Int(try reader.readUInt16())))
            case 0xC6:
                return .binary(try reader.readBytes(Int(try reader.readUInt32())))
            case 0xC7:
                return try ext(count: Int(try reader.readByte()))
            case 0xC8:
                return try ext(count: Int(try reader.readUInt16()))
            case 0xC9:
                return try ext(count: Int(try reader.readUInt32()))
            case 0xCA:
                return .float(Float(bitPattern: try reader.readUInt32()))
            case 0xCB:
                return .double(Double(bitPattern: try reader.readUInt64()))
            case 0xCC:
                return .uint(UInt64(try reader.readByte()))
            case 0xCD:
                return .uint(UInt64(try reader.readUInt16()))
            case 0xCE:
                return .uint(UInt64(try reader.readUInt32()))
            case 0xCF:
                return .uint(try reader.readUInt64())
            case 0xD0:
                return .int(Int64(Int8(bitPattern: try reader.readByte())))
            case 0xD1:
                return .int(Int64(Int16(bitPattern: try reader.readUInt16())))
            case 0xD2:
                return .int(Int64(Int32(bitPattern: try reader.readUInt32())))
            case 0xD3:
                return .int(Int64(bitPattern: try reader.readUInt64()))
            case 0xD4:
                return try ext(count: 1)
            case 0xD5:
                return try ext(count: 2)
            case 0xD6:
                return try ext(count: 4)
            case 0xD7:
                return try ext(count: 8)
            case 0xD8:
                return try ext(count: 16)
            case 0xD9:
                return try string(count: Int(try reader.readByte()))
            case 0xDA:
                return try string(count: Int(try reader.readUInt16()))
            case 0xDB:
                return try string(count: Int(try reader.readUInt32()))
            case 0xDC:
                return try array(count: Int(try reader.readUInt16()), depth: depth)
            case 0xDD:
                return try array(count: Int(try reader.readUInt32()), depth: depth)
            case 0xDE:
                return try map(count: Int(try reader.readUInt16()), depth: depth)
            case 0xDF:
                return try map(count: Int(try reader.readUInt32()), depth: depth)
            case 0xE0...0xFF:
                return .int(Int64(Int8(bitPattern: byte)))
            default:
                throw BinaryValueDecodeError(kind: .invalidByte(byte), offset: start)
            }
        }

        // Older writers put any bytes in `str`.
        private mutating func string(count: Int) throws -> MessagePackValue {
            let bytes = try reader.readBytes(count)
            guard let text = String(data: bytes, encoding: .utf8) else { return .binary(bytes) }
            return .string(text)
        }

        // A count past the bytes left is forged; checking first keeps it from reserving gigabytes.
        private mutating func array(count: Int, depth: Int) throws -> MessagePackValue {
            guard count <= reader.remaining else { throw reader.error(.unexpectedEnd) }
            var items: [MessagePackValue] = []
            items.reserveCapacity(min(count, 1_024))
            for _ in 0..<count {
                items.append(try value(depth: depth + 1))
                if isTruncated { break }
            }
            return .array(items)
        }

        private mutating func map(count: Int, depth: Int) throws -> MessagePackValue {
            guard count <= reader.remaining / 2 else { throw reader.error(.unexpectedEnd) }
            var pairs: [MessagePackPair] = []
            pairs.reserveCapacity(min(count, 1_024))
            for _ in 0..<count {
                let key = try value(depth: depth + 1)
                let item: MessagePackValue = isTruncated ? .truncated : try value(depth: depth + 1)
                pairs.append(MessagePackPair(key: key, value: item))
                if isTruncated { break }
            }
            return .map(pairs)
        }

        private mutating func ext(count: Int) throws -> MessagePackValue {
            let type = Int8(bitPattern: try reader.readByte())
            let data = try reader.readBytes(count)
            if type == MessagePackDecoder.timestampType, let timestamp = Self.timestamp(data) {
                return timestamp
            }
            return .ext(type: type, data: data)
        }

        // Nanoseconds past a second make it no timestamp, so it stays a plain extension.
        private static func timestamp(_ data: Data) -> MessagePackValue? {
            var reader = BinaryValueReader(data)
            let seconds: Int64
            let nanoseconds: UInt32
            switch data.count {
            case 4:
                guard let value = try? reader.readUInt32() else { return nil }
                seconds = Int64(value)
                nanoseconds = 0
            case 8:
                guard let value = try? reader.readUInt64() else { return nil }
                nanoseconds = UInt32(value >> 34)
                seconds = Int64(value & 0x3_FFFF_FFFF)
            case 12:
                guard let nanos = try? reader.readUInt32(), let value = try? reader.readUInt64() else { return nil }
                nanoseconds = nanos
                seconds = Int64(bitPattern: value)
            default:
                return nil
            }
            guard nanoseconds < 1_000_000_000 else { return nil }
            return .timestamp(seconds: seconds, nanoseconds: nanoseconds)
        }
    }
}
