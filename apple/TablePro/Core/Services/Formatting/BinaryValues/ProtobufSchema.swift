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
    // A real oneof only: proto3 `optional` puts a field in a oneof of its own.
    let oneofIndex: Int?
    // Without presence, a field holding its default is not printed.
    let hasPresence: Bool
    // protoc refuses the whole value when such a string is not UTF-8.
    let validatesUTF8: Bool
    // An editions message field sent with group framing.
    let isDelimited: Bool
}

internal struct ProtobufMessageDescriptor: Equatable, Sendable {
    let fullName: String
    let fields: [ProtobufFieldDescriptor]
    // Map entries included: a Schema Registry message index counts them.
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
    // A closed enum keeps a number it does not declare out of the field, with the unknown fields.
    let isClosed: Bool

    var shortName: String {
        fullName.split(separator: ".").last.map(String.init) ?? fullName
    }
}

internal struct ProtobufSchemaError: Error, Equatable, Sendable {
    let reason: String

    static var notASchema: ProtobufSchemaError {
        ProtobufSchemaError(reason: String(localized: "The file is neither a .proto file nor a descriptor set."))
    }
}

// The first file is the one chosen, the primary file of a descriptor set, or the subject a registry returned.
internal struct ProtobufSchema: Equatable, Sendable {
    let messages: [String: ProtobufMessageDescriptor]
    let enums: [String: ProtobufEnumDescriptor]
    // A Schema Registry message index walks these.
    let rootMessages: [String]
    // The first file's messages first, map entries left out.
    let messageNames: [String]

    static let maxMessages = 20_000

    static func parse(_ data: Data) throws -> ProtobufSchema {
        var textError: ProtobufSchemaError?
        if let text = String(data: data, encoding: .utf8) {
            let files: [ProtobufFileDefinition]?
            do {
                files = try ProtoFileParser.parse(text)
            } catch {
                files = nil
                textError = error as? ProtobufSchemaError
            }
            if let files { return try build(files) }
        }
        do {
            return try build(ProtobufDescriptorSetParser.parse(data))
        } catch {
            if let textError, looksLikeText(data) { throw textError }
            throw (error as? ProtobufSchemaError) ?? .notASchema
        }
    }

    static func parse(protoFiles texts: [String]) throws -> ProtobufSchema {
        try build(texts.flatMap { try ProtoFileParser.parse($0) })
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

    // A descriptor set always holds control bytes; a .proto file holds none but whitespace.
    private static func looksLikeText(_ data: Data) -> Bool {
        !data.contains { $0 < 0x20 && !(0x09...0x0D).contains($0) }
    }

    private static func build(_ files: [ProtobufFileDefinition]) throws -> ProtobufSchema {
        var definitions: [String: ProtobufMessageDefinition] = [:]
        var enumDefinitions: [String: ProtobufEnumDefinition] = [:]
        var order: [String] = []
        for file in files {
            for message in file.allMessages {
                if definitions[message.fullName] == nil { order.append(message.fullName) }
                definitions[message.fullName] = message
            }
            for enumeration in file.allEnums {
                enumDefinitions[enumeration.fullName] = enumeration
            }
        }
        guard definitions.count <= maxMessages else {
            throw ProtobufSchemaError(reason: String(localized: "The schema defines more messages than TablePro reads."))
        }
        guard !definitions.isEmpty else {
            throw ProtobufSchemaError(reason: String(localized: "The file defines no message."))
        }
        let scopes = ProtobufFeatureScopes(files: files, messages: definitions, enums: enumDefinitions)
        let resolver = ProtobufTypeResolver(
            messageNames: Set(definitions.keys),
            enumNames: Set(enumDefinitions.keys),
            mapEntryNames: Set(definitions.values.filter(\.isMapEntry).map(\.fullName))
        )
        var resolved: [String: ProtobufMessageDescriptor] = [:]
        for (name, message) in definitions {
            let features = scopes.messages[name] ?? ProtobufFeatures(syntax: .proto2)
            resolved[name] = ProtobufMessageDescriptor(
                fullName: name,
                fields: message.fields.map {
                    resolver.resolve($0, scope: name, features: features, inMapEntry: message.isMapEntry)
                },
                nestedMessages: message.nestedMessages,
                isMapEntry: message.isMapEntry
            )
        }
        var enums: [String: ProtobufEnumDescriptor] = [:]
        for (name, enumeration) in enumDefinitions {
            enums[name] = ProtobufEnumDescriptor(
                fullName: name, values: enumeration.values, isClosed: scopes.closedEnums[name] ?? false
            )
        }
        return ProtobufSchema(
            messages: resolved,
            enums: enums,
            rootMessages: files.first?.messages ?? [],
            messageNames: order.filter { resolved[$0]?.isMapEntry == false }
        )
    }
}

internal enum ProtobufSyntax: Sendable {
    case proto2, proto3, editions
}

// The `features` a scope sets; only an editions file can set them.
internal struct ProtobufFeatureOverrides: Equatable, Sendable {
    var implicitPresence: Bool?
    var closedEnum: Bool?
    var validatesUTF8: Bool?
    var delimitedMessages: Bool?
}

internal struct ProtobufFileDefinition: Sendable {
    var name = ""
    var dependencies: [String] = []
    var syntax = ProtobufSyntax.proto2
    var features = ProtobufFeatureOverrides()
    var messages: [String] = []
    var enums: [String] = []
    var allMessages: [ProtobufMessageDefinition] = []
    var allEnums: [ProtobufEnumDefinition] = []
}

internal struct ProtobufMessageDefinition: Sendable {
    let fullName: String
    var fields: [ProtobufFieldDefinition] = []
    var nestedMessages: [String] = []
    var nestedEnums: [String] = []
    var isMapEntry = false
    var features = ProtobufFeatureOverrides()
}

internal struct ProtobufEnumDefinition: Sendable {
    let fullName: String
    var values: [Int32: String] = [:]
    var features = ProtobufFeatureOverrides()
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
    var isOptional = false
    var oneofIndex: Int?
    var features = ProtobufFeatureOverrides()
}

private struct ProtobufFeatures {
    let syntax: ProtobufSyntax
    var implicitPresence: Bool
    var closedEnum: Bool
    var validatesUTF8: Bool
    var delimitedMessages = false

