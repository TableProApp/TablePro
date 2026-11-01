//
//  AvroDecoder.swift
//  TablePro
//

import Foundation

internal enum AvroFraming: Equatable, Sendable {
    // Confluent Schema Registry: magic byte 0, then the schema ID, big-endian.
    case confluent(schemaID: UInt32)
    // Avro single-object encoding: C3 01, then the CRC-64-AVRO fingerprint of the writer schema, little-endian.
    case singleObject(fingerprint: UInt64)
}

internal struct AvroMessage: Equatable, Sendable {
    let value: MessagePackValue
    let framing: AvroFraming?
}

// Values land in MessagePack's model, which already has the tree, the JSON writer and the timestamp badge.
// A union shows the branch it holds, as Avro's own readers return it.
internal enum AvroDecoder {
    static let maxDepth = 256
    // Items that take no bytes (null, an empty record) are bounded by this, not by the bytes left.
    static let maxZeroByteItems: Int64 = 1_000_000
    // Records of records that take no bytes describe exponentially many values in a short schema, so every value
    // read counts, built or not. A grid cell reads synchronously and stops far sooner, showing hex past that.
    static let maxValuesRead = 10_000_000
    static let maxValuesReadInCell = 1_000_000

    // A single-object header that names this schema's fingerprint is certain, so it goes first. A Confluent
    // prefix proves nothing (a plain datum can start with zero), so it is only tried once the plain read fails.
    static func decode(
        _ data: Data,
        schema: AvroSchema,
        maxValues: Int = .max,
        maxValuesRead: Int = AvroDecoder.maxValuesRead
    ) throws -> AvroMessage {
        let limits = (build: maxValues, read: maxValuesRead)
        let singleObject = singleObjectFingerprint(data)
        if let singleObject, singleObject == schema.fingerprint {
            let value = try datum(data.dropFirst(10), schema: schema, limits: limits)
            return AvroMessage(value: value, framing: .singleObject(fingerprint: singleObject))
        }
        do {
            return AvroMessage(value: try datum(data, schema: schema, limits: limits), framing: nil)
        } catch let plainError as BinaryValueDecodeError {
            // Avro's own reader refuses a value written with a schema it does not have.
            if let singleObject { throw BinaryValueDecodeError(kind: .otherSchema(fingerprint: singleObject), offset: 2) }
            guard data.count >= 5, data.first == 0x00 else { throw plainError }
            var header = BinaryValueReader(data)
            _ = try header.readByte()
            let framing = AvroFraming.confluent(schemaID: try header.readUInt32())
            let body = data.dropFirst(5)
            // Confluent's serializer writes a bytes value as it is, with no length in front, a decimal on bytes included.
            if let raw = rawBytes(Data(body), schema: schema) {
                return AvroMessage(value: raw, framing: framing)
            }
            guard let value = try? datum(body, schema: schema, limits: limits) else { throw plainError }
            return AvroMessage(value: value, framing: framing)
        }
    }

    // The payload behind a Schema Registry prefix the caller has read, so a datum that starts with zero stays a datum.
    static func decodeRegistryPayload(
        _ body: Data,
        schema: AvroSchema,
        maxValues: Int = .max,
        maxValuesRead: Int = AvroDecoder.maxValuesRead
    ) throws -> MessagePackValue {
        if let raw = rawBytes(Data(body), schema: schema) { return raw }
        return try datum(body, schema: schema, limits: (maxValues, maxValuesRead))
    }

    private static func rawBytes(_ body: Data, schema: AvroSchema) -> MessagePackValue? {
        switch schema.resolve(schema.root) {
        case .bytes:
            return .binary(body)
        case .logical(let logical, let base):
            guard case .bytes = schema.resolve(base) else { return nil }
            return AvroLogicalRendering.render(.binary(body), as: logical)
        default:
            return nil
        }
    }

