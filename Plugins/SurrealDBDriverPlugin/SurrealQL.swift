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
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\":
                out += "\\\\"
            case "'":
                out += "\\'"
            case "\u{00}":
                continue
            default:
                out.append(character)
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

        let table = unwrap(String(trimmed[trimmed.startIndex..<separator]))
        let rawId = String(trimmed[trimmed.index(after: separator)...])
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
        guard text.count >= 2 else { return false }
        if text.hasPrefix("`"), text.hasSuffix("`") { return true }
        return text.hasPrefix("\u{27E8}") && text.hasSuffix("\u{27E9}")
    }

    private static func separatorIndex(in text: String) -> String.Index? {
        var insideBackticks = false
        var insideAngles = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                insideBackticks.toggle()
            } else if character == "\u{27E8}" {
                insideAngles = true
            } else if character == "\u{27E9}" {
                insideAngles = false
            } else if character == ":", !insideBackticks, !insideAngles {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func unwrap(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            return unescapeBackticks(String(text.dropFirst().dropLast()))
        }
        if text.count >= 2, text.hasPrefix("\u{27E8}"), text.hasSuffix("\u{27E9}") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func escapeBackticks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func unescapeBackticks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\`", with: "`")
            .replacingOccurrences(of: "\\\\", with: "\\")
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
