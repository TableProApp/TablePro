//
//  ProtobufSchemaDecoder.swift
//  TablePro
//

import Foundation

internal struct ProtobufTypedField: Equatable, Sendable {
    // The field's name, or its number when the schema does not name it.
    let name: String
    // The declared type, which the viewer shows as the badge; nil for a field the schema does not name.
    let typeName: String?
    let value: ProtobufTypedValue
}

internal indirect enum ProtobufTypedValue: Equatable, Sendable {
    // Numbers, bools and enum values, already in `protoc --decode` spelling.
    case scalar(String)
    case string(String)
    case bytes(Data)
    case message([ProtobufTypedField])
    case unknown(ProtobufFieldValue)
    case truncated
}

internal struct ProtobufTypedMessage: Equatable, Sendable {
    let typeName: String
    let fields: [ProtobufTypedField]
    let framing: ProtobufFraming?
}

// Matches `protoc --decode=<message>`: known fields by number, then the rest in wire order as `--decode_raw` prints them.
internal enum ProtobufSchemaDecoder {
    // A nil message takes the one a Schema Registry frame's message indexes name.
    static func decode(
        _ data: Data,
        schema: ProtobufSchema,
        message messageName: String?,
        maxValues: Int = .max
    ) throws -> ProtobufTypedMessage {
        var reader = BinaryValueReader(data)
        var framing: ProtobufFraming?
        if reader.peekByte() == 0 {
            framing = try ProtobufWireDecoder.readFraming(&reader)
        }
        let message: ProtobufMessageDescriptor?
        if let messageName {
            message = schema.messages[messageName]
        } else if let framing {
            message = schema.messageIndexed(by: framing.messageIndexes)
            if message == nil {
                throw BinaryValueDecodeError(kind: .indexOutOfRange(framing.messageIndexes.last ?? 0), offset: 1)
            }
        } else {
            message = schema.rootMessages.first.flatMap { schema.messages[$0] }
        }
        guard let message else { throw BinaryValueDecodeError(kind: .invalidField, offset: 0) }
        var walker = Walker(schema: schema, budget: maxValues)
        let payload = try reader.window(reader.remaining)
        let fields = try walker.members(of: [payload], message: message, depth: 0, asMapEntry: false)
        return ProtobufTypedMessage(typeName: message.fullName, fields: fields, framing: framing)
    }

    private struct Occurrence {
        enum Payload {
            case varint(UInt64)
            case fixed64(UInt64)
            case fixed32(UInt32)
            case lengthDelimited(BinaryValueReader)
            case group(BinaryValueReader)
        }

        let number: Int
        let payload: Payload
        let position: Int
    }

    private enum Match {
        case accepted
        case mismatched
        case undeclaredEnumValue
    }

    // protoc moves a map entry whose closed enum value is undeclared to the unknown fields whole.
    private struct MapEntryRejected: Error {}

    private struct Level {
        var fields: [ProtobufTypedField] = []
        var unknown: [Occurrence] = []
        var isCut = false
    }

    private enum MapKey: Comparable {
        case signed(Int64)
        case unsigned(UInt64)
        case bytes([UInt8])

        static func < (lhs: MapKey, rhs: MapKey) -> Bool {
            switch (lhs, rhs) {
            case (.signed(let left), .signed(let right)): return left < right
            case (.unsigned(let left), .unsigned(let right)): return left < right
            case (.bytes(let left), .bytes(let right)): return left.lexicographicallyPrecedes(right)
            default: return false
            }
        }
    }

    // An occurrence and each packed value cost one, so a cell reads no more of a large value than it can show.
    private struct Walker {
        let schema: ProtobufSchema
        var budget: Int

