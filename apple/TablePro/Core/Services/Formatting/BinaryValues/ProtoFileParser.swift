//
//  ProtoFileParser.swift
//  TablePro
//

import Foundation

// https://protobuf.dev/reference/protobuf/proto3-spec/; only options that change how a value reads are kept.
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
            var index = scalars.first == "\u{FEFF}" ? 1 : 0
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
        var enums: [ProtobufEnumDefinition] = []

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func file() throws -> ProtobufFileDefinition {
            var file = ProtobufFileDefinition()
            let package = packageName()
            while let token = peek() {
                switch token {
                case .identifier("syntax"):
                    if peek(1) == .symbol("="), peek(2) == .string("proto3") { file.syntax = .proto3 }
                    try skipStatement()
                case .identifier("edition"):
                    file.syntax = .editions
                    try skipStatement()
                case .identifier("package"):
                    try skipStatement()
                case .identifier("import"):
                    try skipStatement()
                case .identifier("option"):
                    feature(at: position + 1, into: &file.features)
                    try skipStatement()
                case .identifier("message"):
                    advance()
                    file.messages.append(try message(scope: package, depth: 0))
                case .identifier("enum"):
                    advance()
                    file.enums.append(try enumeration(scope: package))
                case .identifier("service"), .identifier("extend"):
                    try skipStatement()
                case .symbol(";"):
                    advance()
                default:
                    throw unexpected()
                }
            }
            file.allMessages = messages
            file.allEnums = enums
            return file
        }

        // It qualifies every definition in the file, those written before it too.
        private func packageName() -> String {
            var depth = 0
            for index in tokens.indices {
                switch tokens[index] {
                case .symbol("{"): depth += 1
                case .symbol("}"): depth -= 1
                case .identifier("package") where depth == 0 && index + 1 < tokens.count:
                    if case .identifier(let name) = tokens[index + 1] { return name }
                default: break
                }
            }
            return ""
        }

        private mutating func message(scope: String, depth: Int) throws -> String {
            let name = try identifier()
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            try expect("{")
            try messageBody(fullName: fullName, depth: depth)
            return fullName
        }

        private mutating func messageBody(fullName: String, depth: Int) throws {
            let slot = messages.count
            messages.append(ProtobufMessageDefinition(fullName: fullName))
            var definition = messages[slot]
            try body(of: &definition, depth: depth, oneof: nil)
            messages[slot] = definition
        }

        private mutating func body(of definition: inout ProtobufMessageDefinition, depth: Int, oneof: Int?) throws {
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
                    definition.nestedMessages.append(try message(scope: definition.fullName, depth: depth + 1))
                case .identifier("enum"):
                    advance()
                    definition.nestedEnums.append(try enumeration(scope: definition.fullName))
                case .identifier("oneof"):
                    advance()
                    _ = try identifier()
                    try expect("{")
                    let index = (definition.fields.compactMap(\.oneofIndex).max() ?? -1) + 1
                    try body(of: &definition, depth: depth + 1, oneof: index)
                // A Schema Registry stores a map field as the entry message protoc synthesizes for it.
                case .identifier("option") where peek(1) == .identifier("map_entry") && peek(3) == .identifier("true"):
                    definition.isMapEntry = true
                    try skipStatement()
                case .identifier("option"):
                    if oneof == nil { feature(at: position + 1, into: &definition.features) }
                    try skipStatement()
                case .identifier("reserved"), .identifier("extensions"), .identifier("extend"):
                    try skipStatement()
                case .identifier("map") where peek(1) == .symbol("<"):
                    advance()
                    try mapField(into: &definition)
                default:
                    try field(into: &definition, depth: depth, oneof: oneof)
                }
            }
        }

        private mutating func field(into definition: inout ProtobufMessageDefinition, depth: Int, oneof: Int?) throws {
            var label: String?
            // `optional foo = 1;` is a field of a message named `optional`: a label needs a type and a name after it.
            if case .identifier(let word)? = peek(), ["optional", "required", "repeated"].contains(word),
               peek(1).map(Self.isIdentifier) == true, peek(2).map(Self.isIdentifier) == true, peek(3) == .symbol("=") {
                label = word
                advance()
            }
            let typeName = try identifier()
            let name = try identifier()
            try expect("=")
            let number = try fieldNumber()
            let features = try fieldOptions()
            let type: ProtobufFieldDefinition.TypeReference
            if typeName == "group" {
                try expect("{")
                let fullName = "\(definition.fullName).\(name)"
                try messageBody(fullName: fullName, depth: depth + 1)
                definition.nestedMessages.append(fullName)
                type = .group(fullName)
            } else {
                try expect(";")
                type = ProtobufScalarType(rawValue: typeName).map { .scalar($0) } ?? .named(typeName)
            }
            var field = ProtobufFieldDefinition(
                name: typeName == "group" ? name.lowercased() : name,
                number: number,
                type: type,
                isRepeated: label == "repeated"
            )
            field.isOptional = label == "optional"
            field.oneofIndex = oneof
            field.features = features
            definition.fields.append(field)
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
            _ = try fieldOptions()
            try expect(";")
            let entryName = "\(definition.fullName).\(Self.camelCased(name))Entry"
            func reference(_ type: String) -> ProtobufFieldDefinition.TypeReference {
                ProtobufScalarType(rawValue: type).map { .scalar($0) } ?? .named(type)
            }
            var entry = ProtobufMessageDefinition(fullName: entryName)
            entry.fields = [
                ProtobufFieldDefinition(name: "key", number: 1, type: reference(keyType), isRepeated: false),
                ProtobufFieldDefinition(name: "value", number: 2, type: reference(valueType), isRepeated: false),
            ]
            entry.isMapEntry = true
            messages.append(entry)
            definition.nestedMessages.append(entryName)
            // The entry sits in the message's scope, so its value type resolves from there.
            definition.fields.append(ProtobufFieldDefinition(name: name, number: number, type: .named(".\(entryName)"), isRepeated: true))
        }

        private mutating func enumeration(scope: String) throws -> String {
            let name = try identifier()
            let fullName = scope.isEmpty ? name : "\(scope).\(name)"
            try expect("{")
            var enumeration = ProtobufEnumDefinition(fullName: fullName)
            while true {
                guard let token = peek() else { throw ProtoFileParser.error(String(localized: "An enum is never closed.")) }
                switch token {
                case .symbol("}"):
                    advance()
                    enums.append(enumeration)
                    return fullName
                case .symbol(";"):
                    advance()
                case .identifier("option"):
                    feature(at: position + 1, into: &enumeration.features)
                    try skipStatement()
                case .identifier("reserved"):
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
                    if enumeration.values[number] == nil { enumeration.values[number] = valueName }
                }
            }
        }

        private static func isIdentifier(_ token: Token) -> Bool {
            if case .identifier = token { return true }
            return false
        }

        // `features.field_presence = IMPLICIT` and `features.enum_type = CLOSED`, as a statement or a field option.
        private func feature(at index: Int, into overrides: inout ProtobufFeatureOverrides) {
            guard index + 2 < tokens.count, case .identifier(let name) = tokens[index], tokens[index + 1] == .symbol("="),
                  case .identifier(let value) = tokens[index + 2] else { return }
            switch (name, value) {
            case ("features.field_presence", "IMPLICIT"): overrides.implicitPresence = true
            case ("features.field_presence", "EXPLICIT"), ("features.field_presence", "LEGACY_REQUIRED"):
                overrides.implicitPresence = false
            case ("features.enum_type", "CLOSED"): overrides.closedEnum = true
            case ("features.enum_type", "OPEN"): overrides.closedEnum = false
            case ("features.utf8_validation", "VERIFY"): overrides.validatesUTF8 = true
            case ("features.utf8_validation", "NONE"): overrides.validatesUTF8 = false
            default: break
            }
        }

        private mutating func fieldOptions() throws -> ProtobufFeatureOverrides {
            var overrides = ProtobufFeatureOverrides()
            let start = position
            try skipOptions()
            var nesting = 0
            for index in start..<position {
                switch tokens[index] {
                case .symbol("{"): nesting += 1
                case .symbol("}"): nesting -= 1
                case .symbol("["), .symbol(","):
                    if nesting == 0 { feature(at: index + 1, into: &overrides) }
                default: break
                }
            }
            return overrides
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

        private mutating func skipOptions() throws {
            guard peek() == .symbol("[") else { return }
            try skipBalanced(open: "[", close: "]")
        }

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
