//
//  AvroDecoder.swift
//  TablePro
//

import Foundation

internal struct AvroMessage: Equatable, Sendable {
    let value: MessagePackValue
    let schemaID: UInt32?
}

// Values land in MessagePack's model, which already has the tree, the JSON writer and the timestamp badge.
// A union shows the branch it holds, as Avro's own readers return it.
internal enum AvroDecoder {
    static let maxDepth = 256
    static let maxZeroByteItems: Int64 = 1_000_000
    // Long division is quadratic in the width; past this a decimal shows as its bytes.
    static let maxDecimalBytes = 512

    // A Kafka value carries the Confluent prefix: magic byte 0 and a four-byte schema ID. Zero also starts
    // plenty of plain datums, so the prefix is only tried once the value fails to read without it.
    static func decode(_ data: Data, schema: AvroSchema, maxValues: Int = .max) throws -> AvroMessage {
        do {
            return AvroMessage(value: try datum(data, schema: schema, maxValues: maxValues), schemaID: nil)
        } catch let plainError as BinaryValueDecodeError {
            guard data.count >= 5, data.first == 0 else { throw plainError }
            var header = BinaryValueReader(data)
            _ = try header.readByte()
            let schemaID = try header.readUInt32()
            guard let value = try? datum(data.dropFirst(5), schema: schema, maxValues: maxValues) else { throw plainError }
            return AvroMessage(value: value, schemaID: schemaID)
        }
    }

    private static func datum(_ data: Data, schema: AvroSchema, maxValues: Int) throws -> MessagePackValue {
        var parser = Parser(reader: BinaryValueReader(Data(data)), schema: schema, budget: maxValues)
        let value = try parser.value(schema.root, depth: 0)
        if !parser.isTruncated, !parser.reader.isAtEnd {
            throw parser.reader.error(.trailingBytes(parser.reader.remaining))
        }
        return value
    }

    private struct Parser {
        var reader: BinaryValueReader
        let schema: AvroSchema
        var budget: Int
        var isTruncated = false
        private var zeroByteItems: Int64 = 0

        init(reader: BinaryValueReader, schema: AvroSchema, budget: Int) {
            self.reader = reader
            self.schema = schema
            self.budget = budget
        }

        mutating func value(_ type: AvroType, depth: Int) throws -> MessagePackValue {
            guard depth <= AvroDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            guard budget > 0 else {
                isTruncated = true
                return .truncated
            }
            budget -= 1
            switch schema.resolve(type) {
            case .null:
                return .null
            case .boolean:
                let start = reader.offset
                let byte = try reader.readByte()
                guard byte <= 1 else { throw BinaryValueDecodeError(kind: .invalidByte(byte), offset: start) }
                return .bool(byte == 1)
            case .int:
                return .int(try int())
            case .long:
                return .int(try long())
            case .float:
                return .float(Float(bitPattern: try reader.readUInt32LittleEndian()))
            case .double:
                return .double(Double(bitPattern: try reader.readUInt64LittleEndian()))
            case .bytes:
                return .binary(try bytes())
            case .string:
                return try string()
            case .record(_, let fields):
                var pairs: [MessagePackPair] = []
                pairs.reserveCapacity(fields.count)
                for field in fields {
                    let item = try value(field.type, depth: depth + 1)
                    pairs.append(MessagePackPair(key: .string(field.name), value: item))
                    if isTruncated { break }
                }
                return .map(pairs)
            case .enumeration(_, let symbols):
                return .string(symbols[try index(below: symbols.count)])
            case .array(let items):
                var values: [MessagePackValue] = []
                try blocks(takesNoBytes: schema.takesNoBytes(items)) { parser in
                    values.append(try parser.value(items, depth: depth + 1))
                }
                return .array(values)
            case .map(let valueType):
                var pairs: [MessagePackPair] = []
                try blocks(takesNoBytes: false) { parser in
                    let key = try parser.string()
                    pairs.append(MessagePackPair(key: key, value: try parser.value(valueType, depth: depth + 1)))
                }
                return .map(pairs)
            case .union(let branches):
                return try value(branches[try index(below: branches.count)], depth: depth)
            case .fixed(_, let size):
                return .binary(try reader.readBytes(size))
            case .named:
                throw reader.error(.invalidField)
            case .logical(let logical, let base):
                return AvroLogicalRendering.render(try value(base, depth: depth), as: logical)
            }
        }

        // Each block is a count, then that many items; a negative count is followed by the block's byte size.
        private mutating func blocks(takesNoBytes: Bool, _ item: (inout Parser) throws -> Void) throws {
            while true {
                let start = reader.offset
                var count = try long()
                if count == 0 { return }
                if count < 0 {
                    guard count != .min else { throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start) }
                    count = -count
                    _ = try long()
                }
                // A count past the bytes left is forged, unless the items take no bytes; then the count alone bounds the loop.
                if count > Int64(reader.remaining) {
                    guard takesNoBytes else { throw BinaryValueDecodeError(kind: .unexpectedEnd, offset: reader.end) }
                    zeroByteItems += count
                    guard zeroByteItems <= AvroDecoder.maxZeroByteItems else {
                        throw BinaryValueDecodeError(kind: .tooLarge, offset: start)
                    }
                }
                for _ in 0..<count {
                    try item(&self)
                    if isTruncated { return }
                }
            }
        }