        mutating func members(
            of windows: [BinaryValueReader],
            message: ProtobufMessageDescriptor,
            depth: Int,
            asMapEntry: Bool
        ) throws -> [ProtobufTypedField] {
            guard depth < ProtobufWireDecoder.maxDepth else {
                throw BinaryValueDecodeError(kind: .nestingTooDeep, offset: windows.first?.offset ?? 0)
            }
            var level = Level()
            var occurrences: [Occurrence] = []
            scan: for window in windows {
                var reader = window
                while !reader.isAtEnd {
                    guard budget > 0 else {
                        level.isCut = true
                        break scan
                    }
                    occurrences.append(try Self.occurrence(&reader, depth: depth))
                    budget -= 1
                }
            }
            var accepted: [Int: [Occurrence]] = [:]
            for occurrence in occurrences {
                let field = message.field(number: occurrence.number)
                switch field.map({ match(occurrence.payload, field: $0) }) ?? .mismatched {
                case .accepted:
                    if let field { try verifyUTF8(occurrence.payload, field: field) }
                    accepted[occurrence.number, default: []].append(occurrence)
                case .undeclaredEnumValue where asMapEntry:
                    throw MapEntryRejected()
                case .mismatched, .undeclaredEnumValue:
                    // A map entry drops what it does not declare.
                    if !asMapEntry { level.unknown.append(occurrence) }
                }
            }
            keepLastOneofMember(&accepted, message: message)
            var numbers = Set(accepted.keys)
            // protoc prints an entry's key and value even when the bytes leave them out.
            if asMapEntry, !level.isCut { numbers.formUnion(message.fields.map(\.number)) }
            for number in numbers.sorted() {
                guard let field = message.field(number: number) else { continue }
                if let found = accepted[number] {
                    try append(field, found, to: &level, depth: depth, asMapEntry: asMapEntry)
                } else if let value = defaultValue(field.type) {
                    level.fields.append(typed(field, value))
                }
            }
            // An entry that cannot hold a value goes to the unknown fields whole, as protoc's parse would fail.
            if asMapEntry, !level.unknown.isEmpty { throw MapEntryRejected() }
            var fields = level.fields
            let unknown = level.unknown.enumerated().sorted {
                ($0.element.position, $0.offset) < ($1.element.position, $1.offset)
            }
            for (_, occurrence) in unknown {
                fields.append(try raw(occurrence, depth: depth))
            }
            if level.isCut { fields.append(ProtobufTypedField(name: "", typeName: nil, value: .truncated)) }
            return fields
        }

        private static func occurrence(_ reader: inout BinaryValueReader, depth: Int) throws -> Occurrence {
            let start = reader.offset
            let tag = try reader.readVarint()
            let number = tag >> 3
            guard tag <= UInt64(UInt32.max), number > 0, number <= UInt64(ProtobufWireDecoder.maxFieldNumber) else {
                throw BinaryValueDecodeError(kind: .invalidField, offset: start)
            }
            let payload: Occurrence.Payload
            switch tag & 7 {
            case 0:
                payload = .varint(try reader.readVarint())
            case 1:
                payload = .fixed64(try reader.readUInt64LittleEndian())
            case 2:
                let length = try reader.readVarint()
                guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
                payload = .lengthDelimited(try reader.window(Int(length)))
                try reader.skip(Int(length))
            case 3:
                payload = .group(try ProtobufWireDecoder.groupContents(&reader, number: Int(number), depth: depth))
            case 4:
                throw BinaryValueDecodeError(kind: .unmatchedGroupEnd, offset: start)
            case 5:
                payload = .fixed32(try reader.readUInt32LittleEndian())
            default:
                throw BinaryValueDecodeError(kind: .invalidField, offset: start)
            }
            return Occurrence(number: Int(number), payload: payload, position: start)
        }