    private static func singleObjectFingerprint(_ data: Data) -> UInt64? {
        guard data.count >= 10, data.starts(with: [0xC3, 0x01]) else { return nil }
        var header = BinaryValueReader(data)
        try? header.skip(2)
        return try? header.readUInt64LittleEndian()
    }

    private static func datum(_ data: Data, schema: AvroSchema, limits: (build: Int, read: Int)) throws -> MessagePackValue {
        var parser = Parser(reader: BinaryValueReader(Data(data)), schema: schema, budget: limits.build, readLimit: limits.read)
        let value = try parser.value(schema.root, depth: 0)
        if !parser.reader.isAtEnd {
            throw parser.reader.error(.trailingBytes(parser.reader.remaining))
        }
        return value
    }

    // Past the budget the parser keeps reading and stops building, so the cell judges the frame and the
    // trailing bytes on the whole value, the same as the viewer does.
    private struct Parser {
        var reader: BinaryValueReader
        let schema: AvroSchema
        private var budget: Int
        private var isTruncated = false
        private var zeroByteItems: Int64 = 0
        private var valuesRead = 0
        private let readLimit: Int

        init(reader: BinaryValueReader, schema: AvroSchema, budget: Int, readLimit: Int) {
            self.reader = reader
            self.schema = schema
            self.budget = budget
            self.readLimit = readLimit
        }

        // Only a dispatch: every kind of type is its own function, so the frames a deep value stacks up stay small.
        mutating func value(_ type: AvroType, depth: Int) throws -> MessagePackValue {
            guard depth <= AvroDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            valuesRead += 1
            guard valuesRead <= readLimit else { throw reader.error(.tooLarge) }
            if !isTruncated {
                budget -= 1
                isTruncated = budget < 0
            }
            let builds = !isTruncated
            let resolved = schema.resolve(type)
            switch resolved {
            case .record(_, let fields):
                return try record(fields, depth: depth, builds: builds)
            case .array(let items):
                return try array(items, depth: depth, builds: builds)
            case .map(let valueType):
                return try map(valueType, depth: depth, builds: builds)
            case .union(let branches):
                // The branch is the value itself, so it takes no share of the budget of its own.
                budget += builds ? 1 : 0
                return try value(branches[try index(below: branches.count)], depth: depth)
            case .logical(let logical, let base):
                budget += builds ? 1 : 0
                return try annotated(logical, base, depth: depth, builds: builds)
            case .named:
                throw reader.error(.invalidField)
            default:
                return try primitive(resolved, builds: builds)
            }
        }

        private mutating func primitive(_ type: AvroType, builds: Bool) throws -> MessagePackValue {
            switch type {
            case .boolean:
                let start = reader.offset
                let byte = try reader.readByte()
                guard byte <= 1 else { throw BinaryValueDecodeError(kind: .invalidByte(byte), offset: start) }
                return builds ? .bool(byte == 1) : .truncated
            case .int:
                let number = try int()
                return builds ? .int(number) : .truncated
            case .long:
                let number = try long()
                return builds ? .int(number) : .truncated
            case .float:
                let bits = try reader.readUInt32LittleEndian()
                return builds ? .float(Float(bitPattern: bits)) : .truncated
            case .double:
                let bits = try reader.readUInt64LittleEndian()
                return builds ? .double(Double(bitPattern: bits)) : .truncated
            case .bytes, .string, .fixed:
                let count: Int
                if case .fixed(_, let size) = type { count = size } else { count = try byteCount() }
                guard builds else {
                    try reader.skip(count)
                    return .truncated
                }
                let data = try reader.readBytes(count)
                guard case .string = type else { return .binary(data) }
                // Writers that ignore the encoding put any bytes in a string, so those show as bytes.
                return String(data: data, encoding: .utf8).map(MessagePackValue.string) ?? .binary(data)
            case .enumeration(_, let symbols):
                let symbol = symbols[try index(below: symbols.count)]
                return builds ? .string(symbol) : .truncated
            default:
                return builds ? .null : .truncated
            }
        }

