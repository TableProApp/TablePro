//
//  SurrealQL.swift
//  SurrealDBDriverPlugin
//

import Foundation

public enum SurrealQL {
    public static func quoteIdentifier(_ name: String) -> String {
        guard needsQuoting(name) else { return name }
        return "`" + escapeBackticks(name) + "`"
    }

    public static func escapeStringLiteral(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "'":
                out += "\\'"
            case "\u{00}":
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func stringLiteral(_ value: String) -> String {
        "'" + escapeStringLiteral(value) + "'"
    }

    public static func recordIdPart(_ id: SurrealValue) -> String {
        switch id {
        case let .int(number):
            return String(number)
        case let .string(text):
            return isSimpleIdentifier(text) ? text : "`" + escapeBackticks(text) + "`"
        case let .uuid(value):
            return "`" + value.uuidString.lowercased() + "`"
        default:
            return "`" + escapeBackticks(id.displayText) + "`"
        }
    }

    // `recordIdPart` backticks a uuid, an array and an object id like a string that needs quoting, so a backticked
    // string is that string only when it cannot read as one of them.
    public static func isRecoverableFromText(_ id: SurrealValue) -> Bool {
        switch id {
        case .int:
            return true
        case let .string(text):
            if isSimpleIdentifier(text) { return true }
            guard UUID(uuidString: text) == nil, let first = text.unicodeScalars.first else { return false }
            return first != "[" && first != "{"
        default:
            return false
        }
    }

    public static func recordLiteral(_ record: SurrealRecordID) -> String {
        quoteIdentifier(record.table) + ":" + recordIdPart(record.id)
    }

    public static func parseRecordId(_ text: String, fallbackTable: String? = nil) -> SurrealRecordID? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        guard let separator = separatorIndex(in: trimmed) else {
            guard let table = fallbackTable else { return nil }
            return SurrealRecordID(table: table, id: idValue(fromRaw: trimmed))
        }

        let scalars = trimmed.unicodeScalars
        let table = unwrap(String(scalars[..<separator]))
        let rawId = String(scalars[scalars.index(after: separator)...])
        guard !table.isEmpty, !rawId.isEmpty else { return nil }
        return SurrealRecordID(table: table, id: idValue(fromRaw: rawId))
    }

    // MARK: - Helpers

    private static func idValue(fromRaw text: String) -> SurrealValue {
        guard !isQuoted(text) else { return .string(unwrap(text)) }
        if let number = Int64(text), String(number) == text {
            return .int(number)
        }
        return .string(text)
    }

    private static func isQuoted(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count >= 2, let first = scalars.first, let last = scalars.last else { return false }
        return (first == "`" && last == "`") || (first == "\u{27E8}" && last == "\u{27E9}")
    }

    // A backslash inside backticks escapes the next scalar, as `escapeBackticks` writes it.
    private static func separatorIndex(in text: String) -> String.Index? {
        var insideBackticks = false
        var insideAngles = false
        var escaping = false
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if escaping {
                escaping = false
            } else if insideBackticks, scalar == "\\" {
                escaping = true
            } else if scalar == "`" {
                insideBackticks.toggle()
            } else if scalar == "\u{27E8}" {
                insideAngles = true
            } else if scalar == "\u{27E9}" {
                insideAngles = false
            } else if scalar == ":", !insideBackticks, !insideAngles {
                return index
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func unwrap(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count >= 2, let first = scalars.first, let last = scalars.last else { return text }
        let inner = String(String.UnicodeScalarView(scalars.dropFirst().dropLast()))
        if first == "`", last == "`" { return unescapeBackticks(inner) }
        if first == "\u{27E8}", last == "\u{27E9}" { return inner }
        return text
    }

    private static func escapeBackticks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "`", with: "\\`", options: .literal)
    }

    // The inverse of `escapeBackticks`, in one pass: two replacements in turn misread `\\` before a backtick.
    private static func unescapeBackticks(_ text: String) -> String {
        var unescaped = String.UnicodeScalarView()
        var escaping = false
        for scalar in text.unicodeScalars {
            if !escaping, scalar == "\\" {
                escaping = true
                continue
            }
            escaping = false
            unescaped.append(scalar)
        }
        return String(unescaped)
    }

    private static func isSimpleIdentifier(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func needsQuoting(_ name: String) -> Bool {
        !isSimpleIdentifier(name) || reservedWords.contains(name.uppercased())
    }

    private static let reservedWords: Set<String> = [
        "SELECT", "FROM", "WHERE", "CREATE", "UPDATE", "UPSERT", "DELETE", "RELATE", "INSERT",
        "DEFINE", "REMOVE", "ALTER", "INFO", "USE", "LET", "RETURN", "BEGIN", "COMMIT", "CANCEL",
        "TABLE", "FIELD", "INDEX", "NAMESPACE", "DATABASE", "USER", "ACCESS", "EVENT", "PARAM",
        "AND", "OR", "NOT", "IN", "CONTAINS", "INSIDE", "OUTSIDE", "INTERSECTS",
        "ORDER", "GROUP", "LIMIT", "START", "FETCH", "SPLIT", "WITH", "EXPLAIN", "TIMEOUT",
        "NONE", "NULL", "TRUE", "FALSE", "SET", "CONTENT", "MERGE", "PATCH", "LIVE", "KILL"
    ]
}