        private func match(_ payload: Occurrence.Payload, field: ProtobufFieldDescriptor) -> Match {
            switch (field.type, payload) {
            case (.scalar(.string), .lengthDelimited), (.scalar(.bytes), .lengthDelimited),
                 (.message, .lengthDelimited), (.group, .group):
                return .accepted
            case (.scalar(.string), _), (.scalar(.bytes), _):
                return .mismatched
            case (.scalar, .lengthDelimited), (.enumeration, .lengthDelimited):
                return field.isRepeated ? .accepted : .mismatched
            case (.scalar(let scalar), .varint):
                return scalar.wireType == 0 ? .accepted : .mismatched
            case (.scalar(let scalar), .fixed64):
                return scalar.wireType == 1 ? .accepted : .mismatched
            case (.scalar(let scalar), .fixed32):
                return scalar.wireType == 5 ? .accepted : .mismatched
            case (.enumeration(let name), .varint(let raw)):
                return isDeclared(raw, enumeration: name) ? .accepted : .undeclaredEnumValue
            default:
                return .mismatched
            }
        }

        private func isDeclared(_ raw: UInt64, enumeration name: String) -> Bool {
            guard let enumeration = schema.enums[name], enumeration.isClosed else { return true }
            return enumeration.values[Int32(truncatingIfNeeded: raw)] != nil
        }

        // The member set last wins, and only what follows the last switch to it counts.
        private func keepLastOneofMember(_ accepted: inout [Int: [Occurrence]], message: ProtobufMessageDescriptor) {
            var oneofs: [Int: [Int]] = [:]
            for field in message.fields where accepted[field.number] != nil {
                if let index = field.oneofIndex { oneofs[index, default: []].append(field.number) }
            }
            for members in oneofs.values where members.count > 1 {
                let lastPositions = members.map { (number: $0, position: accepted[$0]?.last?.position ?? -1) }
                guard let winner = lastPositions.max(by: { $0.position < $1.position })?.number else { continue }
                let cutoff = lastPositions.filter { $0.number != winner }.map { $0.position }.max() ?? -1
                for number in members where number != winner { accepted[number] = nil }
                accepted[winner] = accepted[winner]?.filter { $0.position > cutoff }
            }
        }

        private mutating func append(
            _ field: ProtobufFieldDescriptor,
            _ found: [Occurrence],
            to level: inout Level,
            depth: Int,
            asMapEntry: Bool
        ) throws {
            switch field.type {
            case .message(let name), .group(let name):
                guard let nested = schema.messages[name] else {
                    level.unknown += found
                    return
                }
                if !field.isRepeated {
                    try appendMessage(field, nested, found, to: &level, depth: depth)
                } else if nested.isMapEntry {
                    try appendMapEntries(field, nested, found, to: &level, depth: depth)
                } else {
                    for occurrence in found { try appendMessage(field, nested, [occurrence], to: &level, depth: depth) }
                }
            case .scalar, .enumeration:
                if field.isRepeated {
                    for occurrence in found { appendRepeated(field, occurrence, to: &level) }
                } else if let last = found.last {
                    // Last wins first: `count: 5` then `count: 0` leaves an implicit field at its default.
                    if !asMapEntry, !field.hasPresence, holdsDefault(last.payload, type: field.type) { return }
                    level.fields.append(typed(field, value(last.payload, field: field)))
                }
            case .unresolved:
                level.unknown += found
            }
        }

        // A singular message seen again merges, which reads the same as its occurrences back to back.
        private mutating func appendMessage(
            _ field: ProtobufFieldDescriptor,
            _ nested: ProtobufMessageDescriptor,
            _ found: [Occurrence],
            to level: inout Level,
            depth: Int
        ) throws {
            let windows = found.compactMap { occurrence -> BinaryValueReader? in
                switch occurrence.payload {
                case .lengthDelimited(let window), .group(let window): return window
                case .varint, .fixed64, .fixed32: return nil
                }
            }
            let start = budget
            do {
                let members = try self.members(of: windows, message: nested, depth: depth + 1, asMapEntry: false)
                if case .group = field.type {
                    level.fields.append(ProtobufTypedField(name: nested.shortName, typeName: "group", value: .message(members)))
                } else {
                    level.fields.append(typed(field, .message(members)))
                }
            } catch let error as BinaryValueDecodeError where error.kind == .invalidUTF8 {
                throw error
            } catch {
                budget = start
                level.unknown += found
            }
        }

