import Foundation

public enum PostgresArrayElement: Hashable, Sendable {
    case value(String)
    case null
}

public enum PostgresArrayLiteralCodec {
    public static let defaultDelimiter: Character = ","

    public static func parse(_ text: String, delimiter: Character = defaultDelimiter) -> [PostgresArrayElement]? {
        let characters = Array(text)
        var index = 0
        skipWhitespace(characters, &index)
        guard index < characters.count, characters[index] == "{" else { return nil }
        index += 1
        skipWhitespace(characters, &index)

        if index < characters.count, characters[index] == "}" {
            index += 1
            return isExhausted(characters, from: index) ? [] : nil
        }

        var elements: [PostgresArrayElement] = []
        while true {
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] != "{" else { return nil }
            guard let element = parseElement(characters, &index, delimiter: delimiter) else { return nil }
            elements.append(element)
            skipWhitespace(characters, &index)
            guard index < characters.count else { return nil }
            if characters[index] == delimiter {
                index += 1
                continue
            }
            guard characters[index] == "}" else { return nil }
            index += 1
            break
        }
        return isExhausted(characters, from: index) ? elements : nil
    }

    public static func serialize(
        _ elements: [PostgresArrayElement],
        delimiter: Character = defaultDelimiter
    ) -> String {
        let body = elements
            .map { serializeElement($0, delimiter: delimiter) }
            .joined(separator: String(delimiter))
        return "{\(body)}"
    }

    private static func isExhausted(_ characters: [Character], from index: Int) -> Bool {
        var cursor = index
        skipWhitespace(characters, &cursor)
        return cursor == characters.count
    }

    private static func skipWhitespace(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }

    private static func parseElement(
        _ characters: [Character],
        _ index: inout Int,
        delimiter: Character
    ) -> PostgresArrayElement? {
        if characters[index] == "\"" {
            index += 1
            return parseQuotedElement(characters, &index)
        }
        return parseUnquotedElement(characters, &index, delimiter: delimiter)
    }

    private static func parseQuotedElement(
        _ characters: [Character],
        _ index: inout Int
    ) -> PostgresArrayElement? {
        var value: [Character] = []
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else { return nil }
                value.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\"" {
                index += 1
                return .value(String(value))
            }
            value.append(character)
            index += 1
        }
        return nil
    }

    private static func parseUnquotedElement(
        _ characters: [Character],
        _ index: inout Int,
        delimiter: Character
    ) -> PostgresArrayElement? {
        var value: [Character] = []
        var significantCount = 0
        var containsEscape = false
        var startedContent = false

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else { return nil }
                value.append(characters[index + 1])
                containsEscape = true
                startedContent = true
                index += 2
                significantCount = value.count
                continue
            }
            if character == delimiter || character == "}" {
                break
            }
            guard character != "{", character != "\"" else { return nil }
            if !startedContent, character.isWhitespace {
                index += 1
                continue
            }
            startedContent = true
            value.append(character)
            index += 1
            if !character.isWhitespace {
                significantCount = value.count
            }
        }

        guard startedContent else { return nil }
        let text = String(value.prefix(significantCount))
        if !containsEscape, isUnquotedNullKeyword(text) {
            return .null
        }
        return .value(text)
    }

    private static func isUnquotedNullKeyword(_ text: String) -> Bool {
        text.count == 4 && text.lowercased() == "null"
    }

    private static func serializeElement(_ element: PostgresArrayElement, delimiter: Character) -> String {
        switch element {
        case .null:
            return "NULL"
        case .value(let value):
            guard needsQuoting(value, delimiter: delimiter) else { return value }
            var quoted: [Character] = ["\""]
            for character in value {
                if character == "\\" || character == "\"" {
                    quoted.append("\\")
                }
                quoted.append(character)
            }
            quoted.append("\"")
            return String(quoted)
        }
    }

    private static func needsQuoting(_ value: String, delimiter: Character) -> Bool {
        if value.isEmpty { return true }
        if isUnquotedNullKeyword(value) { return true }
        return value.contains { character in
            character == delimiter
                || character == "\""
                || character == "\\"
                || character == "{"
                || character == "}"
                || character.isWhitespace
        }
    }
}
