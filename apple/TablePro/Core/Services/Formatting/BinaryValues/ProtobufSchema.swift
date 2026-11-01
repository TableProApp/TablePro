//
//  ProtobufSchema.swift
//  TablePro
//

import Foundation

internal enum ProtobufScalarType: String, Equatable, Sendable {
    case double, float, int64, uint64, int32, fixed64, fixed32, bool, string, bytes, uint32
    case sfixed32, sfixed64, sint32, sint64
}

internal enum ProtobufFieldType: Equatable, Sendable {
    case scalar(ProtobufScalarType)
    case message(String)
    case enumeration(String)
    case group(String)
    // Named by a file the schema does not include, so its values read as they would with no schema.
    case unresolved(String)
}

internal struct ProtobufFieldDescriptor: Equatable, Sendable {
    let name: String
    let number: Int
    let type: ProtobufFieldType
    let isRepeated: Bool
}

internal struct ProtobufMessageDescriptor: Equatable, Sendable {
    let fullName: String
    let fields: [ProtobufFieldDescriptor]
    // In declaration order, map entries included: a Schema Registry message index counts them.
    let nestedMessages: [String]
    let isMapEntry: Bool
    private let fieldIndexes: [Int: Int]

    init(fullName: String, fields: [ProtobufFieldDescriptor], nestedMessages: [String], isMapEntry: Bool) {
        self.fullName = fullName
        self.fields = fields
        self.nestedMessages = nestedMessages
        self.isMapEntry = isMapEntry
        fieldIndexes = Dictionary(fields.enumerated().map { ($0.element.number, $0.offset) }) { first, _ in first }
    }

    var shortName: String {
        fullName.split(separator: ".").last.map(String.init) ?? fullName
    }

    func field(number: Int) -> ProtobufFieldDescriptor? {
        fieldIndexes[number].map { fields[$0] }
    }
}

internal struct ProtobufEnumDescriptor: Equatable, Sendable {
    let fullName: String
    let values: [Int32: String]

    var shortName: String {
        fullName.split(separator: ".").last.map(String.init) ?? fullName
    }
}

internal struct ProtobufSchemaError: Error, Equatable, Sendable {
    let reason: String
}

// Messages and enums by full name, without the leading dot. The first file is the one chosen or fetched;
// a Schema Registry message index walks its top-level messages.
internal struct ProtobufSchema: Equatable, Sendable {
    let messages: [String: ProtobufMessageDescriptor]
    let enums: [String: ProtobufEnumDescriptor]
    let rootMessages: [String]
    // Every message a value can be read as, in file order, map entries left out.
    let messageNames: [String]

    static let maxMessages = 20_000

    // Both forms protoc reads: `.proto` text, and the FileDescriptorSet `--descriptor_set_out` writes.
    static func parse(_ data: Data) throws -> ProtobufSchema {
        if let text = String(data: data, encoding: .utf8), let files = try? ProtoFileParser.parse(text), !files.isEmpty {
            return try build([files])
        }
        do {
            return try build([ProtobufDescriptorSetParser.parse(data)])
        } catch let error as ProtobufSchemaError {
            if let text = String(data: data, encoding: .utf8) {
                // Text that is not a descriptor set: the parser's own reason says what is wrong with it.
                _ = try ProtoFileParser.parse(text)
                throw ProtobufSchemaError(reason: String(localized: "The file defines no message."))
            }
            throw error
        }
    }

    // A fetched schema and the files it imports, each `.proto` text, the root first.
    static func parse(protoFiles texts: [String]) throws -> ProtobufSchema {
        try build(texts.map { try ProtoFileParser.parse($0) })
    }

    func messageIndexed(by indexes: [Int]) -> ProtobufMessageDescriptor? {
        guard let first = indexes.first, rootMessages.indices.contains(first),
              var message = messages[rootMessages[first]] else { return nil }
        for index in indexes.dropFirst() {
            guard message.nestedMessages.indices.contains(index),
                  let nested = messages[message.nestedMessages[index]] else { return nil }
            message = nested
        }
        return message
    }

