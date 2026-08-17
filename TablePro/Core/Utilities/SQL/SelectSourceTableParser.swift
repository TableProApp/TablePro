//
//  SelectSourceTableParser.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Resolves the one table a `SELECT` reads from, or nothing.
///
/// The result decides whether a result grid is editable, and it becomes the target of the
/// generated `UPDATE` and `DELETE`. A wrong name would write to the wrong table, so every
/// shape this cannot prove is single-source resolves to `nil` and leaves the grid read-only:
/// joins, comma lists, derived tables, CTEs, and set operators.
///
/// A `schema.table` reference resolves to both parts. Deciding whether that schema is safe to
/// write through belongs to the caller, not here.
enum SelectSourceTableParser {
    struct SourceTable: Equatable {
        /// Present only when the statement spelled a qualified reference.
        let schema: String?
        let name: String
    }

    /// Keywords that may legally follow the single table reference. Anything else means the
    /// statement reads from more than the one table, so the whitelist is the safety property.
    private static let clauseTerminators: Set<String> = [
        "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR", "WINDOW", "QUALIFY",
    ]

    private static let nonAliasKeywords: Set<String> = clauseTerminators.union([
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "STRAIGHT_JOIN",
        "ON", "USING", "UNION", "INTERSECT", "EXCEPT", "MINUS",
        "AS", "SELECT", "FROM", "INTO", "SET", "RETURNING", "VALUES", "WITH",
        "TABLESAMPLE", "LATERAL", "PARTITION", "PIVOT", "UNPIVOT",
        "USE", "IGNORE", "FORCE", "ONLY", "WITHIN", "START", "CONNECT", "SAMPLE",
    ])

    /// `FOR UPDATE` and its relatives lock rows of the same table, so the read stays single-source.
    /// `FOR SYSTEM_TIME` returns historical row versions and `FOR JSON`/`FOR XML` return a synthetic
    /// column, so neither describes rows that can be written back.
    private static let rowLockingModifiers: Set<String> = ["UPDATE", "SHARE", "NO", "KEY", "READ"]

    static func singleSourceTable(in sql: String, dialect: SqlDialect) -> SourceTable? {
        var cursor = Cursor(sql, dialect: dialect)
        guard cursor.consumeKeyword("SELECT") else { return nil }
        guard cursor.advanceToTopLevelFrom() else { return nil }
        guard let table = cursor.consumeTableReference() else { return nil }
        guard cursor.consumeOptionalAlias() else { return nil }
        guard cursor.atClauseBoundary() else { return nil }
        guard !cursor.hasTopLevelSetOperator() else { return nil }
        return table
    }

    private struct Cursor {
        /// Scanning reads one code unit at a time. `NSString.character(at:)` leaves its fast path
        /// as soon as the bridged string is not ASCII, so a single accented character anywhere in
        /// the text made every later read transcode and turned a 4 ms scan of a wide select list
        /// into 33 ms on the main actor. Transcoding once up front keeps every read a subscript.
        /// The `NSString` stays only for `SqlDollarQuote`, which takes one.
        private let text: NSString
        private let units: [UInt16]
        private let length: Int
        private let dialect: SqlDialect
        private var index = 0
        private(set) var didAbortLexing = false

        init(_ sql: String, dialect: SqlDialect) {
            text = sql as NSString
            units = Array(sql.utf16)
            length = units.count
            self.dialect = dialect
        }

        private func unit(at position: Int) -> UInt16? {
            position < length ? units[position] : nil
        }

        private static func isSpace(_ ch: UInt16) -> Bool {
            ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C
        }

