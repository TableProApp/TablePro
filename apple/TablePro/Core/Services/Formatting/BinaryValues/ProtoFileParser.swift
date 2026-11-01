//
//  ProtoFileParser.swift
//  TablePro
//

import Foundation

// https://protobuf.dev/reference/protobuf/proto3-spec/ and the proto2 and editions grammars: what a value needs is
// read, and options, services, extensions and reserved ranges are skipped.
internal enum ProtoFileParser {
    static let maxTokens = 2_000_000
    static let maxDepth = 100

    static func parse(_ text: String) throws -> [ProtobufFileDefinition] {
        var parser = Parser(tokens: try Tokenizer.tokens(text))
        return [try parser.file()]
    }

    fileprivate enum Token: Equatable {
        case identifier(String)
        case number(String)
        case string(String)
        case symbol(Character)
    }

    private enum Tokenizer {
        static func tokens(_ text: String) throws -> [Token] {
            let scalars = Array(text.unicodeScalars)
            var tokens: [Token] = []
            var index = 0
            while index < scalars.count {
                guard tokens.count < ProtoFileParser.maxTokens else { throw error(String(localized: "The file is too large.")) }
                let scalar = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    index += 2
                    while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                    guard index + 1 < scalars.count else { throw error(String(localized: "A comment is never closed.")) }
                    index += 2
                } else if isIdentifierStart(scalar)
                    || (scalar == "." && index + 1 < scalars.count && isIdentifierStart(scalars[index + 1])) {
                    let start = index
                    while index < scalars.count, isIdentifierPart(scalars[index]) || scalars[index] == "." { index += 1 }
                    tokens.append(.identifier(String(String.UnicodeScalarView(scalars[start..<index]))))
                } else if isDigit(scalar) || (scalar == "." && index + 1 < scalars.count && isDigit(scalars[index + 1])) {
                    let start = index
                    while index < scalars.count, isIdentifierPart(scalars[index]) || scalars[index] == "."
                        || ((scalars[index] == "+" || scalars[index] == "-") && "eE".unicodeScalars.contains(scalars[index - 1])) {
                        index += 1
                    }
                    tokens.append(.number(String(String.UnicodeScalarView(scalars[start..<index]))))
                } else if scalar == "\"" || scalar == "'" {
                    index += 1
                    var value = String.UnicodeScalarView()
                    while index < scalars.count, scalars[index] != scalar, scalars[index] != "\n" {
                        if scalars[index] == "\\", index + 1 < scalars.count { index += 1 }
                        value.append(scalars[index])
                        index += 1
                    }
                    guard index < scalars.count, scalars[index] == scalar else {
                        throw error(String(localized: "A string is never closed."))
                    }
                    index += 1
                    tokens.append(.string(String(value)))
                } else if "{}[]()<>=;,:-+".unicodeScalars.contains(scalar) {
                    tokens.append(.symbol(Character(scalar)))
                    index += 1
                } else {
                    throw error(String(format: String(localized: "Unexpected character “%@”."), String(Character(scalar))))
                }
            }
            return tokens
        }

