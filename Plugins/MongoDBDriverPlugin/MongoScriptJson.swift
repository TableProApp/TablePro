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
    static func members(of objectJson: String) -> [(key: String, value: String)] {
        let characters = Array(objectJson)
        guard let start = characters.firstIndex(of: "{") else { return [] }
        var index = start + 1
        var pairs: [(key: String, value: String)] = []

        while index < characters.count {
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] == "\"" else { return pairs }
            guard let name = readString(characters, &index) else { return pairs }
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] == ":" else { return pairs }
            index += 1
            skipWhitespace(characters, &index)
            let valueStart = index
            skipValue(characters, &index)
            pairs.append((name, String(characters[valueStart ..< index]).trimmingCharacters(in: .whitespaces)))
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] == "," else { return pairs }
            index += 1
        }
        return pairs
    }

    /// The elements of a JSON array, each as its own text.
    static func topLevelElements(_ arrayJson: String) -> [String] {
        let characters = Array(arrayJson)
        guard let start = characters.firstIndex(of: "[") else { return [] }
        var index = start + 1
        var elements: [String] = []

        while index < characters.count {
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] != "]" else { break }
            let elementStart = index
            skipValue(characters, &index)
            elements.append(String(characters[elementStart ..< index]).trimmingCharacters(in: .whitespaces))
            skipWhitespace(characters, &index)
            guard index < characters.count, characters[index] == "," else { break }
            index += 1
        }
        return elements
    }

    // MARK: - Scanning

    private static func skipWhitespace(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    private static func readString(_ characters: [Character], _ index: inout Int) -> String? {
        guard index < characters.count, characters[index] == "\"" else { return nil }
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            index += 1
            if character == "\"" { return value }
            value.append(character)
        }
        return nil
    }

    private static func skipValue(_ characters: [Character], _ index: inout Int) {
        var depth = 0
        var inString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if inString {
                if character == "\\" { escaped = true }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
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
            if depth == 0, character == "}" || character == "]" { return }
        }
    }
}
