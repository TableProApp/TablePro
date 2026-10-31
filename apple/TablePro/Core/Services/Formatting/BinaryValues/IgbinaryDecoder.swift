//
//  IgbinaryDecoder.swift
//  TablePro
//

import Foundation

// https://github.com/igbinary/igbinary/blob/master/src/php7/igbinary.c
// References carry the number PHP's serialize() would give them, so `r:`/`R:` read the same in both viewers.
internal enum IgbinaryDecoder {
    static let maxDepth = PhpSerializeParser.depthCap
    // Arrays repeated by value share storage, so a few bytes can stand for billions of values; past this it is refused.
    static let maxSlots = 10_000_000
    // A two-byte string ID can repeat a long string; the tree and Find would each walk every copy.
    static let maxRepeatedStringBytes = 20_000_000

    static func decode(_ data: Data, maxValues: Int = .max) throws -> PhpValue {
        var reader = BinaryValueReader(data)
        let version = try reader.readUInt32()
        guard version == 1 || version == 2 else {
            throw BinaryValueDecodeError(kind: .unknownVersion(version), offset: 0)
        }
        var parser = Parser(reader: reader, budget: maxValues)
        let value = try parser.value(depth: 0)
        if !parser.isTruncated, !parser.reader.isAtEnd {
            throw parser.reader.error(.trailingBytes(parser.reader.remaining))
        }
        return value
    }

    private enum Tag: UInt8 {
        case null = 0x00
        case ref8, ref16, ref32
        case boolFalse, boolTrue
        case long8p, long8n, long16p, long16n, long32p, long32n
        case double
        case stringEmpty
        case stringID8, stringID16, stringID32
        case string8, string16, string32
        case array8, array16, array32
        case object8, object16, object32
        case objectID8, objectID16, objectID32
        case objectSer8, objectSer16, objectSer32
        case long64p, long64n
        case objref8, objref16, objref32
        case reference
        case string64
        case enumCase
    }

    // What serialize() writes where igbinary refers back by value: arrays in full, objects as `r:`.
    private struct Copy {
        let value: PhpValue
        let slots: Int
    }

    private struct Decoded {
        let value: PhpValue
        let copy: Copy
    }

    private struct Parser {
        var reader: BinaryValueReader
        var budget: Int
        var isTruncated = false
        private var strings: [String] = []
        // Indexed like igbinary's reference table: each array, object and referenced scalar, as serialize() numbers it.
        private var references: [(slot: Int, copy: Copy?)] = []
        private var slot = 0
        private var repeatedStringBytes = 0

        init(reader: BinaryValueReader, budget: Int) {
            self.reader = reader
            self.budget = budget
        }

        mutating func value(depth: Int) throws -> PhpValue {
            try decoded(depth: depth).value
        }

        private mutating func decoded(depth: Int) throws -> Decoded {
            guard depth <= IgbinaryDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            guard budget > 0 else {
                isTruncated = true
                return Decoded(value: .tooLarge, copy: Copy(value: .tooLarge, slots: 1))
            }
            budget -= 1
            slot += 1
            return try decoded(tag: try readTag(), depth: depth, isReference: false)
        }

