//
//  SQLLegacyFingerprint.swift
//  TablePro
//

import CryptoKit
import Foundation
import TableProPluginKit
import TableProSQLGrammar

// The query shape as the previous stable reads it, frozen: it fills `fingerprint_hash`, the column that release groups
// history and matches saved plans by. This build groups by `shape_hash`. Delete once no supported release reads it.
enum SQLLegacyFingerprint {
    static let maxSourceLength = 20_000

    private struct Part {
        let text: String
        let isKeyword: Bool

        init(_ text: String, isKeyword: Bool = false) {
            self.text = text
            self.isKeyword = isKeyword
        }
    }

    private static let placeholder = "?"
    private static let collapsedList = "(...)"
    private static let noSpaceBefore: Set<String> = [",", ")", ";", ".", "]", "["]
    private static let noSpaceAfter: Set<String> = ["(", ".", "["]

    private static let signPrecedingPunctuation: Set<String> = ["(", ",", ";"]

    static func normalize(_ sql: String, databaseType: DatabaseType) -> String {
        let source = strippingDollarQuoted(truncated(sql))
        let treatsDoubleQuoteAsString = Self.treatsDoubleQuoteAsString(databaseType)

        var parts: [Part] = []
        var previousWasLiteral = false
        var previousType: SQLTokenType?
        var previousValue = ""

        for token in tokens(source) {
            defer {
                if token.type != .comment, token.type != .whitespace {
                    previousType = token.type
                    previousValue = token.value
                }
            }

            switch token.type {
            case .comment, .whitespace, .directive:
                continue

            case .number, .placeholder:
                appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)

            case .string:
                // The tokenizer classifies every `"…"` as a string, but outside MySQL that is a
                // quoted identifier. Replacing it with `?` erased table and column names and
                // merged unrelated queries into one group.
                if isDoubleQuoted(token.value), !treatsDoubleQuoteAsString {
                    parts.append(Part(unquotedIdentifier(token.value)))
                    previousWasLiteral = false
                } else {
                    appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)
                }

            case .keyword:
                // NULL, TRUE and FALSE are literals wearing a keyword's clothes.
                if ["NULL", "TRUE", "FALSE"].contains(token.upperValue) {
                    appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)
                } else {
                    parts.append(Part(token.upperValue, isKeyword: true))
                    previousWasLiteral = false
                }

            case .identifier:
                parts.append(Part(unquotedIdentifier(token.value)))
                previousWasLiteral = false

            case .operator:
                let isSign = (token.value == "-" || token.value == "+")
                    && signIntroducesLiteral(previousType: previousType, previousValue: previousValue)
                if !isSign {
                    parts.append(Part(token.value))
                }
                previousWasLiteral = false

