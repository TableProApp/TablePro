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

// Reads a value as `protoc --decode=<message>` does: known fields in number order, then the ones the schema does not
// name, by number, as `--decode_raw` shows them. A field whose wire type does not match its declaration is one of those.
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
        let fields = try walker.fields(&reader, message: message, depth: 0, group: nil)
        return ProtobufTypedMessage(typeName: message.fullName, fields: fields, framing: framing)
    }

    private struct Walker {
        let schema: ProtobufSchema
        var budget: Int
        var isTruncated = false

        mutating func fields(
            _ reader: inout BinaryValueReader,
            message: ProtobufMessageDescriptor?,
            depth: Int,
            group: Int?
        ) throws -> [ProtobufTypedField] {
            guard depth < ProtobufWireDecoder.maxDepth else { throw reader.error(.nestingTooDeep) }
            var known: [Int: [ProtobufTypedField]] = [:]
            var unknown: [ProtobufTypedField] = []
            // A singular message seen twice is merged, which is what parsing its occurrences' bytes back to back does.
            var singularMessages: [Int: Data] = [:]
            func add(_ field: ProtobufTypedField, descriptor: ProtobufFieldDescriptor?) {
                guard let descriptor else {
                    unknown.append(field)
                    return
                }
                // A repeated field keeps every value; any other keeps the last, as a parser does.
                if descriptor.isRepeated {
                    known[descriptor.number, default: []].append(field)
                } else {
                    known[descriptor.number] = [field]
                }
            }
            var ended = group == nil
            while !reader.isAtEnd {
                guard budget > 0 else {
                    isTruncated = true
                    break
                }
                let start = reader.offset
                let tag = try reader.readVarint()
                let number = tag >> 3
                guard tag <= UInt64(UInt32.max), number > 0, number <= UInt64(ProtobufWireDecoder.maxFieldNumber) else {
                    throw BinaryValueDecodeError(kind: .invalidField, offset: start)
                }
                let fieldNumber = Int(number)
                let wireType = tag & 7
                if wireType == 4 {
                    guard group == fieldNumber else { throw BinaryValueDecodeError(kind: .unmatchedGroupEnd, offset: start) }
                    ended = true
                    break
                }
                budget -= 1
                let descriptor = message?.field(number: fieldNumber)
                switch wireType {
                case 0:
                    let bits = try reader.readVarint()
                    if let descriptor, let text = varintText(bits, type: descriptor.type) {
                        add(typed(descriptor, .scalar(text)), descriptor: descriptor)
                    } else {
                        add(raw(fieldNumber, .varint(bits)), descriptor: nil)
                    }
                case 1:
                    let bits = try reader.readUInt64LittleEndian()
                    if let descriptor, let text = fixed64Text(bits, type: descriptor.type) {
                        add(typed(descriptor, .scalar(text)), descriptor: descriptor)
                    } else {
                        add(raw(fieldNumber, .fixed64(bits)), descriptor: nil)
                    }
                case 5:
                    let bits = try reader.readUInt32LittleEndian()
                    if let descriptor, let text = fixed32Text(bits, type: descriptor.type) {
                        add(typed(descriptor, .scalar(text)), descriptor: descriptor)
                    } else {
                        add(raw(fieldNumber, .fixed32(bits)), descriptor: nil)
                    }
                case 2:
                    let length = try reader.readVarint()
                    guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
                    let bytes = try reader.readBytes(Int(length))
                    if let descriptor, case .message = descriptor.type, !descriptor.isRepeated {
                        singularMessages[fieldNumber, default: Data()].append(bytes)
                    } else if let descriptor, let values = lengthDelimited(bytes, descriptor: descriptor, depth: depth) {
                        for value in values { add(typed(descriptor, value), descriptor: descriptor) }
                    } else {
                        add(raw(fieldNumber, ProtobufWireDecoder.lengthDelimited(bytes)), descriptor: nil)
                    }
                case 3:
                    if let descriptor, case .group(let name) = descriptor.type {
                        let members = try fields(&reader, message: schema.messages[name], depth: depth + 1, group: fieldNumber)
                        let groupName = schema.messages[name]?.shortName ?? descriptor.name
                        add(
                            ProtobufTypedField(name: groupName, typeName: "group", value: .message(members)),
                            descriptor: descriptor
                        )
                    } else {
                        let members = try fields(&reader, message: nil, depth: depth + 1, group: fieldNumber)
                        add(ProtobufTypedField(name: String(fieldNumber), typeName: nil, value: .message(members)), descriptor: nil)
                    }
                default:
                    throw BinaryValueDecodeError(kind: .invalidField, offset: start)
                }
                if isTruncated { break }
            }
            if !ended, !isTruncated { throw reader.error(.unexpectedEnd) }
            for (number, bytes) in singularMessages {
                guard let descriptor = message?.field(number: number) else { continue }
                if let values = lengthDelimited(bytes, descriptor: descriptor, depth: depth) {
                    known[number] = values.map { typed(descriptor, $0) }
                } else {
                    unknown.append(raw(number, ProtobufWireDecoder.lengthDelimited(bytes)))
                }
            }
            var result = known.keys.sorted().flatMap { known[$0] ?? [] } + unknown
            if isTruncated, depth == 0 { result.append(ProtobufTypedField(name: "", typeName: nil, value: .truncated)) }
            return result
        }

        private func typed(_ descriptor: ProtobufFieldDescriptor, _ value: ProtobufTypedValue) -> ProtobufTypedField {
            ProtobufTypedField(name: descriptor.name, typeName: typeName(descriptor.type), value: value)
        }

        private func raw(_ number: Int, _ value: ProtobufFieldValue) -> ProtobufTypedField {
            ProtobufTypedField(name: String(number), typeName: nil, value: .unknown(value))
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

        // nil leaves the value to the fields the schema does not name.
        private mutating func lengthDelimited(
            _ bytes: Data,
            descriptor: ProtobufFieldDescriptor,
            depth: Int
        ) -> [ProtobufTypedValue]? {
            switch descriptor.type {
            case .scalar(.string):
                guard let text = String(data: bytes, encoding: .utf8) else { return nil }
                return [.string(text)]
            case .scalar(.bytes):
                return [.bytes(bytes)]
            case .message(let name):
                var nested = BinaryValueReader(bytes)
                var attempt = self
                guard let members = try? attempt.fields(&nested, message: schema.messages[name], depth: depth + 1, group: nil) else {
                    return nil
                }
                self = attempt
                return [.message(members)]
            case .scalar, .enumeration:
                guard descriptor.isRepeated else { return nil }
                return packed(bytes, type: descriptor.type)
            case .group, .unresolved:
                return nil
            }
        }

        private mutating func packed(_ bytes: Data, type: ProtobufFieldType) -> [ProtobufTypedValue]? {
            var reader = BinaryValueReader(bytes)
            var values: [ProtobufTypedValue] = []
            while !reader.isAtEnd {
                guard budget > 0 else {
                    isTruncated = true
                    break
                }
                let text: String?
                switch type {
                case .scalar(.double), .scalar(.fixed64), .scalar(.sfixed64):
                    text = (try? reader.readUInt64LittleEndian()).flatMap { fixed64Text($0, type: type) }
                case .scalar(.float), .scalar(.fixed32), .scalar(.sfixed32):
                    text = (try? reader.readUInt32LittleEndian()).flatMap { fixed32Text($0, type: type) }
                default:
                    text = (try? reader.readVarint()).flatMap { varintText($0, type: type) }
                }
                guard let text else { return nil }
                values.append(.scalar(text))
                budget -= 1
            }
            return values
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
