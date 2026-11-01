//
//  ProtobufWireDecoder.swift
//  TablePro
//

import Foundation

internal struct ProtobufField: Equatable, Sendable {
    let number: Int
    let value: ProtobufFieldValue
}

internal indirect enum ProtobufFieldValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case message([ProtobufField])
    case string(String)
    case bytes(Data)
    case group([ProtobufField])
    case truncated
}

// Confluent Schema Registry framing: magic byte 0, schema ID, message indexes, then the payload.
internal struct ProtobufFraming: Equatable, Sendable {
    let schemaID: UInt32
    let messageIndexes: [Int]
}

internal struct ProtobufMessage: Equatable, Sendable {
    let fields: [ProtobufField]
    let framing: ProtobufFraming?
}

// A length-delimited field is a message if it parses as one, else UTF-8 text, else bytes, as protoc --decode_raw reads it.
internal enum ProtobufWireDecoder {
    static let maxDepth = 100
    static let maxFieldNumber = (1 << 29) - 1

    static func decode(_ data: Data, maxValues: Int = .max) throws -> ProtobufMessage {
        var reader = BinaryValueReader(data)
        var framing: ProtobufFraming?
        // Field number 0 is invalid, so a leading zero byte can only be the frame's magic byte.
        if reader.peekByte() == 0 {
            framing = try readFraming(&reader)
        }
        var parser = Parser(budget: maxValues)
        let fields = try parser.fields(&reader, depth: 0, group: nil)
        return ProtobufMessage(fields: fields, framing: framing)
    }

    static func readFraming(_ reader: inout BinaryValueReader) throws -> ProtobufFraming {
        _ = try reader.readByte()
        let schemaID = try reader.readUInt32()
        let start = reader.offset
        let count = zigzag(try reader.readVarint())
        guard count >= 0, count <= reader.remaining else {
            throw BinaryValueDecodeError(kind: .invalidField, offset: start)
        }
        guard count > 0 else { return ProtobufFraming(schemaID: schemaID, messageIndexes: [0]) }
        var indexes: [Int] = []
        for _ in 0..<count {
            indexes.append(Int(zigzag(try reader.readVarint())))
        }
        return ProtobufFraming(schemaID: schemaID, messageIndexes: indexes)
    }

    // Spends the caller's budget, so a cell stops inside a large field the schema does not name.
    static func lengthDelimited(_ window: BinaryValueReader, depth: Int, budget: inout Int) -> ProtobufFieldValue {
        var parser = Parser(budget: budget)
        var window = window
        let value = parser.lengthDelimited(&window, depth: depth)
        budget = parser.budget
        return value
    }

    static func fields(in window: BinaryValueReader, depth: Int, budget: inout Int) throws -> [ProtobufField] {
        var parser = Parser(budget: budget)
        var window = window
        let fields = try parser.fields(&window, depth: depth, group: nil)
        budget = parser.budget
        return fields
    }

    // The bytes between a group's start tag, already read, and its end tag. Past `limit` tags it stops at the last whole
    // field and reports the cut, so a cell never reads more of a group than its budget.
    static func groupContents(
        _ reader: inout BinaryValueReader,
        number: Int,
        depth: Int,
        limit: Int
    ) throws -> (contents: BinaryValueReader, isCut: Bool) {
        let contents = reader
        var openGroups = [number]
        var boundary = reader.offset
        var scanned = 0
        while true {
            let start = reader.offset
            if openGroups.count == 1 { boundary = start }
            guard scanned < limit else { return (try contents.window(boundary - contents.offset), true) }
            guard !reader.isAtEnd else { throw reader.error(.unexpectedEnd) }
            let tag = try reader.readVarint()
            scanned += 1
            let fieldNumber = tag >> 3
            guard tag <= UInt64(UInt32.max), fieldNumber > 0, fieldNumber <= UInt64(maxFieldNumber) else {
                throw BinaryValueDecodeError(kind: .invalidField, offset: start)
            }
            switch tag & 7 {
            case 0:
                _ = try reader.readVarint()
            case 1:
                try reader.skip(8)
            case 2:
                let length = try reader.readVarint()
                guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
                try reader.skip(Int(length))
            case 3:
                guard depth + openGroups.count < maxDepth else { throw BinaryValueDecodeError(kind: .nestingTooDeep, offset: start) }
                openGroups.append(Int(fieldNumber))
            case 4:
                guard openGroups.last == Int(fieldNumber) else { throw BinaryValueDecodeError(kind: .unmatchedGroupEnd, offset: start) }
                openGroups.removeLast()
                if openGroups.isEmpty { return (try contents.window(start - contents.offset), false) }
            case 5:
                try reader.skip(4)
            default:
                throw BinaryValueDecodeError(kind: .invalidField, offset: start)
            }
        }
    }

    static func zigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    private struct Parser {
        var budget: Int
        var isTruncated = false

        mutating func fields(_ reader: inout BinaryValueReader, depth: Int, group: Int?) throws -> [ProtobufField] {
            var result: [ProtobufField] = []
            while !reader.isAtEnd {
                guard budget > 0 else {
                    isTruncated = true
                    result.append(ProtobufField(number: 0, value: .truncated))
                    return result
                }
                let start = reader.offset
                let tag = try reader.readVarint()
                let number = tag >> 3
                guard tag <= UInt64(UInt32.max), number > 0, number <= UInt64(ProtobufWireDecoder.maxFieldNumber) else {
                    throw BinaryValueDecodeError(kind: .invalidField, offset: start)
                }
                let fieldNumber = Int(number)
                switch tag & 7 {
                case 0:
                    budget -= 1
                    result.append(ProtobufField(number: fieldNumber, value: .varint(try reader.readVarint())))
                case 1:
                    budget -= 1
                    result.append(ProtobufField(number: fieldNumber, value: .fixed64(try reader.readUInt64LittleEndian())))
                case 2:
                    budget -= 1
                    let length = try reader.readVarint()
                    guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
                    var window = try reader.window(Int(length))
                    try reader.skip(Int(length))
                    result.append(ProtobufField(number: fieldNumber, value: lengthDelimited(&window, depth: depth)))
                case 3:
                    budget -= 1
                    guard depth < ProtobufWireDecoder.maxDepth else {
                        throw BinaryValueDecodeError(kind: .nestingTooDeep, offset: start)
                    }
                    let members = try fields(&reader, depth: depth + 1, group: fieldNumber)
                    result.append(ProtobufField(number: fieldNumber, value: .group(members)))
                case 4:
                    guard group == fieldNumber else {
                        throw BinaryValueDecodeError(kind: .unmatchedGroupEnd, offset: start)
                    }
                    return result
                case 5:
                    budget -= 1
                    result.append(ProtobufField(number: fieldNumber, value: .fixed32(try reader.readUInt32LittleEndian())))
                default:
                    throw BinaryValueDecodeError(kind: .invalidField, offset: start)
                }
                if isTruncated { return result }
            }
            if group != nil, !isTruncated {
                throw reader.error(.unexpectedEnd)
            }
            return result
        }

        mutating func lengthDelimited(_ window: inout BinaryValueReader, depth: Int) -> ProtobufFieldValue {
            if window.remaining > 0, depth < ProtobufWireDecoder.maxDepth, budget > 0 {
                var attempt = self
                var nested = window
                if let members = try? attempt.fields(&nested, depth: depth + 1, group: nil) {
                    self = attempt
                    return .message(members)
                }
            }
            guard let bytes = try? window.readBytes(window.remaining) else { return .bytes(Data()) }
            if let text = String(data: bytes, encoding: .utf8) { return .string(text) }
            return .bytes(bytes)
        }
    }
}
