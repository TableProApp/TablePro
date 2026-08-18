//
//  SQLQueryFingerprint.swift
//  TablePro
//

import CryptoKit
import Foundation

/// Collapses a statement to the shape it was asked in, so `WHERE id = 1` and `WHERE id = 2` count
/// as one query the user ran twice rather than two they ran once.
///
/// The rules follow `pg_stat_statements` and MySQL's statement digest: literals become `?`,
/// comments and whitespace stop mattering, quoted and unquoted spellings of one identifier are the
/// same identifier, and a list of literals collapses to `(...)` so the same lookup with two ids and
/// with five is one shape.
///
/// Identifier case is deliberately preserved. Folding it would merge two genuinely different tables
/// on a case-sensitive server and report a wrong count, while leaving it alone only ever splits a
/// group the user typed inconsistently, which costs a row rather than a number.
enum SQLQueryFingerprint {
    /// A dump replayed through the editor can be a single statement of several hundred kilobytes,
    /// and tokenizing that on every insert would cost more than the query it describes. Two
    /// statements sharing this much prefix are the same shape for counting purposes, which is the
    /// same concession MySQL makes at `max_digest_length`.
    static let maxSourceLength = 20_000

    private static let placeholder = "?"
    private static let collapsedList = "(...)"
    private static let noSpaceBefore: Set<String> = [",", ")", ";", ".", "]", "["]
    private static let noSpaceAfter: Set<String> = ["(", ".", "["]

    /// Tokens after which a `-` or `+` is a sign on the literal rather than an operator between
    /// two operands, so `a = -1` collapses to `a = ?` while `b - 1` stays `b - ?`.
    private static let signPrecedingPunctuation: Set<String> = ["(", ",", ";"]

