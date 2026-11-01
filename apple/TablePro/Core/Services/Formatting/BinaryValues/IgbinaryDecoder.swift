//
//  IgbinaryDecoder.swift
//  TablePro
//

import Foundation

// https://github.com/igbinary/igbinary/blob/master/src/php7/igbinary.c
// Values are numbered the way PHP's serialize() numbers them (php_add_var_hash in ext/standard/var.c), so the
// text reads the same `r:` and `R:` serialize() writes.
internal enum IgbinaryDecoder {
    static let maxDepth = PhpSerializeParser.depthCap
    // A repeated array or string ID costs a few bytes and expands in the tree, its text and Find.
    static let maxExpandedValues = 10_000_000
    static let maxExpandedStringBytes = 20_000_000

    static func decode(_ data: Data, maxValues: Int = .max) throws -> PhpValue {
        var reader = BinaryValueReader(data)
        let version = try reader.readUInt32()
        guard version == 1 || version == 2 else {
            throw BinaryValueDecodeError(kind: .unknownVersion(version), offset: 0)
        }
        var parser = Parser(reader: reader, budget: maxValues)
        let value = try parser.value(depth: 0).value
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

    // What serialize() writes when this value turns up again inside an array igbinary repeats by value:
    // a PHP reference as `R:`, an object as `r:`, anything else written out again.
    private struct Copy {
        let value: PhpValue
        let slots: Int
        let stringBytes: Int
        // Levels of nesting below the copy, so one placed deeper than the original still fits the depth cap.
        let height: Int

        static func of(_ value: PhpValue, slots: Int, stringBytes: Int = 0) -> Copy {
            Copy(value: value, slots: slots, stringBytes: stringBytes, height: 0)
        }
    }

    private struct Decoded {
        let value: PhpValue
        let copy: Copy
    }

    private struct Entry {
        let key: PhpValue
        let keyBytes: Int
        let item: Decoded
    }

    private struct Reference {
        let slot: Int
        // Nil while an array is still being read, so a repeat of it from inside is refused.
        var copy: Copy?
    }

    private struct Parser {
        var reader: BinaryValueReader
        var budget: Int
        var isTruncated = false
        private var strings: [PhpValue] = []
        // igbinary's table: every array, every object, and every PHP reference to anything else.
        private var references: [Reference] = []
        // The number serialize() gives the value being read.
        private var slot = 0
        private var stringBytes = 0

        init(reader: BinaryValueReader, budget: Int) {
            self.reader = reader
            self.budget = budget
        }

        mutating func value(depth: Int) throws -> Decoded {
            guard depth <= IgbinaryDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            guard budget > 0 else {
                isTruncated = true
                return Decoded(value: .tooLarge, copy: .of(.tooLarge, slots: 1))
            }
            budget -= 1
            try expand(slots: 1, stringBytes: 0)
            return try value(tag: try readTag(), depth: depth, isReference: false)
        }

        // Only a dispatch: every case is its own function, so the frames a deep value stacks up stay small.
        private mutating func value(tag: Tag, depth: Int, isReference: Bool) throws -> Decoded {
            switch tag {
            case .reference:
                guard !isReference else { throw invalid(tag) }
                return try phpReference(depth: depth)
            case .ref8, .ref16, .ref32, .objref8, .objref16, .objref32:
                return try repeated(tag, depth: depth, isReference: isReference)
            case .array8, .array16, .array32:
                return try array(tag, depth: depth)
            case .object8, .object16, .object32, .objectID8, .objectID16, .objectID32:
                return try object(tag, depth: depth)
            case .objectSer8, .objectSer16, .objectSer32, .enumCase:
                throw invalid(tag)
            default:
                return try scalar(tag)
            }
        }

        private mutating func scalar(_ tag: Tag) throws -> Decoded {
            let value: PhpValue
            var bytes = 0
            switch tag {
            case .null: value = .null
            case .boolFalse: value = .bool(false)
            case .boolTrue: value = .bool(true)
            case .double: value = .float(Double(bitPattern: try reader.readUInt64()))
            case .stringEmpty, .stringID8, .stringID16, .stringID32, .string8, .string16, .string32, .string64:
                let text = try string(tag)
                value = text.value
                bytes = text.bytes
            default: value = .int(try integer(tag))
            }
            return Decoded(value: value, copy: .of(value, slots: 1, stringBytes: bytes))
        }

        private mutating func phpReference(depth: Int) throws -> Decoded {
            let own = slot
            let target = try value(tag: try readTag(), depth: depth, isReference: true)
            if case .reference = target.value { return target }
            let copy = Copy.of(.reference(id: own), slots: 0)
            switch target.value {
            case .array, .object, .serializable, .binarySerializable, .enumCase: break
            default: references.append(Reference(slot: own, copy: copy))
            }
            return Decoded(value: target.value, copy: copy)
        }

        private mutating func repeated(_ tag: Tag, depth: Int, isReference: Bool) throws -> Decoded {
            let start = reader.offset
            let target = try reference(width: tag)
            if isReference {
                // A PHP reference to a value already numbered takes no number of its own.
                slot -= 1
                let value = PhpValue.reference(id: target.slot)
                return Decoded(value: value, copy: .of(value, slots: 0))
            }
            if tag == .objref8 || tag == .objref16 || tag == .objref32 {
                let value = PhpValue.objectReference(id: target.slot)
                return Decoded(value: value, copy: .of(value, slots: 1))
            }
            // The same array again by value, which serialize() writes out in full.
            guard let copy = target.copy else {
                throw BinaryValueDecodeError(kind: .unknownReference(target.index), offset: start)
            }
            guard depth + copy.height <= IgbinaryDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            try expand(slots: copy.slots - 1, stringBytes: copy.stringBytes)
            return Decoded(value: copy.value, copy: copy)
        }

        private mutating func array(_ tag: Tag, depth: Int) throws -> Decoded {
            let own = slot
            let count = try length(tag)
            let index = references.count
            references.append(Reference(slot: own, copy: nil))
            let entries = try entries(count: count, depth: depth)
            let copy = Self.copy(of: entries)
            references[index].copy = copy
            return Decoded(value: .array(entries.map { PhpKeyValue(key: $0.key, value: $0.item.value) }), copy: copy)
        }

        private static func copy(of entries: [Entry]) -> Copy {
            Copy(
                value: .array(entries.map { PhpKeyValue(key: $0.key, value: $0.item.copy.value) }),
                slots: entries.reduce(1) { $0 + $1.item.copy.slots },
                stringBytes: entries.reduce(0) { $0 + $1.keyBytes + $1.item.copy.stringBytes },
                height: entries.map { $0.item.copy.height + 1 }.max() ?? 0
            )
        }

        // An object takes its number before its properties are read, so one that holds itself refers back to it.
        private mutating func object(_ nameTag: Tag, depth: Int) throws -> Decoded {
            let own = slot
            let className = Self.text(try string(nameTag).value)
            let copy = Copy.of(.objectReference(id: own), slots: 1)
            references.append(Reference(slot: own, copy: copy))
            let tag = try readTag()
            let value: PhpValue
            switch tag {
            case .array8, .array16, .array32:
                let properties = try entries(count: try length(tag), depth: depth).map { entry -> PhpProperty in
                    if case .int(let index) = entry.key {
                        return PhpProperty(name: String(index), visibility: .publicVisibility, value: entry.item.value, index: index)
                    }
                    let property = decodePhpPropertyKey(Self.text(entry.key))
                    var binaryKey: Data?
                    if case .binaryString(let bytes) = entry.key { binaryKey = bytes }
                    return PhpProperty(
                        name: property.name, visibility: property.visibility, value: entry.item.value, binaryKey: binaryKey
                    )
                }
                value = .object(className: className, properties: properties)
            case .objectSer8, .objectSer16, .objectSer32:
                let payload = try reader.readBytes(try length(tag))
                value = String(data: payload, encoding: .utf8).map { .serializable(className: className, rawPayload: $0) }
                    ?? .binarySerializable(className: className, payload: payload)
            case .enumCase:
                let caseTag = try readTag()
                switch caseTag {
                case .string8, .string16, .string32, .string64, .stringID8, .stringID16, .stringID32:
                    value = .enumCase(className: className, caseName: Self.text(try string(caseTag).value))
                default:
                    throw invalid(caseTag)
                }
            default:
                throw invalid(tag)
            }
            return Decoded(value: value, copy: copy)
        }

        // A count past the bytes left is forged; checking first keeps it from reserving gigabytes.
        private mutating func entries(count: Int, depth: Int) throws -> [Entry] {
            guard count <= reader.remaining else { throw reader.error(.unexpectedEnd) }
            var entries: [Entry] = []
            entries.reserveCapacity(min(count, 1_024))
            for _ in 0..<count {
                // igbinary_unserialize_array skips an entry whose key is null and reads no value for it.
                guard let key = try key() else { continue }
                entries.append(Entry(key: key.value, keyBytes: key.bytes, item: try value(depth: depth + 1)))
                if isTruncated { break }
            }
            return entries
        }

        private mutating func key() throws -> (value: PhpValue, bytes: Int)? {
            let tag = try readTag()
            switch tag {
            case .null:
                return nil
            case .long8p, .long8n, .long16p, .long16n, .long32p, .long32n, .long64p, .long64n:
                return (.int(try integer(tag)), 0)
            case .stringEmpty, .stringID8, .stringID16, .stringID32, .string8, .string16, .string32, .string64:
                return try string(tag)
            default:
                throw invalid(tag)
            }
        }

        // Every string igbinary writes in full joins the table its string IDs index: keys, values, class names.
        private mutating func string(_ tag: Tag) throws -> (value: PhpValue, bytes: Int) {
            switch tag {
            case .stringEmpty:
                return (.string(""), 0)
            case .stringID8, .stringID16, .stringID32, .objectID8, .objectID16, .objectID32:
                let start = reader.offset
                let id = try index(width: tag)
                guard id < strings.count else {
                    throw BinaryValueDecodeError(kind: .unknownReference(id), offset: start)
                }
                let value = strings[id]
                let bytes = Self.byteCount(value)
                try expand(slots: 0, stringBytes: bytes)
                return (value, bytes)
            default:
                let data = try reader.readBytes(try length(tag))
                let value = Self.phpString(data)
                strings.append(value)
                try expand(slots: 0, stringBytes: data.count)
                return (value, data.count)
            }
        }

        private mutating func expand(slots: Int, stringBytes added: Int) throws {
            slot += slots
            stringBytes += added
            guard slot <= IgbinaryDecoder.maxExpandedValues, stringBytes <= IgbinaryDecoder.maxExpandedStringBytes else {
                throw reader.error(.tooLarge)
            }
        }

        private static func phpString(_ bytes: Data) -> PhpValue {
            String(data: bytes, encoding: .utf8).map(PhpValue.string) ?? .binaryString(bytes)
        }

        private static func byteCount(_ value: PhpValue) -> Int {
            switch value {
            case .string(let text): return text.utf8.count
            case .binaryString(let bytes): return bytes.count
            default: return 0
            }
        }

        // Names and keys PHP keeps as text; bytes that are not UTF-8 show one character each.
        private static func text(_ value: PhpValue) -> String {
            switch value {
            case .int(let number): return String(number)
            case .string(let text): return text
            case .binaryString(let bytes): return String(data: bytes, encoding: .isoLatin1) ?? ""
            default: return ""
            }
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

        private mutating func reference(width tag: Tag) throws -> (index: Int, slot: Int, copy: Copy?) {
            let start = reader.offset
            let index = try index(width: tag)
            guard index < references.count else {
                throw BinaryValueDecodeError(kind: .unknownReference(index), offset: start)
            }
            return (index, references[index].slot, references[index].copy)
        }

        private mutating func readTag() throws -> Tag {
            let start = reader.offset
            let byte = try reader.readByte()
            guard let tag = Tag(rawValue: byte) else {
                throw BinaryValueDecodeError(kind: .invalidByte(byte), offset: start)
            }
            return tag
        }

        private func invalid(_ tag: Tag) -> BinaryValueDecodeError {
            BinaryValueDecodeError(kind: .invalidByte(tag.rawValue), offset: reader.offset - 1)
        }
    }
}
