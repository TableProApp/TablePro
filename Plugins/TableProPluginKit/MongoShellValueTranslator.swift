import Foundation

public enum MongoShellValueError: Error, LocalizedError, Equatable {
    case malformedArguments(helper: String)
    case unterminatedString
    case unterminatedCall(helper: String)

    public var errorDescription: String? {
        switch self {
        case .malformedArguments(let helper):
            return String(format: String(localized: "%@ was given arguments it cannot use."), helper)
        case .unterminatedString:
            return String(localized: "A string literal is missing its closing quote.")
        case .unterminatedCall(let helper):
            return String(format: String(localized: "%@ is missing its closing parenthesis."), helper)
        }
    }
}

/// Rewrites the mongosh value constructors a user can type into the canonical Extended JSON
/// that libbson accepts. Identifiers preceded by a dot are method calls and are left alone,
/// which also makes the pass idempotent.
public enum MongoShellValueTranslator {
    public static func translate(_ input: String) throws -> String {
        guard containsCandidate(input) else { return input }

        var output = ""
        output.reserveCapacity(input.count)
        let characters = Array(input)
        var index = 0
        var previousMeaningful: Character?

        while index < characters.count {
            let character = characters[index]

            if character == "\"" || character == "'" {
                output += try readStringLiteral(characters, from: &index)
                previousMeaningful = "\""
                continue
            }

            if isIdentifierStart(character), previousMeaningful != "." {
                if let translated = try translateCall(characters, from: &index) {
                    output += translated
                    previousMeaningful = ")"
                    continue
                }
            }

            output.append(character)
            if !character.isWhitespace { previousMeaningful = character }
            index += 1
        }

        return output
    }

    // MARK: - Call Translation

    private static func translateCall(_ characters: [Character], from index: inout Int) throws -> String? {
        let start = index
        var cursor = index
        while cursor < characters.count, isIdentifierPart(characters[cursor]) { cursor += 1 }
        let name = String(characters[start ..< cursor])

        var afterName = cursor
        while afterName < characters.count, characters[afterName].isWhitespace { afterName += 1 }

        guard afterName < characters.count, characters[afterName] == "(" else {
            guard let bare = bareConstant(name) else { return nil }
            index = cursor
            return bare
        }
        guard isKnownHelper(name) else { return nil }

        guard let closing = matchingParenthesis(characters, openIndex: afterName) else {
            throw MongoShellValueError.unterminatedCall(helper: name)
        }
        let arguments = try splitArguments(Array(characters[(afterName + 1) ..< closing]))
        guard let json = try extendedJson(helper: name, arguments: arguments) else { return nil }

        index = closing + 1
        return json
    }