        private mutating func index(below count: Int) throws -> Int {
            let start = reader.offset
            let index = try long()
            guard index >= 0, index < count else {
                throw BinaryValueDecodeError(kind: .indexOutOfRange(Int(clamping: index)), offset: start)
            }
            return Int(index)
        }

        private mutating func bytes() throws -> Data {
            let start = reader.offset
            let count = try long()
            guard count >= 0, count <= Int64(reader.remaining) else {
                throw BinaryValueDecodeError(kind: count < 0 ? .invalidLength : .unexpectedEnd, offset: start)
            }
            return try reader.readBytes(Int(count))
        }

        // Writers that ignore the encoding put any bytes in a string, so those show as bytes.
        mutating func string() throws -> MessagePackValue {
            let data = try bytes()
            guard let text = String(data: data, encoding: .utf8) else { return .binary(data) }
            return .string(text)
        }

        private mutating func int() throws -> Int64 {
            let start = reader.offset
            let value = try long()
            guard let narrowed = Int32(exactly: value) else {
                throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start)
            }
            return Int64(narrowed)
        }

        private mutating func long() throws -> Int64 {
            let raw = try reader.readVarint()
            return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
        }
    }
}

internal enum AvroLogicalRendering {
    static func render(_ value: MessagePackValue, as logical: AvroLogicalType) -> MessagePackValue {
        switch (logical, value) {
        case (.decimal(let scale), .binary(let data)) where data.count <= AvroDecoder.maxDecimalBytes:
            return .string(decimalText(unscaled: [UInt8](data), scale: scale))
        case (.uuid, .string):
            return value
        case (.uuid, .binary(let data)) where data.count == 16:
            return .string(UUID(uuid: uuidTuple([UInt8](data))).uuidString.lowercased())
        case (.date, .int(let days)):
            return .string(dateText(days: days))
        case (.timeMillis, .int(let millis)):
            return timeText(units: millis, perSecond: 1_000).map(MessagePackValue.string) ?? value
        case (.timeMicros, .int(let micros)):
            return timeText(units: micros, perSecond: 1_000_000).map(MessagePackValue.string) ?? value
        case (.timestampMillis, .int(let millis)):
            return timestamp(units: millis, perSecond: 1_000)
        case (.timestampMicros, .int(let micros)):
            return timestamp(units: micros, perSecond: 1_000_000)
        case (.localTimestampMillis, .int(let millis)):
            return .string(localText(timestamp(units: millis, perSecond: 1_000)))
        case (.localTimestampMicros, .int(let micros)):
            return .string(localText(timestamp(units: micros, perSecond: 1_000_000)))
        default:
            return value
        }
    }

    private static func timestamp(units: Int64, perSecond: Int64) -> MessagePackValue {
        let (seconds, remainder) = floorDivide(units, perSecond)
        return .timestamp(seconds: seconds, nanoseconds: UInt32(remainder * (1_000_000_000 / perSecond)))
    }

    private static func localText(_ timestamp: MessagePackValue) -> String {
        guard case .timestamp(let seconds, let nanoseconds) = timestamp else { return "" }
        return String(RFC3339Timestamp.format(seconds: seconds, nanoseconds: nanoseconds).dropLast())
    }

    private static func dateText(days: Int64) -> String {
        let (seconds, overflow) = days.multipliedReportingOverflow(by: 86_400)
        guard !overflow else { return String(days) }
        let text = RFC3339Timestamp.format(seconds: seconds, nanoseconds: 0)
        return text.firstIndex(of: "T").map { String(text[..<$0]) } ?? text
    }

    private static func timeText(units: Int64, perSecond: Int64) -> String? {
        guard units >= 0, units < 86_400 * perSecond else { return nil }
        let seconds = units / perSecond
        var text = String(format: "%02lld:%02lld:%02lld", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
        let fraction = units % perSecond
        let digits = perSecond == 1_000 ? 3 : 6
        if fraction > 0 {
            text += "." + String(format: "%0\(digits)lld", fraction)
        }
        return text
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
    }

    // Big-endian two's complement of any width, converted to base 10 by long division.
    static func decimalText(unscaled bytes: [UInt8], scale: Int) -> String {
        guard !bytes.isEmpty else { return "0" }
        let isNegative = bytes[0] & 0x80 != 0
        var magnitude = bytes
        if isNegative {
            var carry = true
            for index in magnitude.indices.reversed() {
                magnitude[index] = ~magnitude[index]
                if carry {
                    let (sum, overflow) = magnitude[index].addingReportingOverflow(1)
                    magnitude[index] = sum
                    carry = overflow
                }
            }
        }
        var digits: [UInt8] = []
        while magnitude.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in magnitude.indices {
                let current = remainder << 8 | Int(magnitude[index])
                magnitude[index] = UInt8(current / 10)
                remainder = current % 10
            }
            digits.append(UInt8(remainder))
        }
        var text = String(digits.reversed().map { Character(String($0)) })
        if text.isEmpty { text = "0" }
        if scale > 0 {
            if text.count <= scale {
                text = String(repeating: "0", count: scale - text.count + 1) + text
            }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -scale))
        }
        return isNegative ? "-" + text : text
    }

    private static func uuidTuple(_ bytes: [UInt8]) -> uuid_t {
        (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }
}