        private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || (scalar.isASCII && CharacterSet.letters.contains(scalar))
        }

        private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
            isIdentifierStart(scalar) || isDigit(scalar)
        }

        private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("0"..."9").contains(scalar)
        }
    }

    fileprivate static func error(_ reason: String) -> ProtobufSchemaError {
        ProtobufSchemaError(reason: reason)
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var messages: [ProtobufMessageDefinition] = []
        var enums: [ProtobufEnumDescriptor] = []

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func file() throws -> ProtobufFileDefinition {
            var package = ""
            var topMessages: [ProtobufMessageDefinition] = []
            var topEnums: [ProtobufEnumDescriptor] = []
            while let token = peek() {
                switch token {
                case .identifier("syntax"), .identifier("edition"):
                    try skipStatement()
                case .identifier("package"):
                    advance()
                    package = try identifier()
                    try expect(";")
                case .identifier("import"), .identifier("option"):
                    try skipStatement()
                case .identifier("message"):
                    advance()
                    topMessages.append(try message(scope: package, depth: 0))
                case .identifier("enum"):
                    advance()
                    topEnums.append(try enumeration(scope: package))
                case .identifier("service"), .identifier("extend"):
                    try skipStatement()
                case .symbol(";"):
                    advance()
                default:
                    throw unexpected()
                }
            }
            return ProtobufFileDefinition(messages: topMessages, enums: topEnums, allMessages: messages, allEnums: enums)
        }

        private mutating func message(scope: String, depth: Int) throws -> ProtobufMessageDefinition {
            let name = try identifier()
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            try expect("{")
            let slot = messages.count
            messages.append(ProtobufMessageDefinition(fullName: fullName, fields: [], nestedMessages: [], isMapEntry: false))
            var definition = messages[slot]
            try body(of: &definition, depth: depth)
            messages[slot] = definition
            return definition
        }

        private mutating func body(of definition: inout ProtobufMessageDefinition, depth: Int) throws {
            guard depth < ProtoFileParser.maxDepth else { throw ProtoFileParser.error(String(localized: "Messages are nested too deeply.")) }
            while true {
                guard let token = peek() else { throw ProtoFileParser.error(String(localized: "A message is never closed.")) }
                switch token {
                case .symbol("}"):
                    advance()
                    return
                case .symbol(";"):
                    advance()
                case .identifier("message"):
                    advance()
                    definition.nestedMessages.append(try message(scope: definition.fullName, depth: depth + 1).fullName)
                case .identifier("enum"):
                    advance()
                    _ = try enumeration(scope: definition.fullName)
                case .identifier("oneof"):
                    advance()
                    _ = try identifier()
                    try expect("{")
                    try body(of: &definition, depth: depth + 1)
                // A Schema Registry stores a map field as the entry message protoc synthesizes for it.
                case .identifier("option") where peek(1) == .identifier("map_entry") && peek(3) == .identifier("true"):
                    definition.isMapEntry = true
                    try skipStatement()
                case .identifier("option"), .identifier("reserved"), .identifier("extensions"), .identifier("extend"):
                    try skipStatement()
                case .identifier("map") where peek(1) == .symbol("<"):
                    advance()
                    try mapField(into: &definition)
                default:
                    try field(into: &definition, depth: depth)
                }
            }
        }

        private mutating func field(into definition: inout ProtobufMessageDefinition, depth: Int) throws {
            var isRepeated = false
            if case .identifier(let label)? = peek(), ["optional", "required", "repeated"].contains(label),
               peek(1).map(Self.isTypeToken) == true, peek(2).map(Self.isTypeToken) == true || peek(2) == .symbol("=") {
                isRepeated = label == "repeated"
                advance()
            }
            let typeName = try identifier()
            if typeName == "group" {
                let groupName = try identifier()
                try expect("=")
                let number = try fieldNumber()
                try skipOptions()
                try expect("{")
                let fullName = "\(definition.fullName).\(groupName)"
                let slot = messages.count
                messages.append(ProtobufMessageDefinition(fullName: fullName, fields: [], nestedMessages: [], isMapEntry: false))
                var group = messages[slot]
                try body(of: &group, depth: depth + 1)
                messages[slot] = group
                definition.nestedMessages.append(fullName)
                definition.fields.append(ProtobufFieldDefinition(
                    name: groupName.lowercased(), number: number, type: .group(fullName), isRepeated: isRepeated
                ))
                return
            }
            let name = try identifier()
            try expect("=")
            let number = try fieldNumber()
            try skipOptions()
            try expect(";")
            let type: ProtobufFieldDefinition.TypeReference = ProtobufScalarType(rawValue: typeName).map { .scalar($0) }
                ?? .named(typeName)
            definition.fields.append(ProtobufFieldDefinition(name: name, number: number, type: type, isRepeated: isRepeated))
        }

        // protoc's synthesized entry: `<Field>Entry { key = 1; value = 2; }`, nested where the field is declared.
        private mutating func mapField(into definition: inout ProtobufMessageDefinition) throws {
            try expect("<")
            let keyType = try identifier()
            try expect(",")
            let valueType = try identifier()
            try expect(">")
            let name = try identifier()
            try expect("=")
            let number = try fieldNumber()
            try skipOptions()
            try expect(";")
            let entryName = "\(definition.fullName).\(Self.camelCased(name))Entry"
            func reference(_ type: String) -> ProtobufFieldDefinition.TypeReference {
                ProtobufScalarType(rawValue: type).map { .scalar($0) } ?? .named(type)
            }
            messages.append(ProtobufMessageDefinition(
                fullName: entryName,
                fields: [
                    ProtobufFieldDefinition(name: "key", number: 1, type: reference(keyType), isRepeated: false),
                    ProtobufFieldDefinition(name: "value", number: 2, type: reference(valueType), isRepeated: false),
                ],
                nestedMessages: [],
                isMapEntry: true
            ))
            definition.nestedMessages.append(entryName)
            // The entry sits in the message's scope, so its value type resolves from there.
            definition.fields.append(ProtobufFieldDefinition(name: name, number: number, type: .named(".\(entryName)"), isRepeated: true))
        }

        private mutating func enumeration(scope: String) throws -> ProtobufEnumDescriptor {
            let name = try identifier()
            try expect("{")
            var values: [Int32: String] = [:]
            while true {
                guard let token = peek() else { throw ProtoFileParser.error(String(localized: "An enum is never closed.")) }
                switch token {
                case .symbol("}"):
                    advance()
                    let enumeration = ProtobufEnumDescriptor(fullName: scope.isEmpty ? name : "\(scope).\(name)", values: values)
                    enums.append(enumeration)
                    return enumeration
                case .symbol(";"):
                    advance()
                case .identifier("option"), .identifier("reserved"):
                    try skipStatement()
                default:
                    let valueName = try identifier()
                    try expect("=")
                    var negative = false
                    if peek() == .symbol("-") {
                        negative = true
                        advance()
                    }
                    guard case .number(let digits)? = peek(), let magnitude = Self.integer(digits),
                          let number = Int32(exactly: negative ? -magnitude : magnitude) else { throw unexpected() }
                    advance()
                    try skipOptions()
                    try expect(";")
                    if values[number] == nil { values[number] = valueName }
                }
            }
        }

        private static func isTypeToken(_ token: Token) -> Bool {
            if case .identifier = token { return true }
            return false
        }

        private static func camelCased(_ name: String) -> String {
            var result = ""
            var upper = true
            for character in name {
                if character == "_" {
                    upper = true
                } else {
                    result += upper ? character.uppercased() : String(character)
                    upper = false
                }
            }
            return result
        }

        private static func integer(_ digits: String) -> Int64? {
            let lower = digits.lowercased()
            if lower.hasPrefix("0x") { return Int64(lower.dropFirst(2), radix: 16) }
            if lower.count > 1, lower.hasPrefix("0") { return Int64(lower.dropFirst(), radix: 8) }
            return Int64(lower)
        }

        private mutating func fieldNumber() throws -> Int {
            guard case .number(let digits)? = peek(), let value = Self.integer(digits),
                  value > 0, value <= Int64(ProtobufWireDecoder.maxFieldNumber) else { throw unexpected() }
            advance()
            return Int(value)
        }

        // `[packed = true, (custom).option = { ... }]`
        private mutating func skipOptions() throws {
            guard peek() == .symbol("[") else { return }
            try skipBalanced(open: "[", close: "]")
        }

        // To the `;` that ends it, or past the `{ ... }` block that does.
        private mutating func skipStatement() throws {
            while let token = peek() {
                switch token {
                case .symbol(";"):
                    advance()
                    return
                case .symbol("{"):
                    try skipBalanced(open: "{", close: "}")
                    if peek() == .symbol(";") { advance() }
                    return
                case .symbol("["):
                    try skipBalanced(open: "[", close: "]")
                default:
                    advance()
                }
            }
            throw ProtoFileParser.error(String(localized: "The file ends in the middle of a statement."))
        }

        private mutating func skipBalanced(open: Character, close: Character) throws {
            var depth = 0
            while let token = peek() {
                advance()
                if token == .symbol(open) { depth += 1 }
                if token == .symbol(close) {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
            throw ProtoFileParser.error(String(localized: "The file ends in the middle of a statement."))
        }

        private mutating func identifier() throws -> String {
            guard case .identifier(let name)? = peek() else { throw unexpected() }
            advance()
            return name
        }

        private mutating func expect(_ symbol: Character) throws {
            guard peek() == .symbol(symbol) else { throw unexpected() }
            advance()
        }

        private func peek(_ offset: Int = 0) -> Token? {
            position + offset < tokens.count ? tokens[position + offset] : nil
        }

        private mutating func advance() {
            position += 1
        }

        private func unexpected() -> ProtobufSchemaError {
            guard let token = peek() else {
                return ProtoFileParser.error(String(localized: "The file ends in the middle of a statement."))
            }
            let text: String
            switch token {
            case .identifier(let value), .number(let value): text = value
            case .string(let value): text = "\"\(value)\""
            case .symbol(let value): text = String(value)
            }
            return ProtoFileParser.error(String(format: String(localized: "Unexpected “%@” in the .proto file."), text))
        }
    }
}
