import Foundation

/// Reading and writing the bridge's JSON without going through `JSONSerialization` for anything
/// whose field order matters.
///
/// Documents cross the bridge as JSON *strings* rather than as nested JSON values, so parsing the
/// request leaves them untouched as text. A document rebuilt from a Swift dictionary comes back
/// with its fields reordered, and BSON field order decides how an embedded document compares, what
/// a compound index matches and where `_id` sits.
enum MongoScriptJson {
    static func success(_ value: String) -> String {
        "{\"ok\":true,\"v\":\(value)}"
    }

    static func failure(message: String, code: UInt32) -> String {
        "{\"ok\":false,\"e\":{\"m\":\(jsonString(message)),\"c\":\(code)}}"
    }

    static func jsonString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for character in value.unicodeScalars {
            switch character {
            case "\"": escaped.append("\\\"")
            case "\\": escaped.append("\\\\")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if character.value < 0x20 {
                    escaped.append(String(format: "\\u%04x", character.value))
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }

    /// Whether this object is an Extended JSON wrapper around a single BSON value.
    ///
    /// `db.users.distinct("_id")` answers with ObjectIds, whose Extended JSON is `{"$oid": …}`.
    /// Reading that as a document renders a `$oid` column instead of one value per row.
    static func isScalarWrapper(_ objectJson: String) -> Bool {
        let members = members(of: objectJson)
        guard let first = members.first, first.key.hasPrefix("$") else { return false }
        if members.count == 1 { return true }
        return members.count == 2 && first.key == "$code" && members[1].key == "$scope"
    }

    /// A document the prelude sent as text, kept verbatim.
    static func rawJson(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func options(_ value: Any?) -> [String: Any] {
        guard let text = rawJson(value), text != "null",
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    /// A numeric field of a command reply, whichever Extended JSON wrapper the server used.
    static func number(in replyJson: String, key: String) -> Int64? {
        guard let data = replyJson.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return numeric(reply[key])
    }

    static func numeric(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return whole(number.doubleValue) }
        guard let wrapper = value as? [String: Any] else { return nil }
        // An integer wrapper is parsed as an integer. Going through `Double` first would round
        // `9223372036854775807` up to 2^63, which is past what `Int64` can hold.
        for key in ["$numberInt", "$numberLong"] {
            if let text = wrapper[key] as? String { return Int64(text) }
        }
        if let text = wrapper["$numberDouble"] as? String, let parsed = Double(text) {
            return whole(parsed)
        }
        return nil
    }

    /// A double as a whole number, or nil when it is not exactly one.
    ///
    /// `Int64(Double.nan)` traps, and so does a value past `Int64`'s range, where the obvious bound
    /// check does not help: `Double(Int64.max)` rounds *up* to 2^63, so an inclusive comparison
    /// against it still admits a value that traps. `Int64(exactly:)` is the check that holds, and it
    /// also refuses `1.5` rather than silently truncating a whole-number argument.
    static func whole(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        return Int64(exactly: value.rounded(.towardZero)) == Int64(exactly: value)
            ? Int64(exactly: value)
            : nil
    }

    /// One member of a JSON object, returned as the text it occupies rather than as a rebuilt value.
    static func member(of objectJson: String, key: String) -> String? {
        members(of: objectJson).first { $0.key == key }?.value
    }

    /// Every member of a JSON object, in the order the document carries them, each value as text.
    ///
    /// The text is walked scalar by scalar, never by `Character`: a Unicode Prepend character joins
    /// the `"` or `\` after it into one grapheme cluster, and a scan by cluster then misses the end
    /// of a string that libbson escaped correctly.
    static func members(of objectJson: String) -> [(key: String, value: String)] {
        let scalars = Array(objectJson.unicodeScalars)
        guard let start = scalars.firstIndex(of: "{") else { return [] }
        var index = start + 1
        var pairs: [(key: String, value: String)] = []

        while index < scalars.count {
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] == "\"" else { return pairs }
            guard let name = readString(scalars, &index) else { return pairs }
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] == ":" else { return pairs }
            index += 1
            skipWhitespace(scalars, &index)
            let valueStart = index
            skipValue(scalars, &index)
            pairs.append((name, text(scalars[valueStart ..< index])))
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] == "," else { return pairs }
            index += 1
        }
        return pairs
    }

    /// The elements of a JSON array, each as its own text.
    static func topLevelElements(_ arrayJson: String) -> [String] {
        let scalars = Array(arrayJson.unicodeScalars)
        guard let start = scalars.firstIndex(of: "[") else { return [] }
        var index = start + 1
        var elements: [String] = []

        while index < scalars.count {
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] != "]" else { break }
            let elementStart = index
            skipValue(scalars, &index)
            elements.append(text(scalars[elementStart ..< index]))
            skipWhitespace(scalars, &index)
            guard index < scalars.count, scalars[index] == "," else { break }
            index += 1
        }
        return elements
    }

    // MARK: - Scanning

    private static func text(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view).trimmingCharacters(in: .whitespaces)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private static func skipWhitespace(_ scalars: [Unicode.Scalar], _ index: inout Int) {
        while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
    }

    private static func readString(_ scalars: [Unicode.Scalar], _ index: inout Int) -> String? {
        guard index < scalars.count, scalars[index] == "\"" else { return nil }
        index += 1
        var value = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\"":
                return String(value)
            case "\\":
                guard let decoded = readEscape(scalars, &index) else { return nil }
                value.append(decoded)
            default:
                value.append(scalar)
            }
        }
        return nil
    }

    private static func readEscape(_ scalars: [Unicode.Scalar], _ index: inout Int) -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        let escape = scalars[index]
        index += 1
        switch escape {
        case "\"", "\\", "/": return escape
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u": return readUnicodeEscape(scalars, &index)
        default: return nil
        }
    }

    private static func readUnicodeEscape(_ scalars: [Unicode.Scalar], _ index: inout Int) -> Unicode.Scalar? {
        guard let unit = readHexUnit(scalars, &index) else { return nil }
        guard (0xD800 ... 0xDBFF).contains(unit) else { return Unicode.Scalar(unit) }
        guard index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else { return nil }
        index += 2
        guard let low = readHexUnit(scalars, &index), (0xDC00 ... 0xDFFF).contains(low) else { return nil }
        return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
    }

    private static func readHexUnit(_ scalars: [Unicode.Scalar], _ index: inout Int) -> UInt32? {
        guard index + 4 <= scalars.count else { return nil }
        var digits = String.UnicodeScalarView()
        digits.append(contentsOf: scalars[index ..< index + 4])
        guard let unit = UInt32(String(digits), radix: 16) else { return nil }
        index += 4
        return unit
    }

    private static func skipValue(_ scalars: [Unicode.Scalar], _ index: inout Int) {
        var depth = 0
        var inString = false
        var escaped = false

        while index < scalars.count {
            let scalar = scalars[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if inString {
                if scalar == "\\" { escaped = true }
                if scalar == "\"" { inString = false }
                index += 1
                continue
            }
            switch scalar {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
            case "}", "]":
                if depth == 0 { return }
                depth -= 1
            case ",":
                if depth == 0 { return }
            default:
                break
            }
            index += 1
            if depth == 0, scalar == "}" || scalar == "]" { return }
        }
    }
}