        // protoc sorts a map by key and keeps every entry, a repeated key included.
        private mutating func appendMapEntries(
            _ field: ProtobufFieldDescriptor,
            _ entry: ProtobufMessageDescriptor,
            _ found: [Occurrence],
            to level: inout Level,
            depth: Int
        ) throws {
            var entries: [(key: MapKey, field: ProtobufTypedField)] = []
            for occurrence in found {
                guard case .lengthDelimited(let window) = occurrence.payload else { continue }
                let start = budget
                do {
                    let members = try self.members(of: [window], message: entry, depth: depth + 1, asMapEntry: true)
                    entries.append((mapKey(members, entry: entry), typed(field, .message(members))))
                } catch let error as BinaryValueDecodeError where error.kind == .invalidUTF8 {
                    throw error
                } catch {
                    budget = start
                    level.unknown.append(occurrence)
                }
            }
            let sorted = entries.enumerated().sorted { lhs, rhs in
                lhs.element.key == rhs.element.key ? lhs.offset < rhs.offset : lhs.element.key < rhs.element.key
            }
            level.fields += sorted.map { $0.element.field }
        }

        private mutating func appendRepeated(_ field: ProtobufFieldDescriptor, _ occurrence: Occurrence, to level: inout Level) {
            guard case .lengthDelimited(let window) = occurrence.payload,
                  field.type != .scalar(.string), field.type != .scalar(.bytes) else {
                level.fields.append(typed(field, value(occurrence.payload, field: field)))
                return
            }
            var reader = window
            var values: [ProtobufTypedField] = []
            var undeclared: [Occurrence] = []
            var remaining = budget
            var isCut = false
            while !reader.isAtEnd {
                guard remaining > 0 else {
                    isCut = true
                    break
                }
                guard let item = try? Self.packedItem(&reader, type: field.type) else {
                    level.unknown.append(occurrence)
                    return
                }
                remaining -= 1
                if case .varint(let raw) = item, case .enumeration(let name) = field.type, !isDeclared(raw, enumeration: name) {
                    undeclared.append(Occurrence(number: field.number, payload: item, position: occurrence.position))
                } else {
                    values.append(typed(field, .scalar(scalarText(item, type: field.type))))
                }
            }
            budget = remaining
            level.fields += values
            level.unknown += undeclared
            if isCut { level.isCut = true }
        }

        private static func packedItem(_ reader: inout BinaryValueReader, type: ProtobufFieldType) throws -> Occurrence.Payload {
            guard case .scalar(let scalar) = type else { return .varint(try reader.readVarint()) }
            switch scalar.wireType {
            case 1: return .fixed64(try reader.readUInt64LittleEndian())
            case 5: return .fixed32(try reader.readUInt32LittleEndian())
            default: return .varint(try reader.readVarint())
            }
        }

        private mutating func raw(_ occurrence: Occurrence, depth: Int) throws -> ProtobufTypedField {
            let value: ProtobufFieldValue
            switch occurrence.payload {
            case .varint(let raw): value = .varint(raw)
            case .fixed64(let raw): value = .fixed64(raw)
            case .fixed32(let raw): value = .fixed32(raw)
            case .lengthDelimited(let window):
                value = ProtobufWireDecoder.lengthDelimited(window, depth: depth, budget: &budget)
            case .group(let window):
                value = .group(try ProtobufWireDecoder.fields(in: window, depth: depth + 1, budget: &budget))
            }
            return ProtobufTypedField(name: String(occurrence.number), typeName: nil, value: .unknown(value))
        }