    /// The readable shape, used to label a group in the UI.
    static func normalize(_ sql: String, databaseType: DatabaseType) -> String {
        let source = strippingDollarQuoted(truncated(sql))
        let treatsDoubleQuoteAsString = Self.treatsDoubleQuoteAsString(databaseType)

        var parts: [String] = []
        var previousWasLiteral = false

        for token in SQLTokenizer().tokenize(source) {
            switch token.type {
            case .comment, .whitespace:
                continue

            case .number, .placeholder:
                appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)

            case .string:
                // The tokenizer classifies every `"…"` as a string, but outside MySQL that is a
                // quoted identifier. Replacing it with `?` erased table and column names and
                // merged unrelated queries into one group.
                if isDoubleQuoted(token.value), !treatsDoubleQuoteAsString {
                    parts.append(unquotedIdentifier(token.value))
                    previousWasLiteral = false
                } else {
                    appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)
                }

            case .keyword:
                // NULL, TRUE and FALSE are literals wearing a keyword's clothes.
                if ["NULL", "TRUE", "FALSE"].contains(token.upperValue) {
                    appendLiteral(to: &parts, previousWasLiteral: &previousWasLiteral)
                } else {
                    parts.append(token.upperValue)
                    previousWasLiteral = false
                }

            case .identifier:
                parts.append(unquotedIdentifier(token.value))
                previousWasLiteral = false

            case .operator:
                appendOperator(token.value, to: &parts)
                previousWasLiteral = false

            case .punctuation:
                parts.append(token.value)
                previousWasLiteral = false
            }
        }

        return join(collapsingLists(mergingBracketIdentifiers(parts)))
    }

    /// The tokenizer has no rule for T-SQL's `[name]`, so it arrives as three tokens and the
    /// identifier never matches its unbracketed spelling. Only a bracket wrapping exactly one
    /// identifier is merged, which leaves a PostgreSQL array subscript (`a[?]`) alone.
    private static func mergingBracketIdentifiers(_ parts: [String]) -> [String] {
        guard parts.contains("[") else { return parts }

        var out: [String] = []
        out.reserveCapacity(parts.count)
        var index = 0

        while index < parts.count {
            if parts[index] == "[", index + 2 < parts.count, parts[index + 2] == "]",
               isPlainIdentifier(parts[index + 1]) {
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

    /// A process-stable digest of `normalize`. `Hasher` is seeded per process, so it can never back
    /// a stored column: the same query would hash differently after a relaunch and every group
    /// would split.
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

    /// MySQL and MariaDB read `"…"` as a string literal unless `ANSI_QUOTES` is set; everyone else
    /// reads it as an identifier. The unknowable case is a MySQL server running `ANSI_QUOTES`, and
    /// guessing wrong there only splits a group, where guessing wrong the other way would merge
    /// two different tables into one row.
    private static func treatsDoubleQuoteAsString(_ databaseType: DatabaseType) -> Bool {
        databaseType == .mysql || databaseType == .mariadb
    }

    private static func appendLiteral(to parts: inout [String], previousWasLiteral: inout Bool) {
        guard !previousWasLiteral else { return }
        parts.append(placeholder)
        previousWasLiteral = true
    }

    /// Drops a sign that belongs to the literal that follows it. The literal is already `?`, so
    /// keeping the sign would leave `= -?` and split it from `= ?`.
    private static func appendOperator(_ value: String, to parts: inout [String]) {
        guard value == "-" || value == "+" else {
            parts.append(value)
            return
        }
        guard let previous = parts.last else { return }
        let startsExpression = signPrecedingPunctuation.contains(previous)
            || isOperatorToken(previous)
            || isBareKeyword(previous)
        if startsExpression {
            return
        }
        parts.append(value)
    }

    private static func isOperatorToken(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.count <= 3 else { return false }
        return "=<>+-*/%&|^~!".unicodeScalars.contains(first)
    }

    private static func isBareKeyword(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isUppercase || $0 == "_" }
    }

    private static func isDoubleQuoted(_ value: String) -> Bool {
        value.hasPrefix("\"")
    }

    /// `users`, `` `users` `` and `"users"` name one table, so they have to reach the same shape.
    /// MySQL's digest does the same unification before it renders the identifier back out.
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

    /// The tokenizer has no dollar-quote rule, so `$$body$$` reaches it as loose identifiers and
    /// the literal survives into the shape. Replacing each one with an empty string literal lets
    /// the tokenizer see the placeholder it would have seen for any other literal.
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

    /// `IN (?, ?)` and `IN (?, ?, ?)` are one lookup asked with different cardinality, and a
    /// multi-row `INSERT … VALUES (?, ?), (?, ?)` is one insert with a different batch size.
    /// Both collapse to MySQL's `(...)` spelling, which a reader of `DIGEST_TEXT` will recognise.
    /// A list holding anything other than literals is left alone, because a subquery or an
    /// expression list is part of the shape rather than its arguments.
    private static func collapsingLists(_ parts: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(parts.count)
        var index = 0

        while index < parts.count {
            let token = parts[index]
            guard token == "IN" || token == "VALUES" else {
                out.append(token)
                index += 1
                continue
            }

            guard let end = literalListEnd(in: parts, startingAfter: index) else {
                out.append(token)
                index += 1
                continue
            }

            out.append(contentsOf: [token, collapsedList])
            index = end + 1
        }
        return out
    }

    /// Walks one or more consecutive parenthesised literal groups and returns the index of the
    /// final `)`, or nil when anything in them is not a literal.
    private static func literalListEnd(in parts: [String], startingAfter keywordIndex: Int) -> Int? {
        var index = keywordIndex + 1
        var lastClosing: Int?

        while index < parts.count, parts[index] == "(" {
            var scan = index + 1
            var sawLiteral = false
            while scan < parts.count, parts[scan] != ")" {
                guard parts[scan] == placeholder || parts[scan] == "," else { return lastClosing }
                if parts[scan] == placeholder { sawLiteral = true }
                scan += 1
            }
            // Truncation can cut the statement inside the list, which leaves no closing paren.
            // The values seen so far are still values, so it collapses rather than surviving as
            // several thousand placeholders.
            guard sawLiteral else { return lastClosing }
            guard scan < parts.count else { return parts.count - 1 }

            lastClosing = scan
            index = scan + 1
            if index < parts.count, parts[index] == "," {
                index += 1
            } else {
                break
            }
        }
        return lastClosing
    }

    private static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if out.isEmpty || noSpaceBefore.contains(part) || noSpaceAfter.contains(String(out.suffix(1))) {
                out += part
            } else {
                out += " " + part
            }
        }
        return out
    }
}