        private mutating func record(_ fields: [AvroField], depth: Int, builds: Bool) throws -> MessagePackValue {
            var pairs: [MessagePackPair] = []
            pairs.reserveCapacity(builds ? fields.count : 0)
            for field in fields {
                let wasTruncated = isTruncated
                let item = try value(field.type, depth: depth + 1)
                if !wasTruncated { pairs.append(MessagePackPair(key: .string(field.name), value: item)) }
            }
            return builds ? .map(pairs) : .truncated
        }

        private mutating func array(_ items: AvroType, depth: Int, builds: Bool) throws -> MessagePackValue {
            var values: [MessagePackValue] = []
            try blocks(takesNoBytes: schema.takesNoBytes(items)) { parser in
                let wasTruncated = parser.isTruncated
                let item = try parser.value(items, depth: depth + 1)
                if !wasTruncated { values.append(item) }
            }
            return builds ? .array(values) : .truncated
        }

        private mutating func map(_ valueType: AvroType, depth: Int, builds: Bool) throws -> MessagePackValue {
            var pairs: [MessagePackPair] = []
            try blocks(takesNoBytes: false) { parser in
                let wasTruncated = parser.isTruncated
                let key = try parser.value(.string, depth: depth + 1)
                let item = try parser.value(valueType, depth: depth + 1)
                if !wasTruncated { pairs.append(MessagePackPair(key: key, value: item)) }
            }
            return builds ? .map(pairs) : .truncated
        }