        private func mapKey(_ members: [ProtobufTypedField], entry: ProtobufMessageDescriptor) -> MapKey {
            guard let key = entry.field(number: 1) else { return .signed(0) }
            let value = members.first { $0.name == key.name }?.value
            switch key.type {
            case .scalar(.string):
                if case .string(let text)? = value { return .bytes(Array(text.utf8)) }
                if case .bytes(let data)? = value { return .bytes(Array(data)) }
                return .bytes([])
            case .scalar(.bool):
                return .unsigned(value == .scalar("true") ? 1 : 0)
            case .scalar(.uint32), .scalar(.uint64), .scalar(.fixed32), .scalar(.fixed64):
                guard case .scalar(let text)? = value else { return .unsigned(0) }
                return .unsigned(UInt64(text) ?? 0)
            default:
                guard case .scalar(let text)? = value else { return .signed(0) }
                return .signed(Int64(text) ?? 0)
            }
        }

        // Floats compare by bit pattern, so -0 is not the default.
        private func holdsDefault(_ payload: Occurrence.Payload, type: ProtobufFieldType) -> Bool {
            switch payload {
            case .varint(let raw):
                switch type {
                case .scalar(.int64), .scalar(.uint64), .scalar(.sint64), .scalar(.bool): return raw == 0
                default: return UInt32(truncatingIfNeeded: raw) == 0
                }
            case .fixed64(let raw): return raw == 0
            case .fixed32(let raw): return raw == 0
            case .lengthDelimited(let window): return window.remaining == 0
            case .group: return false
            }
        }

        private func defaultValue(_ type: ProtobufFieldType) -> ProtobufTypedValue? {
            switch type {
            case .scalar(.string): return .string("")
            case .scalar(.bytes): return .bytes(Data())
            case .scalar(.bool): return .scalar("false")
            case .scalar: return .scalar("0")
            case .enumeration(let name): return .scalar(schema.enums[name]?.values[0] ?? "0")
            case .message, .group: return .message([])
            case .unresolved: return nil
            }
        }

        // Every occurrence, as protoc checks each one it parses, the ones a later value replaces included.
        private func verifyUTF8(_ payload: Occurrence.Payload, field: ProtobufFieldDescriptor) throws {
            guard field.validatesUTF8, field.type == .scalar(.string), case .lengthDelimited(let window) = payload else { return }
            var reader = window
            let data = (try? reader.readBytes(reader.remaining)) ?? Data()
            guard String(data: data, encoding: .utf8) == nil else { return }
            throw BinaryValueDecodeError(kind: .invalidUTF8, offset: window.offset)
        }

        // An unverified string that is not UTF-8 prints escaped, as protoc prints a proto2 string.
        private func value(_ payload: Occurrence.Payload, field: ProtobufFieldDescriptor) -> ProtobufTypedValue {
            guard case .lengthDelimited(let window) = payload else { return .scalar(scalarText(payload, type: field.type)) }
            var reader = window
            let data = (try? reader.readBytes(reader.remaining)) ?? Data()
            if field.type == .scalar(.string), let text = String(data: data, encoding: .utf8) { return .string(text) }
            return .bytes(data)
        }

        private func typed(_ descriptor: ProtobufFieldDescriptor, _ value: ProtobufTypedValue) -> ProtobufTypedField {
            ProtobufTypedField(name: descriptor.name, typeName: typeName(descriptor.type), value: value)
        }

        private func typeName(_ type: ProtobufFieldType) -> String {
            switch type {
            case .scalar(let scalar): return scalar.rawValue
            case .message(let name): return schema.messages[name]?.shortName ?? name
            case .enumeration(let name): return schema.enums[name]?.shortName ?? name
            case .group: return "group"
            case .unresolved(let name): return name
            }
        }

        private func scalarText(_ payload: Occurrence.Payload, type: ProtobufFieldType) -> String {
            switch payload {
            case .varint(let raw): return varintText(raw, type: type) ?? String(raw)
            case .fixed64(let raw): return fixed64Text(raw, type: type) ?? String(raw)
            case .fixed32(let raw): return fixed32Text(raw, type: type) ?? String(raw)
            case .lengthDelimited, .group: return ""
            }
        }

