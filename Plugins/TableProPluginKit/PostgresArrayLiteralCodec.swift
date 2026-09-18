import Foundation

public enum PostgresArrayElement: Hashable, Sendable {
    case value(String)
    case null
}

/// Reads and writes the literal PostgreSQL's `array_in` and `array_out` use.
///
/// It scans Unicode scalars rather than `Character`s because that is what the server does. A Swift
/// grapheme can carry a structural scalar and a combining mark together, and `Character`
/// comparison then misses it: `,` followed by U+0301 is one `Character` that is not `","`, so a
/// grapheme scan would keep an element the server splits in two, and a space followed by U+0301 is
/// one `Character` that is not whitespace, so it would go out unquoted for the server to trim.
public enum PostgresArrayLiteralCodec {
    public static let defaultDelimiter: Character = ","

    /// The scalars PostgreSQL's array parser treats as whitespace, its `scanner_isspace`.
    ///
    /// `Character.isWhitespace` is the whole Unicode set instead, which is wrong in both
    /// directions. Measured on PostgreSQL 17.11: `array_out` writes U+00A0 and U+3000 into a
    /// literal unquoted and `array_in` reads them back as part of the value, so trimming them here
    /// deleted a character from an element the user never edited.
    private static let separators: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]

    public static func parse(_ text: String, delimiter: Character = defaultDelimiter) -> [PostgresArrayElement]? {
        guard let delimiter = delimiter.unicodeScalars.first else { return nil }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        skipWhitespace(scalars, &index)
        guard index < scalars.count, scalars[index] == "{" else { return nil }
        index += 1
        skipWhitespace(scalars, &index)

        if index < scalars.count, scalars[index] == "}" {
            index += 1
            return isExhausted(scalars, from: index) ? [] : nil
        }

        var elements: [PostgresArrayElement] = []
        while true {
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] != "{" else { return nil }
            guard let element = parseElement(scalars, &index, delimiter: delimiter) else { return nil }
            elements.append(element)
            skipWhitespace(scalars, &index)
            guard index < scalars.count else { return nil }
            if scalars[index] == delimiter {
                index += 1
                continue
            }
            guard scalars[index] == "}" else { return nil }
            index += 1
            break
        }
        return isExhausted(scalars, from: index) ? elements : nil
    }

    public static func serialize(
        _ elements: [PostgresArrayElement],
        delimiter: Character = defaultDelimiter
    ) -> String {
        let scalar = delimiter.unicodeScalars.first ?? ","
        let body = elements
            .map { serializeElement($0, delimiter: scalar) }
            .joined(separator: String(Unicode.Scalar(scalar)))
        return "{\(body)}"
    }

    private static func text(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func isExhausted(_ scalars: [Unicode.Scalar], from index: Int) -> Bool {
        var cursor = index
        skipWhitespace(scalars, &cursor)
        return cursor == scalars.count
    }

    private static func skipWhitespace(_ scalars: [Unicode.Scalar], _ index: inout Int) {
        while index < scalars.count, separators.contains(scalars[index]) {
            index += 1
        }
    }

    private static func parseElement(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int,
        delimiter: Unicode.Scalar
    ) -> PostgresArrayElement? {
        if scalars[index] == "\"" {
            index += 1
            return parseQuotedElement(scalars, &index)
        }
        return parseUnquotedElement(scalars, &index, delimiter: delimiter)
    }

    private static func parseQuotedElement(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int
    ) -> PostgresArrayElement? {
        var value: [Unicode.Scalar] = []
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return nil }
                value.append(scalars[index + 1])
                index += 2
                continue
            }
            if scalar == "\"" {
                index += 1
                return .value(text(value))
            }
            value.append(scalar)
            index += 1
        }
        return nil
    }

    private static func parseUnquotedElement(
        _ scalars: [Unicode.Scalar],
        _ index: inout Int,
        delimiter: Unicode.Scalar
    ) -> PostgresArrayElement? {
        var value: [Unicode.Scalar] = []
        var significantCount = 0
        var containsEscape = false
        var startedContent = false

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return nil }
                value.append(scalars[index + 1])
                containsEscape = true
                startedContent = true
                index += 2
                significantCount = value.count
                continue
            }
            if scalar == delimiter || scalar == "}" {
                break
            }
            guard scalar != "{", scalar != "\"" else { return nil }
            if !startedContent, separators.contains(scalar) {
                index += 1
                continue
            }
            startedContent = true
            value.append(scalar)
            index += 1
            if !separators.contains(scalar) {
                significantCount = value.count
            }
        }

        guard startedContent else { return nil }
        let parsed = text(value.prefix(significantCount))
        if !containsEscape, isUnquotedNullKeyword(parsed) {
            return .null
        }
        return .value(parsed)
    }

    private static func isUnquotedNullKeyword(_ value: String) -> Bool {
        value.lowercased() == "null"
    }

    private static func serializeElement(_ element: PostgresArrayElement, delimiter: Unicode.Scalar) -> String {
        switch element {
        case .null:
            return "NULL"
        case .value(let value):
            guard needsQuoting(value, delimiter: delimiter) else { return value }
            var quoted: [Unicode.Scalar] = ["\""]
            for scalar in value.unicodeScalars {
                if scalar == "\\" || scalar == "\"" {
                    quoted.append("\\")
                }
                quoted.append(scalar)
            }
            quoted.append("\"")
            return text(quoted)
        }
    }

    private static func needsQuoting(_ value: String, delimiter: Unicode.Scalar) -> Bool {
        if value.isEmpty { return true }
        if isUnquotedNullKeyword(value) { return true }
        return value.unicodeScalars.contains { scalar in
            scalar == delimiter
                || scalar == "\""
                || scalar == "\\"
                || scalar == "{"
                || scalar == "}"
                || separators.contains(scalar)
        }
    }
}