        private mutating func annotated(_ logical: AvroLogicalType, _ base: AvroType, depth: Int, builds: Bool) throws -> MessagePackValue {
            let raw = try value(base, depth: depth)
            guard builds, raw != .truncated else { return raw }
            if case .decimal = logical, case .binary(let bytes) = raw {
                // Long division costs the square of the width, so a wide decimal draws on the budget by its width.
                budget -= AvroDecimal.significantBytes([UInt8](bytes)).count
            }
            return AvroLogicalRendering.render(raw, as: logical)
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
                // Every item takes a byte at least, unless its type takes none; then only the cap bounds the loop.
                if takesNoBytes {
                    guard count <= AvroDecoder.maxZeroByteItems - zeroByteItems else {
                        throw BinaryValueDecodeError(kind: .tooLarge, offset: start)
                    }
                    zeroByteItems += count
                } else if count > Int64(reader.remaining) {
                    throw BinaryValueDecodeError(kind: .unexpectedEnd, offset: reader.end)
                }
                for _ in 0..<count {
                    try item(&self)
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

        private mutating func byteCount() throws -> Int {
            let start = reader.offset
            let count = try long()
            guard count >= 0 else { throw BinaryValueDecodeError(kind: .invalidLength, offset: start) }
            guard count <= Int64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
            return Int(count)
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
        case (.decimal(let precision, let scale), .binary(let data)):
            let unscaled = AvroDecimal.significantBytes([UInt8](data))
            guard unscaled.count <= AvroDecimal.maxBytes(precision: precision) else { return value }
            return .string(AvroDecimal.text(unscaled: unscaled, scale: scale))
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
        case (.timestampNanos, .int(let nanos)):
            return timestamp(units: nanos, perSecond: 1_000_000_000)
        case (.localTimestampMillis, .int(let millis)):
            return localText(timestamp(units: millis, perSecond: 1_000)).map(MessagePackValue.string) ?? value
        case (.localTimestampMicros, .int(let micros)):
            return localText(timestamp(units: micros, perSecond: 1_000_000)).map(MessagePackValue.string) ?? value
        case (.localTimestampNanos, .int(let nanos)):
            return localText(timestamp(units: nanos, perSecond: 1_000_000_000)).map(MessagePackValue.string) ?? value
        case (.duration, .binary(let data)) where data.count == 12:
            return .string(durationText([UInt8](data)))
        default:
            return value
        }
    }

    private static func timestamp(units: Int64, perSecond: Int64) -> MessagePackValue {
        let (seconds, remainder) = floorDivide(units, perSecond)
        return .timestamp(seconds: seconds, nanoseconds: UInt32(remainder * (1_000_000_000 / perSecond)))
    }

    // A local timestamp names no zone, so it reads as the wall-clock text without the trailing Z.
    private static func localText(_ timestamp: MessagePackValue) -> String? {
        guard case .timestamp(let seconds, let nanoseconds) = timestamp else { return nil }
        let text = RFC3339Timestamp.format(seconds: seconds, nanoseconds: nanoseconds)
        return text.hasSuffix("Z") ? String(text.dropLast()) : nil
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

    // Three little-endian unsigned ints: months, days, milliseconds, written as an ISO 8601 duration.
    private static func durationText(_ bytes: [UInt8]) -> String {
        func part(_ offset: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
        }
        let months = part(0), days = part(4), millis = part(8)
        var text = "P"
        if months > 0 { text += "\(months)M" }
        if days > 0 { text += "\(days)D" }
        if millis > 0 {
            text += "T\(millis / 1_000)"
            if millis % 1_000 > 0 { text += String(format: ".%03llu", millis % 1_000) }
            text += "S"
        }
        return text == "P" ? "PT0S" : text
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
    }

    private static func uuidTuple(_ bytes: [UInt8]) -> uuid_t {
        (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }
}

// Big-endian two's complement of any width, as Avro's decimal stores the unscaled value.
internal enum AvroDecimal {
    // The most digits a two's complement of this many bytes holds: floor(log10(2^(8n-1) - 1)).
    static func maxPrecision(bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        return Int((Double(8 * min(bytes, 100_000) - 1) * log10(2.0)).rounded(.down))
    }

    // The fewest bytes that hold any value of this many digits, sign bit included.
    static func maxBytes(precision: Int) -> Int {
        Int(((Double(precision) * log2(10.0) + 1) / 8).rounded(.up))
    }

    // Leading bytes that only repeat the sign; a fixed pads with them.
    static func significantBytes(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        var start = bytes.startIndex
        while bytes.endIndex - start > 1 {
            let lead = bytes[start], next = bytes[start + 1]
            guard (lead == 0x00 && next < 0x80) || (lead == 0xFF && next >= 0x80) else { break }
            start += 1
        }
        return bytes[start...]
    }

    static func text(unscaled bytes: ArraySlice<UInt8>, scale: Int) -> String {
        guard let first = bytes.first else { return "0" }
        let isNegative = first & 0x80 != 0
        var magnitude = Array(bytes)
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
        var words = Self.words(magnitude)
        // Base 10^9 groups, least significant first: one pass of division yields nine digits.
        var groups: [UInt32] = []
        while let lead = words.firstIndex(where: { $0 != 0 }) {
            words.removeFirst(lead)
            var remainder: UInt64 = 0
            for index in words.indices {
                let current = remainder << 32 | UInt64(words[index])
                words[index] = UInt32(current / 1_000_000_000)
                remainder = current % 1_000_000_000
            }
            groups.append(UInt32(remainder))
        }
        var text = groups.last.map { String($0) } ?? "0"
        for group in groups.dropLast().reversed() {
            let digits = String(group)
            text += String(repeating: "0", count: 9 - digits.count) + digits
        }
        if scale > 0 {
            if text.count <= scale {
                text = String(repeating: "0", count: scale - text.count + 1) + text
            }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -scale))
        }
        return isNegative ? "-" + text : text
    }

    private static func words(_ bytes: [UInt8]) -> [UInt32] {
        let padded = [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4) + bytes
        return stride(from: 0, to: padded.count, by: 4).map { start in
            padded[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
    }
}
