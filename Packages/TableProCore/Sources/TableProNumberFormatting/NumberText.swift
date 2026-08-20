import Foundation

public enum NumberText {
    public static func text(for value: Double) -> String {
        withoutTrailingPointZero(value.description)
    }

    public static func text(for value: Float) -> String {
        withoutTrailingPointZero(value.description)
    }

    public static func text(for number: NSNumber) -> String {
        guard !(number is NSDecimalNumber) else { return number.stringValue }
        switch String(cString: number.objCType) {
        case "f":
            return text(for: number.floatValue)
        case "d":
            return text(for: number.doubleValue)
        default:
            return number.stringValue
        }
    }

    public static func json(
        from value: Any,
        sortedKeys: Bool = true,
        prettyPrinted: Bool = false,
        preservesFloatingPointForm: Bool = false
    ) -> String? {
        var writer = JSONWriter(
            sortedKeys: sortedKeys,
            prettyPrinted: prettyPrinted,
            preservesFloatingPointForm: preservesFloatingPointForm
        )
        guard writer.append(value, depth: 0) else { return nil }
        return writer.output
    }

    /// Digits that are already a JSON number and must be written through verbatim, at whatever
    /// precision they carry. `Decimal` cannot hold every decimal128 value: measured, it turns
    /// "NaN" and "1E+400" into NaN, "-Infinity" into 0, and "0.100" into "0.1".
    public struct RawNumber: Sendable, Hashable {
        public let text: String

        public init?(_ text: String) {
            guard NumberText.isJSONNumberLiteral(text) else { return nil }
            self.text = text
        }
    }

    /// The JSON number grammar with no width limit, for values carried as text.
    public static func isJSONNumberLiteral(_ text: String) -> Bool {
        guard let match = jsonNumberRegex?.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        ) else {
            return false
        }
        return match.range.length == (text as NSString).length
    }

    /// The JSON number grammar, restricted to values a bare JSON number can carry without loss.
    public static func isJSONNumber(_ text: String) -> Bool {
        guard let match = jsonNumberRegex?.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        ), match.range.length == (text as NSString).length else {
            return false
        }
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            return Int64(text) != nil
        }
        return Double(text)?.isFinite ?? false
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static let jsonNumberRegex = try? NSRegularExpression(
        pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
    )

    private static func withoutTrailingPointZero(_ description: String) -> String {
        description.hasSuffix(".0") ? String(description.dropLast(2)) : description
    }
}

public enum JSONTruncation {
    static let marker = "..."

    public static func truncate(_ json: String, maxLength: Int) -> String {
        let nsJson = json as NSString
        guard nsJson.length > maxLength else { return json }
        let boundary = nsJson.rangeOfComposedCharacterSequence(at: maxLength)
        let cut = boundary.location < maxLength ? boundary.location : maxLength
        return nsJson.substring(to: cut) + marker
    }

    /// A structure whose text was cut short no longer closes, so it is no longer the value it
    /// came from. Callers that write or export must refuse it rather than store the fragment.
    public static func isIncompleteStructure(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        guard text.hasSuffix(marker) else { return false }
        return !(text.hasSuffix("}" + marker) || text.hasSuffix("]" + marker))
    }
}

private struct JSONWriter {
    let sortedKeys: Bool
    let prettyPrinted: Bool
    let preservesFloatingPointForm: Bool
    var output = ""

    mutating func append(_ value: Any, depth: Int) -> Bool {
        switch value {
        case is NSNull:
            output += "null"
            return true
        case let string as String:
            appendString(string)
            return true
        case let raw as NumberText.RawNumber:
            output += raw.text
            return true
        case let number as NSNumber:
            return appendNumber(number)
        case let array as [Any]:
            return appendArray(array, depth: depth)
        case let dictionary as [String: Any]:
            return appendObject(dictionary, depth: depth)
        default:
            return false
        }
    }

    private mutating func appendNumber(_ number: NSNumber) -> Bool {
        if NumberText.isBoolean(number) {
            output += number.boolValue ? "true" : "false"
            return true
        }
        if number is NSDecimalNumber {
            output += number.stringValue
            return true
        }
        switch String(cString: number.objCType) {
        case "f":
            guard number.floatValue.isFinite else { return false }
            output += floatingPointText(NumberText.text(for: number.floatValue))
        case "d":
            guard number.doubleValue.isFinite else { return false }
            output += floatingPointText(NumberText.text(for: number.doubleValue))
        default:
            output += number.stringValue
        }
        return true
    }

    /// A JSON number without a fractional part or exponent reads back as an integer, so a value
    /// that was floating point loses that on any round trip through the text.
    private func floatingPointText(_ text: String) -> String {
        guard preservesFloatingPointForm else { return text }
        let hasFractionOrExponent = text.contains(".") || text.contains("e") || text.contains("E")
        return hasFractionOrExponent ? text : text + ".0"
    }

    private mutating func appendArray(_ array: [Any], depth: Int) -> Bool {
        guard !array.isEmpty else {
            output += "[]"
            return true
        }
        output += "["
        for (index, element) in array.enumerated() {
            if index > 0 { output += "," }
            appendNewlineAndIndent(depth: depth + 1)
            guard append(element, depth: depth + 1) else { return false }
        }
        appendNewlineAndIndent(depth: depth)
        output += "]"
        return true
    }

    private mutating func appendObject(_ dictionary: [String: Any], depth: Int) -> Bool {
        guard !dictionary.isEmpty else {
            output += "{}"
            return true
        }
        output += "{"
        let keys = sortedKeys ? dictionary.keys.sorted() : Array(dictionary.keys)
        for (index, key) in keys.enumerated() {
            if index > 0 { output += "," }
            appendNewlineAndIndent(depth: depth + 1)
            appendString(key)
            output += prettyPrinted ? " : " : ":"
            guard let element = dictionary[key], append(element, depth: depth + 1) else { return false }
        }
        appendNewlineAndIndent(depth: depth)
        output += "}"
        return true
    }

    private mutating func appendNewlineAndIndent(depth: Int) {
        guard prettyPrinted else { return }
        output += "\n"
        output += String(repeating: "  ", count: depth)
    }

    private mutating func appendString(_ string: String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "/": output += "\\/"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