        private func varintText(_ raw: UInt64, type: ProtobufFieldType) -> String? {
            switch type {
            case .scalar(.int32): return String(Int32(truncatingIfNeeded: raw))
            case .scalar(.int64): return String(Int64(bitPattern: raw))
            case .scalar(.uint32): return String(UInt32(truncatingIfNeeded: raw))
            case .scalar(.uint64): return String(raw)
            case .scalar(.sint32): return String(Int32(truncatingIfNeeded: ProtobufWireDecoder.zigzag(raw)))
            case .scalar(.sint64): return String(ProtobufWireDecoder.zigzag(raw))
            case .scalar(.bool): return raw != 0 ? "true" : "false"
            case .enumeration(let name):
                let number = Int32(truncatingIfNeeded: raw)
                return schema.enums[name]?.values[number] ?? String(number)
            default: return nil
            }
        }

        private func fixed64Text(_ raw: UInt64, type: ProtobufFieldType) -> String? {
            switch type {
            case .scalar(.double): return ProtobufNumberText.double(Double(bitPattern: raw))
            case .scalar(.fixed64): return String(raw)
            case .scalar(.sfixed64): return String(Int64(bitPattern: raw))
            default: return nil
            }
        }

        private func fixed32Text(_ raw: UInt32, type: ProtobufFieldType) -> String? {
            switch type {
            case .scalar(.float): return ProtobufNumberText.float(Float(bitPattern: raw))
            case .scalar(.fixed32): return String(raw)
            case .scalar(.sfixed32): return String(Int32(bitPattern: raw))
            default: return nil
            }
        }
    }
}

private extension ProtobufScalarType {
    var wireType: UInt64 {
        switch self {
        case .double, .fixed64, .sfixed64: return 1
        case .float, .fixed32, .sfixed32: return 5
        case .string, .bytes: return 2
        case .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool: return 0
        }
    }
}

// protobuf's SimpleDtoa and SimpleFtoa: the shortest of DBL_DIG or FLT_DIG digits that reads back, else the full count.
internal enum ProtobufNumberText {
    static func double(_ value: Double) -> String {
        if let special = special(value) { return special }
        let short = String(format: "%.15g", value)
        return Double(short) == value ? short : String(format: "%.17g", value)
    }

    static func float(_ value: Float) -> String {
        if let special = special(Double(value)) { return special }
        let short = String(format: "%.6g", Double(value))
        return Float(short) == value ? short : String(format: "%.9g", Double(value))
    }

    private static func special(_ value: Double) -> String? {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return nil
    }
}

internal enum ProtobufSchemaTextWriter {
    static func text(_ fields: [ProtobufTypedField], multiLine: Bool, limit: Int = .max) -> String {
        var output = ""
        write(fields, into: &output, multiLine: multiLine, depth: 0, limit: limit)
        return multiLine ? output : output.trimmingCharacters(in: .whitespaces)
    }

    static func scalarText(_ value: ProtobufTypedValue, limit: Int = .max) -> String? {
        switch value {
        case .scalar(let text): return text
        case .string(let text): return ProtobufTextWriter.scalarText(.string(text), limit: limit)
        case .bytes(let data): return ProtobufTextWriter.scalarText(.bytes(data), limit: limit)
        case .unknown(let raw): return ProtobufTextWriter.scalarText(raw, limit: limit)
        case .message, .truncated: return nil
        }
    }