        /// Treats every non-ASCII code unit as an identifier character, which keeps unquoted
        /// non-Latin table names intact without decoding surrogate pairs.
        private static func isIdentifierUnit(_ ch: UInt16) -> Bool {
            (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
                || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F || ch == 0x24 || ch >= 0x80
        }

        private static func closingDelimiter(for opener: UInt16) -> UInt16? {
            switch opener {
            case 0x22: return 0x22
            case 0x60: return 0x60
            case 0x5B: return 0x5D
            default: return nil
            }
        }

        private mutating func skipTrivia() {
            while index < length {
                let ch = units[index]
                if Self.isSpace(ch) {
                    index += 1
                } else if ch == 0x2D, unit(at: index + 1) == 0x2D {
                    index += 2
                    skipToEndOfLine()
                } else if ch == 0x23, dialect.supportsHashLineComments {
                    index += 1
                    skipToEndOfLine()
                } else if ch == 0x2F, unit(at: index + 1) == 0x2A {
                    skipBlockComment()
                } else {
                    return
                }
            }
        }

        /// A lone carriage return ends a line comment too, so SQL pasted with classic Mac line
        /// endings does not swallow the rest of the statement as trivia.
        private mutating func skipToEndOfLine() {
            while index < length {
                let ch = units[index]
                if ch == 0x0A || ch == 0x0D { return }
                index += 1
            }
        }

        /// Only PostgreSQL nests block comments. Counting depth on a dialect that does not nest
        /// would swallow real SQL, and not counting it on PostgreSQL would expose commented-out
        /// SQL as if it were live.
        private mutating func skipBlockComment() {
            index += 2
            var depth = 1
            let nests = dialect == .postgres
            while index < length, depth > 0 {
                if nests, units[index] == 0x2F, unit(at: index + 1) == 0x2A {
                    depth += 1
                    index += 2
                } else if units[index] == 0x2A, unit(at: index + 1) == 0x2F {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
        }

        /// PostgreSQL honours backslash escapes only inside an `E'...'` literal.
        private func hasEscapeStringPrefix(at quote: Int) -> Bool {
            guard quote > 0 else { return false }
            let previous = units[quote - 1]
            guard previous == 0x45 || previous == 0x65 else { return false }
            return quote < 2 || !Self.isIdentifierUnit(units[quote - 2])
        }

        private mutating func skipStringLiteral() {
            let escapesWithBackslash = dialect.requiresBackslashEscapesInSingleQuotes
                || (dialect.supportsEscapeStringPrefix && hasEscapeStringPrefix(at: index))
            index += 1
            while index < length {
                let ch = units[index]
                if escapesWithBackslash, ch == 0x5C, index + 1 < length {
                    index += 2
                    continue
                }
                if ch == 0x27 {
                    if unit(at: index + 1) == 0x27 {
                        index += 2
                        continue
                    }
                    index += 1
                    return
                }
                index += 1
            }
        }

        /// Returns the unescaped identifier, or `nil` when the closing delimiter is missing.
        private mutating func consumeDelimited(closing: UInt16) -> String? {
            index += 1
            let start = index
            var doubled = false
            while index < length {
                let ch = units[index]
                if closing == 0x22, dialect.requiresBackslashEscapesInSingleQuotes,
                   ch == 0x5C, index + 1 < length {
                    index += 2
                    continue
                }
                if ch == closing {
                    if unit(at: index + 1) == closing {
                        doubled = true
                        index += 2
                        continue
                    }
                    let raw = String(decoding: units[start..<index], as: UTF16.self)
                    index += 1
                    guard doubled, let scalar = UnicodeScalar(closing) else { return raw }
                    let quote = String(Character(scalar))
                    return raw.replacingOccurrences(of: quote + quote, with: quote)
                }
                index += 1
            }
            return nil
        }

        private mutating func readWord() -> String? {
            guard index < length, Self.isIdentifierUnit(units[index]) else { return nil }
            let start = index
            while index < length, Self.isIdentifierUnit(units[index]) { index += 1 }
            return String(decoding: units[start..<index], as: UTF16.self)
        }

        private mutating func peekWord() -> String? {
            skipTrivia()
            let saved = index
            let word = readWord()
            index = saved
            return word
        }

        mutating func consumeKeyword(_ keyword: String) -> Bool {
            skipTrivia()
            let saved = index
            guard let word = readWord(), word.uppercased() == keyword else {
                index = saved
                return false
            }
            return true
        }

        /// Compares a word in place instead of allocating a `String`. A wide select list holds
        /// tens of thousands of words and this runs on every execution.
        private mutating func skipWordMatchingAny(_ keywords: [[UInt16]]) -> Bool {
            let start = index
            while index < length, Self.isIdentifierUnit(units[index]) { index += 1 }
            let count = index - start
            candidates: for keyword in keywords where keyword.count == count {
                for offset in 0..<count {
                    let codeUnit = units[start + offset]
                    let folded = (codeUnit >= 0x61 && codeUnit <= 0x7A) ? codeUnit - 0x20 : codeUnit
                    if folded != keyword[offset] { continue candidates }
                }
                return true
            }
            return false
        }

        private mutating func skipDollarQuotedBody(openerLength: Int, tag: String) -> Bool {
            index += openerLength
            while index < length {
                if units[index] == SqlDollarQuote.dollar,
                   SqlDollarQuote.matchesClose(at: index, tag: tag, in: text, bufLen: length) {
                    index += (tag as NSString).length + 2
                    return true
                }
                index += 1
            }
            return false
        }

        /// Scans forward for one of `keywords` appearing as a bare word outside any parentheses.
        /// Parenthesised subqueries, string literals, delimited identifiers, dollar-quoted bodies
        /// and comments are skipped, so a keyword hidden inside any of them never matches.
        ///
        /// Returning `false` means "not found", which callers read as safe. Anything this cannot
        /// lex confidently sets `didAbortLexing` instead, so a caller asking whether a disqualifying
        /// keyword is present never mistakes an abandoned scan for a clean one.
        private mutating func advanceToTopLevelWord(matching keywords: [[UInt16]]) -> Bool {
            var depth = 0
            while true {
                skipTrivia()
                guard index < length else { return false }
                let ch = units[index]
                switch ch {
                case 0x28:
                    depth += 1
                    index += 1
                case 0x29:
                    depth -= 1
                    index += 1
                case 0x27:
                    skipStringLiteral()
                case 0x3B:
                    return false
                case 0x23 where dialect == .generic,
                     0x2F where dialect == .generic && unit(at: index + 1) == 0x2F:
                    // ClickHouse spells line comments `#` and `//` and lands in `.generic`, which
                    // it shares with dialects that read both as operators. Neither reading can be
                    // trusted, and guessing wrong hides the real `FROM`. MySQL never reaches here
                    // because `skipTrivia` has already taken its `#` comment, and PostgreSQL keeps
                    // `#` as the jsonb path operator it is.
                    didAbortLexing = true
                    return false
                default:
                    if ch == SqlDollarQuote.dollar,
                       case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                           at: index, in: text, bufLen: length
                       ) {
                        guard consumeDollarQuoted(openerLength: openerLength, tag: tag, keywords: keywords) else {
                            return false
                        }
                    } else if ch != 0x5B, let closing = Self.closingDelimiter(for: ch) {
                        guard consumeDelimited(closing: closing) != nil else {
                            didAbortLexing = true
                            return false
                        }
                    } else if Self.isIdentifierUnit(ch) {
                        if skipWordMatchingAny(keywords), depth == 0 { return true }
                    } else {
                        index += 1
                    }
                }
            }
        }

        /// A dollar-quoted body is only a literal on PostgreSQL. DuckDB accepts the same spelling
        /// but maps to `.sqlite`, so on any other dialect a body that really is closed means the
        /// text cannot be lexed as SQL and the statement must not resolve. An opener with no closer
        /// is an ordinary `$` in an identifier and rewinds.
        private mutating func consumeDollarQuoted(
            openerLength: Int,
            tag: String,
            keywords: [[UInt16]]
        ) -> Bool {
            let saved = index
            let closed = skipDollarQuotedBody(openerLength: openerLength, tag: tag)
            if dialect.supportsDollarQuotes {
                guard closed else { return false }
                return true
            }
            if closed {
                didAbortLexing = true
                return false
            }
            index = saved
            _ = skipWordMatchingAny(keywords)
            return true
        }

        /// Finds the `FROM` belonging to the outer query.
        mutating func advanceToTopLevelFrom() -> Bool {
            advanceToTopLevelWord(matching: [[0x46, 0x52, 0x4F, 0x4D]])
        }

        /// A set operator anywhere after the table reference means the grid holds rows from more
        /// than one source. Checking only the token right after the table would miss the common
        /// `SELECT ... FROM a WHERE ... UNION SELECT ... FROM b`, whose rows would then be written
        /// back to whichever branch happened to parse first. A scan that could not be lexed counts
        /// as present, because the alternative is editing rows whose origin is unknown.
        ///
        /// `MINUS` is only a set operator where Oracle, Snowflake and Teradata land. Elsewhere it
        /// is an ordinary column name.
        mutating func hasTopLevelSetOperator() -> Bool {
            var keywords: [[UInt16]] = [
                [0x55, 0x4E, 0x49, 0x4F, 0x4E],
                [0x45, 0x58, 0x43, 0x45, 0x50, 0x54],
                [0x49, 0x4E, 0x54, 0x45, 0x52, 0x53, 0x45, 0x43, 0x54],
            ]
            if dialect == .generic {
                keywords.append([0x4D, 0x49, 0x4E, 0x55, 0x53])
            }
            if advanceToTopLevelWord(matching: keywords) { return true }
            return didAbortLexing
        }

        /// `FROM ONLY tbl` never resolves. On PostgreSQL it excludes inheritance children, and the
        /// generated write carries no `ONLY`, so it would reach the descendant rows the query left
        /// out. On a dialect without the modifier the same text is a table named `only` wearing an
        /// alias, and reading it as a modifier would return the alias as the write target. A table
        /// genuinely named `only` with no reference after it still resolves.
        mutating func consumeTableReference() -> SourceTable? {
            skipTrivia()
            let saved = index
            if peekWord()?.uppercased() == "ONLY" {
                _ = readWord()
                if let modified = consumeQualifiedReference(),
                   !nonAliasKeywords.contains(modified.name.uppercased()) {
                    return nil
                }
                index = saved
            }
            return consumeQualifiedReference()
        }

        /// Accepts `table` and `schema.table`. A three-part `catalog.schema.table` is rejected:
        /// the write path can express one qualifier, and silently dropping the catalog would aim
        /// the statement at the connected database instead of the one the query named.
        private mutating func consumeQualifiedReference() -> SourceTable? {
            guard let first = consumeIdentifierPart() else { return nil }
            guard unit(at: index) == 0x2E else { return SourceTable(schema: nil, name: first) }
            index += 1
            guard let second = consumeIdentifierPart() else { return nil }
            guard unit(at: index) != 0x2E else { return nil }
            return SourceTable(schema: first, name: second)
        }

        private mutating func consumeIdentifierPart() -> String? {
            skipTrivia()
            guard index < length else { return nil }
            let ch = units[index]
            let name: String?
            if let closing = Self.closingDelimiter(for: ch) {
                name = consumeDelimited(closing: closing)
            } else if Self.isIdentifierUnit(ch) {
                name = readWord()
            } else {
                name = nil
            }
            guard let name, !name.isEmpty else { return nil }
            return name
        }

        mutating func consumeOptionalAlias() -> Bool {
            skipTrivia()
            guard index < length else { return true }
            let ch = units[index]
            if let closing = Self.closingDelimiter(for: ch) {
                return consumeDelimited(closing: closing) != nil
            }
            guard Self.isIdentifierUnit(ch) else { return true }
            let saved = index
            guard let word = readWord() else { return true }
            guard word.uppercased() == "AS" else {
                if nonAliasKeywords.contains(word.uppercased()) { index = saved }
                return true
            }
            skipTrivia()
            guard index < length else { return false }
            let aliasChar = units[index]
            if let closing = Self.closingDelimiter(for: aliasChar) {
                return consumeDelimited(closing: closing) != nil
            }
            return readWord() != nil
        }

        mutating func atClauseBoundary() -> Bool {
            skipTrivia()
            guard index < length else { return true }
            if units[index] == 0x3B { return true }
            guard let word = peekWord() else { return false }
            let keyword = word.uppercased()
            guard clauseTerminators.contains(keyword) else { return false }
            return keyword == "FOR" ? startsRowLockingClause() : true
        }

        private mutating func startsRowLockingClause() -> Bool {
            let saved = index
            defer { index = saved }
            skipTrivia()
            _ = readWord()
            guard let modifier = peekWord()?.uppercased() else { return false }
            return rowLockingModifiers.contains(modifier)
        }
    }
}