    private static func build(_ fileGroups: [[ProtobufFileDefinition]]) throws -> ProtobufSchema {
        let files = fileGroups.flatMap { $0 }
        var messages: [String: ProtobufMessageDefinition] = [:]
        var enums: [String: ProtobufEnumDescriptor] = [:]
        var order: [String] = []
        for file in files {
            for message in file.allMessages {
                if messages[message.fullName] == nil { order.append(message.fullName) }
                messages[message.fullName] = message
            }
            for enumeration in file.allEnums {
                enums[enumeration.fullName] = enumeration
            }
        }
        guard messages.count <= maxMessages else {
            throw ProtobufSchemaError(reason: String(localized: "The schema defines more messages than TablePro reads."))
        }
        guard !messages.isEmpty else {
            throw ProtobufSchemaError(reason: String(localized: "The file defines no message."))
        }
        let resolver = ProtobufTypeResolver(messageNames: Set(messages.keys), enumNames: Set(enums.keys))
        var resolved: [String: ProtobufMessageDescriptor] = [:]
        for (name, message) in messages {
            resolved[name] = ProtobufMessageDescriptor(
                fullName: name,
                fields: message.fields.map { resolver.resolve($0, scope: name) },
                nestedMessages: message.nestedMessages,
                isMapEntry: message.isMapEntry
            )
        }
        return ProtobufSchema(
            messages: resolved,
            enums: enums,
            rootMessages: files.first?.messages.map(\.fullName) ?? [],
            messageNames: order.filter { resolved[$0]?.isMapEntry == false }
        )
    }
}

// What a parser read, before type names are resolved against every file.
internal struct ProtobufFileDefinition: Sendable {
    let messages: [ProtobufMessageDefinition]
    let enums: [ProtobufEnumDescriptor]
    // Nested types too, so build() sees every name the file declares.
    let allMessages: [ProtobufMessageDefinition]
    let allEnums: [ProtobufEnumDescriptor]
}

internal struct ProtobufMessageDefinition: Sendable {
    let fullName: String
    var fields: [ProtobufFieldDefinition]
    var nestedMessages: [String]
    var isMapEntry: Bool
}

internal struct ProtobufFieldDefinition: Sendable {
    enum TypeReference: Sendable {
        case scalar(ProtobufScalarType)
        // As written: relative, dotted, or absolute with a leading dot.
        case named(String)
        case group(String)
    }

    let name: String
    let number: Int
    let type: TypeReference
    let isRepeated: Bool
}

// C++ scoping: a name is looked up from the innermost scope outward, by its first component.
private struct ProtobufTypeResolver {
    let messageNames: Set<String>
    let enumNames: Set<String>

    func resolve(_ field: ProtobufFieldDefinition, scope: String) -> ProtobufFieldDescriptor {
        let type: ProtobufFieldType
        switch field.type {
        case .scalar(let scalar):
            type = .scalar(scalar)
        case .group(let fullName):
            type = .group(fullName)
        case .named(let reference):
            type = resolve(reference, scope: scope)
        }
        return ProtobufFieldDescriptor(name: field.name, number: field.number, type: type, isRepeated: field.isRepeated)
    }

    private func resolve(_ reference: String, scope: String) -> ProtobufFieldType {
        if reference.hasPrefix(".") {
            return lookup(String(reference.dropFirst())) ?? .unresolved(reference)
        }
        var components = scope.split(separator: ".").map(String.init)
        while true {
            let candidate = (components + [reference]).joined(separator: ".")
            if let found = lookup(candidate) { return found }
            guard !components.isEmpty else { return .unresolved(reference) }
            components.removeLast()
        }
    }

    private func lookup(_ name: String) -> ProtobufFieldType? {
        if messageNames.contains(name) { return .message(name) }
        if enumNames.contains(name) { return .enumeration(name) }
        return nil
    }
}

// descriptor.proto, read with the wire reader: FileDescriptorSet.file = 1.
internal enum ProtobufDescriptorSetParser {
    static func parse(_ data: Data) throws -> [ProtobufFileDefinition] {
        let invalid = ProtobufSchemaError(reason: String(localized: "The file is neither a .proto file nor a descriptor set."))
        guard let set = try? fields(data) else { throw invalid }
        var files: [ProtobufFileDefinition] = []
        for (number, value) in set {
            guard number == 1, case .bytes(let bytes) = value else { throw invalid }
            files.append(try file(bytes))
        }
        guard files.contains(where: { !$0.allMessages.isEmpty }) else { throw invalid }
        return files
    }