    private static func write(
        _ fields: [ProtobufTypedField],
        into output: inout String,
        multiLine: Bool,
        depth: Int,
        limit: Int
    ) {
        let indent = multiLine ? String(repeating: "  ", count: depth) : ""
        let separator = multiLine ? "\n" : " "
        for field in fields {
            let room = limit - output.utf8.count
            guard room > 0 else { return }
            switch field.value {
            case .message(let members):
                output += "\(indent)\(field.name) {\(separator)"
                write(members, into: &output, multiLine: multiLine, depth: depth + 1, limit: limit)
                output += "\(indent)}\(separator)"
            case .unknown(let raw):
                ProtobufTextWriter.write(
                    [ProtobufField(number: Int(field.name) ?? 0, value: raw)],
                    into: &output, multiLine: multiLine, depth: depth, limit: limit
                )
            case .truncated:
                output += "\(indent)…\(separator)"
            case .scalar, .string, .bytes:
                output += "\(indent)\(field.name): \(scalarText(field.value, limit: room) ?? "")\(separator)"
            }
        }
    }
}

internal enum ProtobufSchemaTreeBuilder {
    private static let maxDisplayLength = 300

    static func build(from message: ProtobufTypedMessage, formats: TreeSummaryFormats = .localized) -> ProtobufTreeNode {
        var nodeCount = 0
        let fields = message.fields.filter { $0.value != .truncated }
        return ProtobufTreeNode(
            key: nil, keyPath: "", path: .root, kind: .message,
            displayValue: "{\(formats.fields.text(fields.count))}",
            typeBadge: message.typeName.split(separator: ".").last.map(String.init),
            typedMembers: message.fields,
            children: makeChildren(fields, keyPath: nil, path: .root, formats: formats, nodeCount: &nodeCount)
        )
    }

    private static func makeChildren(
        _ fields: [ProtobufTypedField],
        keyPath: String?,
        path: TreeNodePath,
        formats: TreeSummaryFormats,
        nodeCount: inout Int
    ) -> [ProtobufTreeNode] {
        var children: [ProtobufTreeNode] = []
        var siblings = TreeSiblingCounter()
        for field in fields where field.value != .truncated {
            guard nodeCount < TreeNodeLimits.maxNodes else {
                children.append(ProtobufTreeNode(
                    key: nil, keyPath: "", path: path.appending(.truncationMarker), kind: .truncated,
                    displayValue: "… (\(fields.count - children.count) more)"
                ))
                break
            }
            nodeCount += 1
            let fieldKeyPath = keyPath.map { "\($0).\(field.name)" } ?? field.name
            let fieldPath = path.appending(siblings.key(field.name))
            switch field.value {
            case .message(let members):
                let shown = members.filter { $0.value != .truncated }
                children.append(ProtobufTreeNode(
                    key: field.name, keyPath: fieldKeyPath, path: fieldPath, kind: .message,
                    displayValue: "{\(formats.fields.text(shown.count))}",
                    typeBadge: field.typeName,
                    typedMembers: members,
                    children: makeChildren(shown, keyPath: fieldKeyPath, path: fieldPath, formats: formats, nodeCount: &nodeCount)
                ))
            case .unknown(let raw):
                children.append(ProtobufTreeBuilder.node(
                    key: field.name, keyPath: fieldKeyPath, path: fieldPath, value: raw, formats: formats, nodeCount: &nodeCount
                ))
            case .string(let text):
                let display = TreeDisplayText.quoted(text, limit: maxDisplayLength)
                children.append(ProtobufTreeNode(
                    key: field.name, keyPath: fieldKeyPath, path: fieldPath, kind: .string,
                    displayValue: display.text, isDisplayCut: display.isCut, rawValue: text, typeBadge: field.typeName
                ))
            case .scalar, .bytes, .truncated:
                let text = ProtobufSchemaTextWriter.scalarText(field.value) ?? ""
                let display = TreeDisplayText.cut(text, limit: maxDisplayLength)
                let kind: ProtobufTreeNode.Kind
                if case .bytes = field.value { kind = .bytes } else { kind = .varint }
                children.append(ProtobufTreeNode(
                    key: field.name, keyPath: fieldKeyPath, path: fieldPath, kind: kind,
                    displayValue: display.isCut ? display.text + "…" : display.text,
                    isDisplayCut: display.isCut, rawValue: text, typeBadge: field.typeName
                ))
            }
        }
        return children
    }
}
