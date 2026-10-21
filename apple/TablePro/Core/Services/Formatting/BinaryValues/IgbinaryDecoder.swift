//
//  IgbinaryDecoder.swift
//  TablePro
//

import Foundation

// Formats 1 and 2, read as `igbinary_unserialize` in igbinary 3.2 reads them.
internal enum IgbinaryDecoder {
    static func decode(_ data: Data, maxValues: Int = .max) throws -> PhpValue {
        var reader = BinaryValueReader(data)
        guard reader.remaining >= 5 else { throw reader.error(.unexpectedEnd) }
        let version = try reader.readUInt32()
        guard version == 1 || version == 2 else {
            throw BinaryValueDecodeError(kind: .unsupportedVersion(version), offset: 0)
        }
        var parser = Parser(reader: reader, budget: maxValues)
        let value = try parser.value(depth: 0)
        if !parser.isTruncated, !parser.reader.isAtEnd {
            throw parser.reader.error(.trailingBytes(parser.reader.remaining))
        }
        return value
    }

    private enum Tag {
        static let null: UInt8 = 0x00
        static let ref8: UInt8 = 0x01, ref16: UInt8 = 0x02, ref32: UInt8 = 0x03
        static let boolFalse: UInt8 = 0x04, boolTrue: UInt8 = 0x05
        static let long8p: UInt8 = 0x06, long8n: UInt8 = 0x07
        static let long16p: UInt8 = 0x08, long16n: UInt8 = 0x09
        static let long32p: UInt8 = 0x0A, long32n: UInt8 = 0x0B
        static let double: UInt8 = 0x0C
        static let stringEmpty: UInt8 = 0x0D
        static let stringID8: UInt8 = 0x0E, stringID16: UInt8 = 0x0F, stringID32: UInt8 = 0x10
        static let string8: UInt8 = 0x11, string16: UInt8 = 0x12, string32: UInt8 = 0x13
        static let array8: UInt8 = 0x14, array16: UInt8 = 0x15, array32: UInt8 = 0x16
        static let object8: UInt8 = 0x17, object16: UInt8 = 0x18, object32: UInt8 = 0x19
        static let objectID8: UInt8 = 0x1A, objectID16: UInt8 = 0x1B, objectID32: UInt8 = 0x1C
        static let objectSer8: UInt8 = 0x1D, objectSer16: UInt8 = 0x1E, objectSer32: UInt8 = 0x1F
        static let long64p: UInt8 = 0x20, long64n: UInt8 = 0x21
        static let objref8: UInt8 = 0x22, objref16: UInt8 = 0x23, objref32: UInt8 = 0x24
        static let reference: UInt8 = 0x25
        static let string64: UInt8 = 0x26
        static let enumCase: UInt8 = 0x27
    }

    private struct Parser {
        var reader: BinaryValueReader
        var budget: Int
        var isTruncated = false
        private var strings: [String] = []
        // Indexed by igbinary's reference number, holding the number PHP's serialize() gives the same value.
        private var references: [Int] = []
        private var valueNumber = 0

        init(reader: BinaryValueReader, budget: Int) {
            self.reader = reader
            self.budget = budget
        }

        mutating func value(depth: Int) throws -> PhpValue {
            guard depth <= PhpSerializeParser.depthCap else { throw reader.error(.nestingTooDeep) }
            guard budget > 0 else {
                isTruncated = true
                return .tooLarge
            }
            budget -= 1
            let start = reader.offset
            let tag = try reader.readByte()
            if tag != Tag.reference, !Self.isPHPReference(tag) {
                valueNumber += 1
            }
            let number = valueNumber
            switch tag {
            case Tag.reference:
                let inner = try value(depth: depth + 1)
                switch inner {
                case .null, .bool, .int, .float, .string:
                    references.append(valueNumber)
                default:
                    break
                }
                return inner
            case Tag.ref8, Tag.ref16, Tag.ref32, Tag.objref8, Tag.objref16, Tag.objref32:
                let index = Int(try readSized(tag, small: [Tag.ref8, Tag.objref8], medium: [Tag.ref16, Tag.objref16]))
                guard index < references.count else {
                    throw BinaryValueDecodeError(kind: .unknownReference(index), offset: start)
                }
                return Self.isPHPReference(tag) ? .variableReference(id: references[index]) : .reference(id: references[index])
            case Tag.null:
                return .null
            case Tag.boolFalse:
                return .bool(false)
            case Tag.boolTrue:
                return .bool(true)
            case Tag.long8p, Tag.long8n, Tag.long16p, Tag.long16n, Tag.long32p, Tag.long32n, Tag.long64p, Tag.long64n:
                return .int(try long(tag))
            case Tag.double:
                return .float(Double(bitPattern: try reader.readUInt64()))
            case Tag.stringEmpty:
                return .string("")
            case Tag.stringID8, Tag.stringID16, Tag.stringID32:
                return .string(try storedString(tag))
            case Tag.string8, Tag.string16, Tag.string32, Tag.string64:
                return .string(try characters(tag))
            case Tag.array8, Tag.array16, Tag.array32:
                references.append(number)
                return .array(try entries(tag, depth: depth))
            case Tag.object8, Tag.object16, Tag.object32, Tag.objectID8, Tag.objectID16, Tag.objectID32:
                return try object(tag, number: number, depth: depth)
            default:
                throw BinaryValueDecodeError(kind: .invalidByte(tag), offset: start)
            }
        }

        // `R:` takes no number of its own in serialize().
        private static func isPHPReference(_ tag: UInt8) -> Bool {
            tag == Tag.ref8 || tag == Tag.ref16 || tag == Tag.ref32
        }