    private enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private static func fields(_ data: Data) throws -> [(Int, Value)] {
        var reader = BinaryValueReader(data)
        var result: [(Int, Value)] = []
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let number = Int(truncatingIfNeeded: tag >> 3)
            switch tag & 7 {
            case 0:
                result.append((number, .varint(try reader.readVarint())))
            case 1:
                try reader.skip(8)
            case 2:
                let length = try reader.readVarint()
                guard length <= UInt64(reader.remaining) else { throw reader.error(.unexpectedEnd) }
                result.append((number, .bytes(try reader.readBytes(Int(length)))))
            case 5:
                try reader.skip(4)
            default:
                throw reader.error(.invalidField)
            }
        }
        return result
    }

    private static func string(_ value: Value) -> String? {
        guard case .bytes(let data) = value else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func file(_ data: Data) throws -> ProtobufFileDefinition {
        var package = ""
        var messageData: [Data] = []
        var enumData: [Data] = []
        for (number, value) in try fields(data) {
            switch (number, value) {
            case (2, _): package = string(value) ?? ""
            case (4, .bytes(let bytes)): messageData.append(bytes)
            case (5, .bytes(let bytes)): enumData.append(bytes)
            default: break
            }
        }
        var collector = Collector()
        let messages = try messageData.map { try collector.message($0, scope: package, depth: 0) }
        let enums = try enumData.map { try collector.enumeration($0, scope: package) }
        return ProtobufFileDefinition(
            messages: messages, enums: enums, allMessages: collector.messages, allEnums: collector.enums
        )
    }

    private struct Collector {
        var messages: [ProtobufMessageDefinition] = []
        var enums: [ProtobufEnumDescriptor] = []

        mutating func message(_ data: Data, scope: String, depth: Int) throws -> ProtobufMessageDefinition {
            guard depth < ProtoFileParser.maxDepth else {
                throw ProtobufSchemaError(reason: String(localized: "Messages are nested too deeply."))
            }
            let entries = try ProtobufDescriptorSetParser.fields(data)
            let name = entries.first { $0.0 == 1 }.flatMap { string($0.1) } ?? ""
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            let slot = messages.count
            messages.append(ProtobufMessageDefinition(fullName: fullName, fields: [], nestedMessages: [], isMapEntry: false))
            var definition = messages[slot]
            for (number, value) in entries {
                guard case .bytes(let bytes) = value else { continue }
                switch number {
                case 2: definition.fields.append(try field(bytes))
                case 3: definition.nestedMessages.append(try message(bytes, scope: fullName, depth: depth + 1).fullName)
                case 4: enums.append(try enumeration(bytes, scope: fullName))
                case 7: definition.isMapEntry = try ProtobufDescriptorSetParser.fields(bytes).contains {
                    if $0.0 == 7, case .varint(let flag) = $0.1 { return flag != 0 }
                    return false
                }
                default: break
                }
            }
            messages[slot] = definition
            return definition
        }

        mutating func enumeration(_ data: Data, scope: String) throws -> ProtobufEnumDescriptor {
            var name = ""
            var values: [Int32: String] = [:]
            for (number, value) in try ProtobufDescriptorSetParser.fields(data) {
                if number == 1 { name = string(value) ?? "" }
                guard number == 2, case .bytes(let bytes) = value else { continue }
                var valueName = ""
                var valueNumber: Int32 = 0
                for (member, memberValue) in try ProtobufDescriptorSetParser.fields(bytes) {
                    if member == 1 { valueName = string(memberValue) ?? "" }
                    if member == 2, case .varint(let raw) = memberValue { valueNumber = Int32(truncatingIfNeeded: raw) }
                }
                // The first name wins for an aliased number, as protoc prints it.
                if values[valueNumber] == nil { values[valueNumber] = valueName }
            }
            let enumeration = ProtobufEnumDescriptor(fullName: scope.isEmpty ? name : "\(scope).\(name)", values: values)
            enums.append(enumeration)
            return enumeration
        }

        private func field(_ data: Data) throws -> ProtobufFieldDefinition {
            var name = ""
            var number = 0
            var label: UInt64 = 1
            var typeCode: UInt64 = 0
            var typeName = ""
            for (member, value) in try ProtobufDescriptorSetParser.fields(data) {
                switch (member, value) {
                case (1, _): name = string(value) ?? ""
                case (3, .varint(let raw)): number = Int(truncatingIfNeeded: raw)
                case (4, .varint(let raw)): label = raw
                case (5, .varint(let raw)): typeCode = raw
                case (6, _): typeName = string(value) ?? ""
                default: break
                }
            }
            let type: ProtobufFieldDefinition.TypeReference
            switch typeCode {
            case 10: type = .group(String(typeName.drop { $0 == "." }))
            case 11, 14, 0: type = .named(typeName)
            default:
                guard let scalar = Self.scalarTypes[typeCode] else {
                    throw ProtobufSchemaError(reason: String(
                        format: String(localized: "The descriptor set names an unknown field type %llu."), typeCode
                    ))
                }
                type = .scalar(scalar)
            }
            return ProtobufFieldDefinition(name: name, number: number, type: type, isRepeated: label == 3)
        }

        private static let scalarTypes: [UInt64: ProtobufScalarType] = [
            1: .double, 2: .float, 3: .int64, 4: .uint64, 5: .int32, 6: .fixed64, 7: .fixed32, 8: .bool,
            9: .string, 12: .bytes, 13: .uint32, 15: .sfixed32, 16: .sfixed64, 17: .sint32, 18: .sint64,
        ]
    }
}
