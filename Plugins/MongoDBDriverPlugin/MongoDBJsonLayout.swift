import Foundation

/// Lays out Extended JSON, and the shell text `MongoDBShellLiteral` writes from it, without parsing
/// it into a dictionary, so every member stays where the server put it.
///
/// A catalog document read through `JSONSerialization` comes back in hash order and was then
/// written out key-sorted, which reordered a `$sort` stage, a compound index key and a validator's
/// `properties`. Each of those orders means something to the server.
enum MongoDBJsonLayout {
    private static let indentUnit = "  "

    /// The members as one Extended JSON object on one line, in the spacing libbson uses for its
    /// own output.
    static func object(_ members: [(key: String, value: String)]) -> String {
        line(members.map { "\(MongoScriptJson.jsonString($0.key)) : \($0.value)" })
    }

    /// The members as one object literal of shell source, every one of them a member of the object
    /// it builds.
    static func shellObject(_ members: [(key: String, value: String)]) -> String {
        line(members.map { "\(MongoDBShellText.memberName($0.key)) : \($0.value)" })
    }

    private static func line(_ body: [String]) -> String {
        body.isEmpty ? "{ }" : "{ \(body.joined(separator: ", ")) }"
    }

    /// The text spread over one line per member and element, nested `depth` levels in, so it can
    /// sit inside a statement that is itself indented. A constructor call such as
    /// `BinData(4, "...")` stays on one line as it was written, and so do `new Date(...)` and a
    /// computed key such as `["__proto__"]`.
    static func indented(_ json: String, depth: Int = 0) -> String {
        let scalars = Array(json.unicodeScalars)
        var output = String.UnicodeScalarView()
        var level = depth
        var callDepth = 0
        var index = 0
        var inString = false
        var escaped = false

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inString {
                output.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            if callDepth > 0 || scalar == "(" {
                output.append(scalar)
                if scalar == "\"" { inString = true }
                if scalar == "(" { callDepth += 1 }
                if scalar == ")" { callDepth -= 1 }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                output.append(scalar)
            case "{", "[":
                if scalar == "[", let closer = computedKeyEnd(scalars, from: index) {
                    output.append(contentsOf: scalars[(index - 1) ... closer])
                    index = closer + 1
                } else if let closer = emptyContainerEnd(scalars, opening: scalar, from: index) {
                    output.append(scalar)
                    output.append(scalars[closer])
                    index = closer + 1
                } else {
                    output.append(scalar)
                    level += 1
                    appendLineBreak(to: &output, level: level)
                }
            case "}", "]":
                level -= 1
                appendLineBreak(to: &output, level: level)
                output.append(scalar)
            case ",":
                output.append(scalar)
                appendLineBreak(to: &output, level: level)
            case ":":
                output.append(contentsOf: ": ".unicodeScalars)
            case " ", "\t", "\n", "\r":
                if let last = output.last, isWordScalar(last), index < scalars.count, isWordScalar(scalars[index]) {
                    output.append(" ")
                }
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    private static func emptyContainerEnd(
        _ scalars: [Unicode.Scalar],
        opening: Unicode.Scalar,
        from start: Int
    ) -> Int? {
        var index = start
        while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) {
            index += 1
        }
        guard index < scalars.count else { return nil }
        let closing: Unicode.Scalar = opening == "{" ? "}" : "]"
        return scalars[index] == closing ? index : nil
    }

    /// The `]` that closes a computed key: one string literal in brackets with a `:` after it,
    /// which a JSON array never is.
    private static func computedKeyEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        guard start < scalars.count, scalars[start] == "\"" else { return nil }
        var index = start + 1
        var escaped = false
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "\"" {
                break
            }
        }
        guard index < scalars.count, scalars[index] == "]" else { return nil }
        let closer = index
        index += 1
        while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) {
            index += 1
        }
        return index < scalars.count && scalars[index] == ":" ? closer : nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar)
    }

    private static func appendLineBreak(to output: inout String.UnicodeScalarView, level: Int) {
        output.append("\n")
        output.append(contentsOf: String(repeating: indentUnit, count: max(0, level)).unicodeScalars)
    }
}