    init(syntax: ProtobufSyntax) {
        self.syntax = syntax
        implicitPresence = syntax == .proto3
        closedEnum = syntax == .proto2
        validatesUTF8 = syntax != .proto2
    }

    func applying(_ overrides: ProtobufFeatureOverrides?) -> ProtobufFeatures {
        guard syntax == .editions, let overrides else { return self }
        var result = self
        if let implicitPresence = overrides.implicitPresence { result.implicitPresence = implicitPresence }
        if let closedEnum = overrides.closedEnum { result.closedEnum = closedEnum }
        if let validatesUTF8 = overrides.validatesUTF8 { result.validatesUTF8 = validatesUTF8 }
        if let delimitedMessages = overrides.delimitedMessages { result.delimitedMessages = delimitedMessages }
        return result
    }
}

// Features inherit from the file through each enclosing message, wherever in the scope the option is written.
private struct ProtobufFeatureScopes {
    private(set) var messages: [String: ProtobufFeatures] = [:]
    private(set) var closedEnums: [String: Bool] = [:]

    init(
        files: [ProtobufFileDefinition],
        messages definitions: [String: ProtobufMessageDefinition],
        enums enumDefinitions: [String: ProtobufEnumDefinition]
    ) {
        for file in files {
            let base = ProtobufFeatures(syntax: file.syntax).applying(file.features)
            var pending = file.messages.map { ($0, base) }
            for name in file.enums {
                closedEnums[name] = base.applying(enumDefinitions[name]?.features).closedEnum
            }
            while let (name, inherited) = pending.popLast() {
                guard messages[name] == nil, let definition = definitions[name] else { continue }
                let features = inherited.applying(definition.features)
                messages[name] = features
                pending += definition.nestedMessages.map { ($0, features) }
                for nested in definition.nestedEnums {
                    closedEnums[nested] = features.applying(enumDefinitions[nested]?.features).closedEnum
                }
            }
            for message in file.allMessages where messages[message.fullName] == nil {
                messages[message.fullName] = base.applying(message.features)
            }
            for enumeration in file.allEnums where closedEnums[enumeration.fullName] == nil {
                closedEnums[enumeration.fullName] = base.applying(enumeration.features).closedEnum
            }
        }
    }
}

// C++ scoping: a name is looked up from the innermost scope outward, by its first component.
private struct ProtobufTypeResolver {
    let messageNames: Set<String>
    let enumNames: Set<String>
    let mapEntryNames: Set<String>