        private mutating func decoded(tag: Tag, depth: Int, isReference: Bool) throws -> Decoded {
            let ownSlot = slot
            switch tag {
            case .reference:
                guard !isReference else { throw invalid(tag, at: reader.offset - 1) }
                let result = try decoded(tag: try readTag(), depth: depth, isReference: true)
                switch result.value {
                case .null, .bool, .int, .float, .string: references.append((ownSlot, result.copy))
                default: break
                }
                return result
            case .ref8, .ref16, .ref32:
                let target = try reference(width: tag)
                if isReference {
                    // A PHP reference to a value already written takes no number of its own, as `R:` in serialize().
                    slot -= 1
                    let value = PhpValue.reference(id: target.slot)
                    return Decoded(value: value, copy: Copy(value: value, slots: 0))
                }
                // Not wrapped as a reference: the same array again by value, which serialize() writes out in full.
                guard let copy = target.copy else {
                    throw BinaryValueDecodeError(kind: .unknownReference(target.id), offset: target.offset)
                }
                slot += copy.slots - 1
                guard slot <= IgbinaryDecoder.maxSlots else { throw reader.error(.tooLarge) }
                return Decoded(value: copy.value, copy: copy)
            case .objref8, .objref16, .objref32:
                let value = PhpValue.reference(id: try reference(width: tag).slot)
                return Decoded(value: value, copy: Copy(value: value, slots: 1))
            case .null:
                return Self.scalar(.null)
            case .boolFalse:
                return Self.scalar(.bool(false))
            case .boolTrue:
                return Self.scalar(.bool(true))
            case .long8p, .long8n, .long16p, .long16n, .long32p, .long32n, .long64p, .long64n:
                return Self.scalar(.int(try integer(tag)))
            case .double:
                return Self.scalar(.float(Double(bitPattern: try reader.readUInt64())))
            case .stringEmpty:
                return Self.scalar(.string(""))
            case .stringID8, .stringID16, .stringID32:
                return Self.scalar(.string(try storedString(width: tag)))
            case .string8, .string16, .string32, .string64:
                return Self.scalar(.string(try newString(tag)))
            case .array8, .array16, .array32:
                let count = try length(tag)
                let index = references.count
                references.append((ownSlot, nil))
                let children = try entries(count: count, depth: depth)
                let copy = Copy(
                    value: .array(children.map { PhpKeyValue(key: $0.key, value: $0.copy.value) }),
                    slots: children.reduce(1) { $0 + $1.copy.slots }
                )
                references[index].copy = copy
                return Decoded(value: .array(children.map { PhpKeyValue(key: $0.key, value: $0.value) }), copy: copy)
            case .object8, .object16, .object32:
                return try object(className: try newString(tag), depth: depth, slot: ownSlot)
            case .objectID8, .objectID16, .objectID32:
                return try object(className: try storedString(width: tag), depth: depth, slot: ownSlot)
            case .objectSer8, .objectSer16, .objectSer32, .enumCase:
                throw invalid(tag, at: reader.offset - 1)
            }
        }

        private static func scalar(_ value: PhpValue) -> Decoded {
            Decoded(value: value, copy: Copy(value: value, slots: 1))
        }

        private mutating func object(className: String, depth: Int, slot ownSlot: Int) throws -> Decoded {
            let objectCopy = Copy(value: .reference(id: ownSlot), slots: 1)
            references.append((ownSlot, objectCopy))
            let tag = try readTag()
            let value: PhpValue
            switch tag {
            case .array8, .array16, .array32:
                let count = try length(tag)
                let properties = try entries(count: count, depth: depth).map { entry -> PhpProperty in
                    let property = decodePhpPropertyKey(Self.keyText(entry.key))
                    return PhpProperty(name: property.name, visibility: property.visibility, value: entry.value)
                }
                value = .object(className: className, properties: properties)
            case .objectSer8, .objectSer16, .objectSer32:
                let payload = try reader.readBytes(try length(tag))
                value = .serializable(className: className, rawPayload: Self.text(payload))
            case .enumCase:
                let caseTag = try readTag()
                let caseName: String
                switch caseTag {
                case .string8, .string16, .string32, .string64: caseName = try newString(caseTag)
                case .stringID8, .stringID16, .stringID32: caseName = try storedString(width: caseTag)
                default: throw invalid(caseTag, at: reader.offset - 1)
                }
                value = .enumCase(className: className, caseName: caseName)
            default:
                throw invalid(tag, at: reader.offset - 1)
            }
            return Decoded(value: value, copy: objectCopy)
        }

