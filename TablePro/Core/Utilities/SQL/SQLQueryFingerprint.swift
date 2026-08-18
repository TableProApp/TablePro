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

    /// Text plus the one fact the later passes need about it. Spacing used to re-derive "is this a
    /// keyword" from the spelling, which is the same mistake that made `TOTAL - 1` collapse.
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

    /// Tokens after which a `-` or `+` is a sign on the literal rather than an operator between
    /// two operands, so `a = -1` collapses to `a = ?` while `b - 1` stays `b - ?`.
    private static let signPrecedingPunctuation: Set<String> = ["(", ",", ";"]

    /// The readable shape, used to label a group in the UI.
    static func normalize(_ sql: String, databaseType: DatabaseType) -> String {
        let source = strippingDollarQuoted(truncated(sql))
        let treatsDoubleQuoteAsString = Self.treatsDoubleQuoteAsString(databaseType)

        var parts: [Part] = []
        var previousWasLiteral = false
        var previousType: SQLTokenType?
        var previousValue = ""

        for token in SQLTokenizer().tokenize(source) {
            defer {
                if token.type != .comment, token.type != .whitespace {
                    previousType = token.type
                    previousValue = token.value
                }
            }

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

    /// The tokenizer has no rule for T-SQL's `[name]`, so it arrives as three tokens and the
    /// identifier never matches its unbracketed spelling. Only a bracket wrapping exactly one
    /// identifier is merged, which leaves a PostgreSQL array subscript (`a[?]`) alone.
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

    private static func appendLiteral(to parts: inout [Part], previousWasLiteral: inout Bool) {
        guard !previousWasLiteral else { return }
        parts.append(Part(placeholder))
        previousWasLiteral = true
    }

    /// Whether a `-` or `+` is the sign on the literal that follows rather than an operator between
    /// two operands. The literal is already `?`, so a sign left in place leaves `= -?` and splits it
    /// from `= ?`.
    ///
    /// This reads the preceding token's *type*, never its text. Deciding from the emitted string
    /// treated any all-uppercase token as a keyword, and identifier case is deliberately preserved,
    /// so `SELECT TOTAL - 1` and `SELECT TOTAL + 1` both collapsed to `SELECT TOTAL ?`: two
    /// different statements counted as one shape, spelled as arithmetic in neither of them.
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
        case .identifier, .number, .string, .placeholder, .comment, .whitespace:
            return false
        }
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

    /// Walks one or more consecutive parenthesised literal groups and returns the index of the
    /// final `)`, or nil when anything in them is not a literal.
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

    /// The tokenizer classifies aggregate names as keywords, so "is this a function call" cannot be
    /// answered by keyword-ness alone. These are the ones that take a parenthesised argument list
    /// and therefore bind to it, the way an identifier does.
    private static let functionKeywords: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX"]

    /// A `(` binds to the name in front of it, so a call reads `COUNT(*)` rather than `COUNT (*)`,
    /// while a clause keyword keeps its space and `IN (...)` reads the way MySQL spells the same
    /// shape in `DIGEST_TEXT`.
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
}