    func resolve(
        _ field: ProtobufFieldDefinition,
        scope: String,
        features: ProtobufFeatures,
        inMapEntry: Bool
    ) -> ProtobufFieldDescriptor {
        let type: ProtobufFieldType
        switch field.type {
        case .scalar(let scalar):
            type = .scalar(scalar)
        case .group(let fullName):
            type = .group(fullName)
        case .named(let reference):
            type = resolve(reference, scope: scope)
        }
        let fieldFeatures = features.applying(field.features)
        let isImplicit = fieldFeatures.implicitPresence && !field.isOptional
        let isMessage: Bool
        switch type {
        case .message, .group: isMessage = true
        case .scalar, .enumeration, .unresolved: isMessage = false
        }
        return ProtobufFieldDescriptor(
            name: field.name,
            number: field.number,
            type: type,
            isRepeated: field.isRepeated,
            oneofIndex: field.oneofIndex,
            hasPresence: !field.isRepeated && (field.oneofIndex != nil || isMessage || !isImplicit),
            validatesUTF8: fieldFeatures.validatesUTF8,
            isDelimited: !inMapEntry && isDelimited(type, features: fieldFeatures)
        )
    }

    // A map's entries, and the messages they hold, stay length-prefixed whatever the file sets.
    private func isDelimited(_ type: ProtobufFieldType, features: ProtobufFeatures) -> Bool {
        guard features.delimitedMessages, case .message(let name) = type else { return false }
        return !mapEntryNames.contains(name)
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

// descriptor.proto read with the wire reader. Field numbers are descriptor.proto's.
internal enum ProtobufDescriptorSetParser {
    static func parse(_ data: Data) throws -> [ProtobufFileDefinition] {
        var files: [ProtobufFileDefinition] = []
        do {
            for (number, value) in try fields(data) {
                guard number == 1, case .bytes(let bytes) = value else { throw ProtobufSchemaError.notASchema }
                files.append(try file(bytes))
            }
        } catch let error as ProtobufSchemaError {
            throw error
        } catch {
            throw ProtobufSchemaError.notASchema
        }
        guard files.contains(where: { !$0.allMessages.isEmpty }) else { throw ProtobufSchemaError.notASchema }
        return primaryFirst(files)
    }

    // `--include_imports` writes each dependency before the files that import it.
    private static func primaryFirst(_ files: [ProtobufFileDefinition]) -> [ProtobufFileDefinition] {
        let imported = Set(files.flatMap(\.dependencies))
        guard let primary = files.lastIndex(where: { !imported.contains($0.name) }) else { return files }
        var ordered = files
        let file = ordered.remove(at: primary)
        return [file] + ordered
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

    private static func varint(_ entries: [(Int, Value)], _ number: Int) -> UInt64? {
        for (member, value) in entries.reversed() where member == number {
            if case .varint(let raw) = value { return raw }
        }
        return nil
    }

    private static func bytes(_ entries: [(Int, Value)], _ number: Int) -> Data? {
        for (member, value) in entries.reversed() where member == number {
            if case .bytes(let data) = value { return data }
        }
        return nil
    }

    // FeatureSet: field_presence 1 (2 IMPLICIT), enum_type 2 (2 CLOSED), utf8_validation 4 (3 NONE), message_encoding 5.
    private static func features(_ entries: [(Int, Value)], options: Int, features: Int) throws -> ProtobufFeatureOverrides {
        guard let optionBytes = bytes(entries, options),
              let featureBytes = bytes(try fields(optionBytes), features) else { return ProtobufFeatureOverrides() }
        let set = try fields(featureBytes)
        var overrides = ProtobufFeatureOverrides()
        if let presence = varint(set, 1), (1...3).contains(presence) { overrides.implicitPresence = presence == 2 }
        if let enumType = varint(set, 2), (1...2).contains(enumType) { overrides.closedEnum = enumType == 2 }
        if let validation = varint(set, 4), (2...3).contains(validation) { overrides.validatesUTF8 = validation == 2 }
        if let encoding = varint(set, 5), (1...2).contains(encoding) { overrides.delimitedMessages = encoding == 2 }
        return overrides
    }

    private static func file(_ data: Data) throws -> ProtobufFileDefinition {
        let entries = try fields(data)
        var file = ProtobufFileDefinition()
        var package = ""
        var messageData: [Data] = []
        var enumData: [Data] = []
        for (number, value) in entries {
            switch (number, value) {
            case (1, _): file.name = string(value) ?? ""
            case (2, _): package = string(value) ?? ""
            case (3, _): file.dependencies.append(string(value) ?? "")
            case (4, .bytes(let bytes)): messageData.append(bytes)
            case (5, .bytes(let bytes)): enumData.append(bytes)
            default: break
            }
        }
        let syntax = bytes(entries, 12).flatMap { String(data: $0, encoding: .utf8) }
        switch syntax {
        case "proto3": file.syntax = .proto3
        case "editions": file.syntax = .editions
        default: file.syntax = (varint(entries, 14) ?? 0) >= 1_000 ? .editions : .proto2
        }
        file.features = try features(entries, options: 8, features: 50)
        var collector = Collector()
        file.messages = try messageData.map { try collector.message($0, scope: package, depth: 0) }
        file.enums = try enumData.map { try collector.enumeration($0, scope: package) }
        file.allMessages = collector.messages
        file.allEnums = collector.enums
        return file
    }

    private struct Collector {
        var messages: [ProtobufMessageDefinition] = []
        var enums: [ProtobufEnumDefinition] = []

        mutating func message(_ data: Data, scope: String, depth: Int) throws -> String {
            guard depth < ProtoFileParser.maxDepth else {
                throw ProtobufSchemaError(reason: String(localized: "Messages are nested too deeply."))
            }
            let entries = try ProtobufDescriptorSetParser.fields(data)
            let name = entries.first { $0.0 == 1 }.flatMap { string($0.1) } ?? ""
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            let slot = messages.count
            messages.append(ProtobufMessageDefinition(fullName: fullName))
            var definition = messages[slot]
            definition.features = try features(entries, options: 7, features: 12)
            for (number, value) in entries {
                guard case .bytes(let bytes) = value else { continue }
                switch number {
                case 2: definition.fields.append(try field(bytes))
                case 3: definition.nestedMessages.append(try message(bytes, scope: fullName, depth: depth + 1))
                case 4: definition.nestedEnums.append(try enumeration(bytes, scope: fullName))
                case 7: definition.isMapEntry = varint(try fields(bytes), 7).map { $0 != 0 } ?? false
                default: break
                }
            }
            messages[slot] = definition
            return fullName
        }

        mutating func enumeration(_ data: Data, scope: String) throws -> String {
            let entries = try ProtobufDescriptorSetParser.fields(data)
            var name = ""
            var values: [Int32: String] = [:]
            for (number, value) in entries {
                if number == 1 { name = string(value) ?? "" }
                guard number == 2, case .bytes(let bytes) = value else { continue }
                var valueName = ""
                var valueNumber: Int32 = 0
                for (member, memberValue) in try ProtobufDescriptorSetParser.fields(bytes) {
                    if member == 1 { valueName = string(memberValue) ?? "" }
                    if member == 2, case .varint(let raw) = memberValue { valueNumber = Int32(truncatingIfNeeded: raw) }
                }
                // protoc prints an aliased number by its first name.
                if values[valueNumber] == nil { values[valueNumber] = valueName }
            }
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            enums.append(ProtobufEnumDefinition(
                fullName: fullName, values: values, features: try features(entries, options: 3, features: 7)
            ))
            return fullName
        }

        private func field(_ data: Data) throws -> ProtobufFieldDefinition {
            let entries = try ProtobufDescriptorSetParser.fields(data)
            let typeCode = varint(entries, 5) ?? 0
            let typeName = bytes(entries, 6).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
            let isProto3Optional = (varint(entries, 17) ?? 0) != 0
            var definition = ProtobufFieldDefinition(
                name: bytes(entries, 1).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                number: Int(truncatingIfNeeded: varint(entries, 3) ?? 0),
                type: type,
                isRepeated: varint(entries, 4) == 3
            )
            definition.isOptional = isProto3Optional
            if !isProto3Optional, let index = varint(entries, 9) { definition.oneofIndex = Int(truncatingIfNeeded: index) }
            definition.features = try features(entries, options: 8, features: 21)
            return definition
        }

        private static let scalarTypes: [UInt64: ProtobufScalarType] = [
            1: .double, 2: .float, 3: .int64, 4: .uint64, 5: .int32, 6: .fixed64, 7: .fixed32, 8: .bool,
            9: .string, 12: .bytes, 13: .uint32, 15: .sfixed32, 16: .sfixed64, 17: .sint32, 18: .sint64,
        ]
    }
}