        // A count past the bytes left is forged; checking first keeps it from reserving gigabytes.
        private mutating func entries(count: Int, depth: Int) throws -> [(key: PhpValue, value: PhpValue, copy: Copy)] {
            guard count <= reader.remaining else { throw reader.error(.unexpectedEnd) }
            var entries: [(key: PhpValue, value: PhpValue, copy: Copy)] = []
            entries.reserveCapacity(min(count, 1_024))
            for _ in 0..<count {
                let keyTag = try readTag()
                let key: PhpValue
                switch keyTag {
                case .null:
                    continue
                case .long8p, .long8n, .long16p, .long16n, .long32p, .long32n, .long64p, .long64n:
                    key = .int(try integer(keyTag))
                case .stringEmpty:
                    key = .string("")
                case .stringID8, .stringID16, .stringID32:
                    key = .string(try storedString(width: keyTag))
                case .string8, .string16, .string32, .string64:
                    key = .string(try newString(keyTag))
                default:
                    throw invalid(keyTag, at: reader.offset - 1)
                }
                let item = try decoded(depth: depth + 1)
                entries.append((key, item.value, item.copy))
                if isTruncated { break }
            }
            return entries
        }

        // PHP strings are bytes; ones that are not UTF-8 show each byte as one character.
        private static func text(_ bytes: Data) -> String {
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }

        private static func keyText(_ key: PhpValue) -> String {
            if case .int(let number) = key { return String(number) }
            if case .string(let text) = key { return text }
            return ""
        }

        private mutating func integer(_ tag: Tag) throws -> Int {
            let start = reader.offset
            let magnitude: UInt64
            let isNegative: Bool
            switch tag {
            case .long8p, .long8n:
                magnitude = UInt64(try reader.readByte())
                isNegative = tag == .long8n
            case .long16p, .long16n:
                magnitude = UInt64(try reader.readUInt16())
                isNegative = tag == .long16n
            case .long32p, .long32n:
                magnitude = UInt64(try reader.readUInt32())
                isNegative = tag == .long32n
            default:
                magnitude = try reader.readUInt64()
                isNegative = tag == .long64n
            }
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

        private mutating func length(_ tag: Tag) throws -> Int {
            switch tag {
            case .string8, .array8, .object8, .objectSer8:
                return Int(try reader.readByte())
            case .string16, .array16, .object16, .objectSer16:
                return Int(try reader.readUInt16())
            case .string64:
                let start = reader.offset
                let count = try reader.readUInt64()
                guard count <= UInt64(reader.remaining) else {
                    throw BinaryValueDecodeError(kind: .unexpectedEnd, offset: start)
                }
                return Int(count)
            default:
                return Int(try reader.readUInt32())
            }
        }

        private mutating func index(width tag: Tag) throws -> Int {
            switch tag {
            case .ref8, .objref8, .stringID8, .objectID8:
                return Int(try reader.readByte())
            case .ref16, .objref16, .stringID16, .objectID16:
                return Int(try reader.readUInt16())
            default:
                return Int(try reader.readUInt32())
            }
        }

        // Every string igbinary writes in full, keys and class names included, joins the table it refers back to.
        private mutating func newString(_ tag: Tag) throws -> String {
            let text = Self.text(try reader.readBytes(try length(tag)))
            strings.append(text)
            return text
        }

        private mutating func storedString(width tag: Tag) throws -> String {
            let start = reader.offset
            let id = try index(width: tag)
            guard id < strings.count else {
                throw BinaryValueDecodeError(kind: .unknownReference(id), offset: start)
            }
            repeatedStringBytes += strings[id].utf8.count
            guard repeatedStringBytes <= IgbinaryDecoder.maxRepeatedStringBytes else {
                throw BinaryValueDecodeError(kind: .tooLarge, offset: start)
            }
            return strings[id]
        }

        private mutating func reference(width tag: Tag) throws -> (id: Int, offset: Int, slot: Int, copy: Copy?) {
            let start = reader.offset
            let id = try index(width: tag)
            guard id < references.count else {
                throw BinaryValueDecodeError(kind: .unknownReference(id), offset: start)
            }
            return (id, start, references[id].slot, references[id].copy)
        }

        private mutating func readTag() throws -> Tag {
            let start = reader.offset
            let byte = try reader.readByte()
            guard let tag = Tag(rawValue: byte) else {
                throw BinaryValueDecodeError(kind: .invalidByte(byte), offset: start)
            }
            return tag
        }

        private func invalid(_ tag: Tag, at offset: Int) -> BinaryValueDecodeError {
            BinaryValueDecodeError(kind: .invalidByte(tag.rawValue), offset: offset)
        }
    }
}