    private static func extendedJson(helper: String, arguments: [String]) throws -> String? {
        func malformed() -> MongoShellValueError { .malformedArguments(helper: helper) }

        switch helper {
        case "ObjectId":
            let hex = try singleStringArgument(arguments, helper: helper)
            guard hex.count == 24, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw malformed() }
            return "{\"$oid\": \"\(escaped(hex))\"}"
        case "ISODate", "Date":
            let value = try singleStringArgument(arguments, helper: helper)
            return "{\"$date\": \"\(escaped(value))\"}"
        case "NumberInt":
            let raw = try numericArgument(arguments, helper: helper)
            guard Int32(raw) != nil else { throw malformed() }
            return "{\"$numberInt\": \"\(raw)\"}"
        case "NumberLong":
            let raw = try numericArgument(arguments, helper: helper)
            guard Int64(raw) != nil else { throw malformed() }
            return "{\"$numberLong\": \"\(raw)\"}"
        case "NumberDecimal":
            return "{\"$numberDecimal\": \"\(try numericArgument(arguments, helper: helper))\"}"
        case "Timestamp":
            guard arguments.count == 2,
                  let seconds = UInt32(unwrapped(arguments[0])),
                  let increment = UInt32(unwrapped(arguments[1])) else { throw malformed() }
            return "{\"$timestamp\": {\"t\": \(seconds), \"i\": \(increment)}}"
        case "BinData":
            guard arguments.count == 2, let subtype = UInt8(unwrapped(arguments[0])),
                  let payload = stringLiteralValue(arguments[1]),
                  Data(base64Encoded: payload) != nil else { throw malformed() }
            return MongoDBUuidCodec.extendedJson(
                for: MongoDBBinaryValue(data: Data(base64Encoded: payload) ?? Data(), subtype: subtype)
            )
        case "HexData":
            guard arguments.count == 2, let subtype = UInt8(unwrapped(arguments[0])),
                  let payload = stringLiteralValue(arguments[1]),
                  let data = hexData(payload) else { throw malformed() }
            return MongoDBUuidCodec.extendedJson(for: MongoDBBinaryValue(data: data, subtype: subtype))
        case "MinKey":
            guard arguments.isEmpty else { throw malformed() }
            return "{\"$minKey\": 1}"
        case "MaxKey":
            guard arguments.isEmpty else { throw malformed() }
            return "{\"$maxKey\": 1}"
        default:
            let uuid = try singleStringArgument(arguments, helper: helper)
            guard let binary = MongoDBUuidCodec.parseWrapper("\(helper)(\"\(uuid)\")") else { throw malformed() }
            return MongoDBUuidCodec.extendedJson(for: binary)
        }
    }

    // MARK: - Helper Vocabulary

    private static let valueHelpers: Set<String> = [
        "ObjectId", "ISODate", "Date", "NumberInt", "NumberLong", "NumberDecimal",
        "Timestamp", "BinData", "HexData", "MinKey", "MaxKey",
    ]

    private static let uuidHelpers: Set<String> = [
        "UUID", "LegacyJavaUUID", "LegacyCSharpUUID", "LegacyPythonUUID",
        "JUUID", "CSUUID", "NUUID", "PYUUID", "LUUID",
    ]

    private static func isKnownHelper(_ name: String) -> Bool {
        valueHelpers.contains(name) || uuidHelpers.contains(name)
    }

    private static func bareConstant(_ name: String) -> String? {
        switch name {
        case "MinKey": return "{\"$minKey\": 1}"
        case "MaxKey": return "{\"$maxKey\": 1}"
        default: return nil
        }
    }

    private static func containsCandidate(_ input: String) -> Bool {
        for helper in valueHelpers.union(uuidHelpers) where input.contains(helper) {
            return true
        }
        return false
    }

    // MARK: - Argument Parsing

    private static func singleStringArgument(_ arguments: [String], helper: String) throws -> String {
        guard arguments.count == 1, let value = stringLiteralValue(arguments[0]) else {
            throw MongoShellValueError.malformedArguments(helper: helper)
        }
        return value
    }

    private static func numericArgument(_ arguments: [String], helper: String) throws -> String {
        guard arguments.count == 1 else { throw MongoShellValueError.malformedArguments(helper: helper) }
        let raw = stringLiteralValue(arguments[0]) ?? unwrapped(arguments[0])
        guard isNumericLiteral(raw) else {
            throw MongoShellValueError.malformedArguments(helper: helper)
        }
        return raw
    }

    private static func isNumericLiteral(_ value: String) -> Bool {
        var characters = Array(value)[...]
        if characters.first == "-" || characters.first == "+" { characters = characters.dropFirst() }

        var digits = 0
        while let first = characters.first, first.isNumber, first.isASCII {
            characters = characters.dropFirst()
            digits += 1
        }
        if characters.first == "." {
            characters = characters.dropFirst()
            while let first = characters.first, first.isNumber, first.isASCII {
                characters = characters.dropFirst()
                digits += 1
            }
        }
        guard digits > 0 else { return false }

        if characters.first == "e" || characters.first == "E" {
            characters = characters.dropFirst()
            if characters.first == "-" || characters.first == "+" { characters = characters.dropFirst() }
            var exponentDigits = 0
            while let first = characters.first, first.isNumber, first.isASCII {
                characters = characters.dropFirst()
                exponentDigits += 1
            }
            guard exponentDigits > 0 else { return false }
        }
        return characters.isEmpty
    }

    private static func stringLiteralValue(_ argument: String) -> String? {
        let trimmed = unwrapped(argument)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
              first == last, first == "\"" || first == "'" else { return nil }
        var result = ""
        var isEscaped = false
        for character in trimmed.dropFirst().dropLast() {
            if isEscaped {
                result.append(unescape(character))
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func splitArguments(_ characters: [Character]) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var depth = 0
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" || character == "'" {
                current += try readStringLiteral(characters, from: &index)
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                arguments.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }

        if !unwrapped(current).isEmpty { arguments.append(current) }
        return arguments
    }

    private static func matchingParenthesis(_ characters: [Character], openIndex: Int) -> Int? {
        var depth = 0
        var index = openIndex
        while index < characters.count {
            let character = characters[index]
            if character == "\"" || character == "'" {
                guard (try? readStringLiteral(characters, from: &index)) != nil else { return nil }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func readStringLiteral(_ characters: [Character], from index: inout Int) throws -> String {
        let quote = characters[index]
        var literal = String(quote)
        var cursor = index + 1

        while cursor < characters.count {
            let character = characters[cursor]
            literal.append(character)
            if character == "\\" {
                guard cursor + 1 < characters.count else { throw MongoShellValueError.unterminatedString }
                literal.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            if character == quote {
                index = cursor + 1
                return literal
            }
            cursor += 1
        }
        throw MongoShellValueError.unterminatedString
    }

    // MARK: - Scalars

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static func unwrapped(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return character
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func hexData(_ value: String) -> Data? {
        let characters = Array(value)
        guard !characters.isEmpty, characters.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }
}