        private mutating func readSized(_ tag: UInt8, small: Set<UInt8>, medium: Set<UInt8>) throws -> UInt32 {
            if small.contains(tag) { return UInt32(try reader.readByte()) }
            if medium.contains(tag) { return UInt32(try reader.readUInt16()) }
            return try reader.readUInt32()
        }

        private mutating func long(_ tag: UInt8) throws -> Int {
            let start = reader.offset
            let magnitude: UInt64
            switch tag {
            case Tag.long8p, Tag.long8n: magnitude = UInt64(try reader.readByte())
            case Tag.long16p, Tag.long16n: magnitude = UInt64(try reader.readUInt16())
            case Tag.long32p, Tag.long32n: magnitude = UInt64(try reader.readUInt32())
            default: magnitude = try reader.readUInt64()
            }
            let isNegative = tag == Tag.long8n || tag == Tag.long16n || tag == Tag.long32n || tag == Tag.long64n
            if isNegative {
                guard magnitude <= UInt64(Int64.max) + 1 else {
                    throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start)
                }
                return Int(Int64(bitPattern: 0 &- magnitude))
            }
            guard magnitude <= UInt64(Int64.max) else {
                throw BinaryValueDecodeError(kind: .integerOutOfRange, offset: start)
            }
            return Int(magnitude)
        }

        private mutating func characters(_ tag: UInt8) throws -> String {
            let length: UInt64
            switch tag {
            case Tag.string8, Tag.object8: length = UInt64(try reader.readByte())
            case Tag.string16, Tag.object16: length = UInt64(try reader.readUInt16())
            case Tag.string32, Tag.object32: length = UInt64(try reader.readUInt32())
            default: length = try reader.readUInt64()
            }
            guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
            let text = Self.phpString(try reader.readBytes(Int(length)))
            strings.append(text)
            return text
        }

        // A PHP string is bytes: one that is not UTF-8 keeps a character per byte.
        private static func phpString(_ bytes: Data) -> String {
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }

        private mutating func storedString(_ tag: UInt8) throws -> String {
            let start = reader.offset
            let index = Int(try readSized(
                tag,
                small: [Tag.stringID8, Tag.objectID8],
                medium: [Tag.stringID16, Tag.objectID16]
            ))
            guard index < strings.count else {
                throw BinaryValueDecodeError(kind: .unknownReference(index), offset: start)
            }
            return strings[index]
        }

        private mutating func count(_ tag: UInt8) throws -> Int {
            let value = Int(try readSized(
                tag,
                small: [Tag.array8, Tag.objectSer8],
                medium: [Tag.array16, Tag.objectSer16]
            ))
            // A count past the bytes left is forged; checking first keeps it from reserving gigabytes.
            guard value <= reader.remaining else { throw reader.error(.unexpectedEnd) }
            return value
        }

        private mutating func entries(_ tag: UInt8, depth: Int) throws -> [PhpKeyValue] {
            let total = try count(tag)
            var result: [PhpKeyValue] = []
            result.reserveCapacity(min(total, 1_024))
            for _ in 0..<total {
                guard let key = try key() else { continue }
                result.append(PhpKeyValue(key: key, value: try value(depth: depth + 1)))
                if isTruncated { break }
            }
            return result
        }

        // igbinary's null key is an entry with no value, which igbinary_unserialize skips.
        private mutating func key() throws -> PhpValue? {
            let start = reader.offset
            let tag = try reader.readByte()
            switch tag {
            case Tag.null:
                return nil
            case Tag.long8p, Tag.long8n, Tag.long16p, Tag.long16n, Tag.long32p, Tag.long32n, Tag.long64p, Tag.long64n:
                return .int(try long(tag))
            case Tag.stringEmpty:
                return .string("")
            case Tag.stringID8, Tag.stringID16, Tag.stringID32:
                return .string(try storedString(tag))
            case Tag.string8, Tag.string16, Tag.string32, Tag.string64:
                return .string(try characters(tag))
            default:
                throw BinaryValueDecodeError(kind: .invalidByte(tag), offset: start)
            }
        }

        private mutating func object(_ tag: UInt8, number: Int, depth: Int) throws -> PhpValue {
            let className: String
            switch tag {
            case Tag.object8, Tag.object16, Tag.object32:
                className = try characters(tag)
            default:
                className = try storedString(tag)
            }
            references.append(number)
            let start = reader.offset
            let inner = try reader.readByte()
            switch inner {
            case Tag.array8, Tag.array16, Tag.array32:
                let properties = try entries(inner, depth: depth).map { entry -> PhpProperty in
                    let decoded = PhpSerializeParser.decodePropertyKey(Self.propertyName(entry.key))
                    return PhpProperty(name: decoded.name, visibility: decoded.visibility, value: entry.value)
                }
                return .object(className: className, properties: properties)
            case Tag.objectSer8, Tag.objectSer16, Tag.objectSer32:
                let payload = try reader.readBytes(try count(inner))
                return .serializable(className: className, rawPayload: Self.phpString(payload))
            case Tag.enumCase:
                let caseStart = reader.offset
                let caseTag = try reader.readByte()
                switch caseTag {
                case Tag.string8, Tag.string16, Tag.string32, Tag.string64:
                    return .enumCase(className: className, caseName: try characters(caseTag))
                case Tag.stringID8, Tag.stringID16, Tag.stringID32:
                    return .enumCase(className: className, caseName: try storedString(caseTag))
                default:
                    throw BinaryValueDecodeError(kind: .invalidByte(caseTag), offset: caseStart)
                }
            default:
                throw BinaryValueDecodeError(kind: .invalidByte(inner), offset: start)
            }
        }

        private static func propertyName(_ key: PhpValue) -> String {
            switch key {
            case .int(let number): return String(number)
            case .string(let text): return text
            default: return ""
            }
        }
    }
}