            case .punctuation:
                parts.append(Part(token.value))
                previousWasLiteral = false
            }
        }

        return join(collapsingLists(mergingBracketIdentifiers(parts)))
    }

    private static func mergingBracketIdentifiers(_ parts: [Part]) -> [Part] {
        guard parts.contains(where: { $0.text == "[" }) else { return parts }

        var out: [Part] = []
        out.reserveCapacity(parts.count)
        var index = 0

        while index < parts.count {
            if parts[index].text == "[", index + 2 < parts.count, parts[index + 2].text == "]",
               isPlainIdentifier(parts[index + 1].text) {
                out.append(parts[index + 1])
                index += 3
                continue
            }
            out.append(parts[index])
            index += 1
        }
        return out
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func hash(_ sql: String, databaseType: DatabaseType) -> Int64 {
        digest(of: normalize(sql, databaseType: databaseType))
    }

    static func digest(of normalized: String) -> Int64 {
        var result: UInt64 = 0
        for byte in SHA256.hash(data: Data(normalized.utf8)).prefix(8) {
            result = (result << 8) | UInt64(byte)
        }
        return Int64(bitPattern: result)
    }

    private static func treatsDoubleQuoteAsString(_ databaseType: DatabaseType) -> Bool {
        SqlDialect.from(databaseTypeId: databaseType.rawValue) == .mysql
    }

    private static func appendLiteral(to parts: inout [Part], previousWasLiteral: inout Bool) {
        guard !previousWasLiteral else { return }
        parts.append(Part(placeholder))
        previousWasLiteral = true
    }

    private static func signIntroducesLiteral(previousType: SQLTokenType?, previousValue: String) -> Bool {
        guard let previousType else { return true }
        switch previousType {
        case .keyword:
            return true
        case .operator:
            // `]` reaches the tokenizer's unknown-character fallback, so it arrives typed as an
            // operator while actually closing a subscript, which makes the next sign binary.
            return previousValue != "]"
        case .punctuation:
            return signPrecedingPunctuation.contains(previousValue)
        case .identifier, .number, .string, .placeholder, .comment, .whitespace, .directive:
            return false
        }
    }

    private static func isDoubleQuoted(_ value: String) -> Bool {
        value.hasPrefix("\"")
    }

    private static func unquotedIdentifier(_ value: String) -> String {
        guard let first = value.first else { return value }
        let closing: Character
        switch first {
        case "`": closing = "`"
        case "\"": closing = "\""
        case "[": closing = "]"
        default: return value
        }
        var inner = value.dropFirst()
        if inner.last == closing {
            inner = inner.dropLast()
        }
        return String(inner)
    }

    private static func truncated(_ sql: String) -> String {
        let source = sql as NSString
        guard source.length > maxSourceLength else { return sql }
        return source.substring(to: maxSourceLength)
    }

    private static func strippingDollarQuoted(_ sql: String) -> String {
        guard sql.contains("$") else { return sql }

        let buffer = sql as NSString
        let length = buffer.length
        var out = ""
        out.reserveCapacity(length)
        var index = 0

        while index < length {
            let character = buffer.character(at: index)
            guard character == SqlDollarQuote.dollar,
                  case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                      at: index,
                      in: buffer,
                      bufLen: length
                  )
            else {
                out += buffer.substring(with: NSRange(location: index, length: 1))
                index += 1
                continue
            }

            var scan = index + openerLength
            while scan < length, !SqlDollarQuote.matchesClose(at: scan, tag: tag, in: buffer, bufLen: length) {
                scan += 1
            }
            out += "''"
            index = scan < length ? scan + (tag as NSString).length + 2 : length
        }
        return out
    }

    private static func collapsingLists(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        out.reserveCapacity(parts.count)
        var index = 0

        while index < parts.count {
            let token = parts[index]
            guard token.isKeyword, token.text == "IN" || token.text == "VALUES" else {
                out.append(token)
                index += 1
                continue
            }

            guard let end = literalListEnd(in: parts, startingAfter: index) else {
                out.append(token)
                index += 1
                continue
            }

            out.append(contentsOf: [token, Part(collapsedList)])
            index = end + 1
        }
        return out
    }

    private static func literalListEnd(in parts: [Part], startingAfter keywordIndex: Int) -> Int? {
        var index = keywordIndex + 1
        var lastClosing: Int?

        while index < parts.count, parts[index].text == "(" {
            var scan = index + 1
            var sawLiteral = false
            while scan < parts.count, parts[scan].text != ")" {
                guard parts[scan].text == placeholder || parts[scan].text == "," else { return lastClosing }
                if parts[scan].text == placeholder { sawLiteral = true }
                scan += 1
            }
            // Truncation can cut the statement inside the list, which leaves no closing paren.
            // The values seen so far are still values, so it collapses rather than surviving as
            // several thousand placeholders.
            guard sawLiteral else { return lastClosing }
            guard scan < parts.count else { return parts.count - 1 }

            lastClosing = scan
            index = scan + 1
            if index < parts.count, parts[index].text == "," {
                index += 1
            } else {
                break
            }
        }
        return lastClosing
    }

    private static let functionKeywords: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX"]

    private static func join(_ parts: [Part]) -> String {
        var out = ""
        var previous: Part?
        for part in parts {
            let bindsToName = part.text == "("
                && previous.map { !$0.isKeyword || functionKeywords.contains($0.text) } == true
            let binds = noSpaceBefore.contains(part.text)
                || noSpaceAfter.contains(String(out.suffix(1)))
                || bindsToName
            if out.isEmpty || binds {
                out += part.text
            } else {
                out += " " + part.text
            }
            previous = part
        }
        return out
    }

    private static let keywords: Set<String> = [
        // DML
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
        "LIKE", "BETWEEN", "EXISTS", "AS", "ON", "USING",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "NATURAL",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
        "UNION", "INTERSECT", "EXCEPT", "ALL", "DISTINCT",
        // CASE
        "CASE", "WHEN", "THEN", "ELSE", "END",
        // DDL
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "ADD", "COLUMN", "CONSTRAINT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "UNIQUE", "CHECK", "DEFAULT", "AUTO_INCREMENT", "IDENTITY",
        "IF", "TEMPORARY", "TEMP", "CASCADE", "RESTRICT",
        // CTE
        "WITH", "RECURSIVE",
        // Data types
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
        "VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR",
        "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "BOOLEAN", "BOOL", "BIT",
        "DATE", "TIME", "TIMESTAMP", "DATETIME", "INTERVAL",
        "BLOB", "CLOB", "BINARY", "VARBINARY",
        "JSON", "JSONB", "XML", "UUID",
        "SERIAL", "BIGSERIAL",
        // Aggregates
        "COUNT", "SUM", "AVG", "MIN", "MAX",
        // Transaction
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
        // Other
        "ASC", "DESC", "NULLS", "FIRST", "LAST",
        "TRUE", "FALSE", "UNKNOWN",
        "OVER", "PARTITION", "WINDOW", "FILTER",
        "RETURNING", "CONFLICT", "DO", "NOTHING",
        "EXPLAIN", "ANALYZE", "TRUNCATE",
        "GRANT", "REVOKE", "DENY",
        "TOP", "PERCENT",
    ]

    private static func tokens(_ sql: String) -> [SQLToken] {
        var tokens: [SQLToken] = []
        let chars = Array(sql)
        let count = chars.count
        var i = 0

        while i < count {
            let ch = chars[i]

            // Line comment: -- ...
            if ch == "-" && i + 1 < count && chars[i + 1] == "-" {
                let start = i
                i += 2
                while i < count && chars[i] != "\n" {
                    i += 1
                }
                tokens.append(SQLToken(type: .comment, value: String(chars[start..<i])))
                continue
            }

            // Block comment: /* ... */
            if ch == "/" && i + 1 < count && chars[i + 1] == "*" {
                let start = i
                i += 2
                while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    i += 1
                }
                if i + 1 < count {
                    i += 2 // skip */
                } else {
                    i = count // unterminated, so the comment runs to the end of the input
                }
                tokens.append(SQLToken(type: .comment, value: String(chars[start..<i])))
                continue
            }

            // String literals: 'single', "double", `backtick`
            if ch == "'" || ch == "\"" || ch == "`" {
                let start = i
                let quote = ch
                i += 1
                while i < count {
                    if chars[i] == "\\" {
                        i = min(i + 2, count) // skip escaped char, or stop at a trailing backslash
                        continue
                    }
                    if chars[i] == quote {
                        // Check for doubled quote escape: '' or ""
                        if i + 1 < count && chars[i + 1] == quote {
                            i += 2
                            continue
                        }
                        i += 1
                        break
                    }
                    i += 1
                }
                let value = String(chars[start..<i])
                // Backtick-quoted identifiers are identifiers, not strings
                let type: SQLTokenType = (quote == "`") ? .identifier : .string
                tokens.append(SQLToken(type: type, value: value))
                continue
            }

            // Whitespace
            if ch.isWhitespace {
                let start = i
                while i < count && chars[i].isWhitespace {
                    i += 1
                }
                tokens.append(SQLToken(type: .whitespace, value: String(chars[start..<i])))
                continue
            }

            // Numbers
            if ch.isNumber || (ch == "." && i + 1 < count && chars[i + 1].isNumber) {
                let start = i
                if ch == "." { i += 1 }
                while i < count && (chars[i].isNumber || chars[i] == ".") {
                    i += 1
                }
                // Scientific notation: 1e10, 1.5E-3
                if i < count && (chars[i] == "e" || chars[i] == "E") {
                    i += 1
                    if i < count && (chars[i] == "+" || chars[i] == "-") {
                        i += 1
                    }
                    while i < count && chars[i].isNumber {
                        i += 1
                    }
                }
                tokens.append(SQLToken(type: .number, value: String(chars[start..<i])))
                continue
            }

            // Placeholders: $1, $name, ?, :name, @name
            if ch == "?" {
                tokens.append(SQLToken(type: .placeholder, value: "?"))
                i += 1
                continue
            }
            if (ch == "$" || ch == ":" || ch == "@") && i + 1 < count && (chars[i + 1].isLetter || chars[i + 1].isNumber || chars[i + 1] == "_") {
                let start = i
                i += 1
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                tokens.append(SQLToken(type: .placeholder, value: String(chars[start..<i])))
                continue
            }

            // Multi-character operators: >=, <=, <>, !=, ||, ::, ->>, ->
            if i + 1 < count {
                let twoChar = String([chars[i], chars[i + 1]])
                if [">=", "<=", "<>", "!=", "||", "::", "->"].contains(twoChar) {
                    if twoChar == "->" && i + 2 < count && chars[i + 2] == ">" {
                        tokens.append(SQLToken(type: .operator, value: "->>"))
                        i += 3
                    } else {
                        tokens.append(SQLToken(type: .operator, value: twoChar))
                        i += 2
                    }
                    continue
                }
            }

            // Single-character operators
            if "=<>+-*/%&|^~!".contains(ch) {
                tokens.append(SQLToken(type: .operator, value: String(ch)))
                i += 1
                continue
            }

            // Punctuation: ( ) , ; .
            if "(),;.".contains(ch) {
                tokens.append(SQLToken(type: .punctuation, value: String(ch)))
                i += 1
                continue
            }

            // Words: keywords or identifiers
            if ch.isLetter || ch == "_" {
                let start = i
                i += 1
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start..<i])
                let isKW = keywords.contains(word.uppercased())
                tokens.append(SQLToken(type: isKW ? .keyword : .identifier, value: word))
                continue
            }

            // Unknown character, treated as an operator
            tokens.append(SQLToken(type: .operator, value: String(ch)))
            i += 1
        }

        return tokens
    }
}
