//
//  SelectSourceTableParser.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

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

    /// - Parameters:
    ///   - dialect: decides whether `MINUS` is a set operator, which is grammar and not lexing.
    ///   - readings: where strings, comments and identifiers end. The parse reads the execution grammar and gives up
    ///     wherever the plausible readings disagree about whether `#` or `//` starts a comment.
    static func singleSourceTable(in sql: String, dialect: SqlDialect, readings: SQLLexicalReadings) -> SourceTable? {
        var cursor = Cursor(sql, dialect: dialect, readings: readings)
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
        /// into 33 ms on the main actor. Transcoding once up front keeps every read a subscript,
        /// and the `NSString` the lexer reads is built over those same UTF-16 units, so its reads
        /// stay constant time too.
        private let text: NSString
        private let units: [UInt16]
        private let length: Int
        private let dialect: SqlDialect
        private let grammar: SQLLexicalGrammar
        private let hashCommentsAreAmbiguous: Bool
        private let slashCommentsAreAmbiguous: Bool
        private var index = 0
        private(set) var didAbortLexing = false

        init(_ sql: String, dialect: SqlDialect, readings: SQLLexicalReadings) {
            units = Array(sql.utf16)
            text = NSString(characters: units, length: units.count)
            length = units.count
            self.dialect = dialect
            grammar = readings.execution
            hashCommentsAreAmbiguous = Self.readingsDisagree(readings, on: .hashLineComments)
            slashCommentsAreAmbiguous = Self.readingsDisagree(readings, on: .doubleSlashLineComments)
        }

        private static func readingsDisagree(_ readings: SQLLexicalReadings, on fact: SQLLexicalGrammar) -> Bool {
            let holding = readings.all.filter { $0.contains(fact) }.count
            return holding > 0 && holding < readings.all.count
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

        /// Whitespace and comments, where the grammar ends them: a block comment nests only on an engine that
        /// nests it, and a line comment ends at a lone carriage return only where the engine ends it there.
        private mutating func skipTrivia() {
            while index < length {
                if Self.isSpace(units[index]) {
                    index += 1
                    continue
                }
                guard !startsAmbiguousLineComment(at: index),
                      let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), span.kind.isComment
                else {
                    return
                }
                index = max(span.end, index + 1)
            }
        }

        /// Returns the unescaped identifier, or `nil` when the closing delimiter is missing.
        private mutating func consumeDelimited(closing: UInt16) -> String? {
            let backslashEscapes = grammar.backslashEscapes(inQuote: units[index])
            index += 1
            let start = index
            var doubled = false
            while index < length {
                let ch = units[index]
                if backslashEscapes, ch == 0x5C, index + 1 < length {
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
                case 0x3B:
                    return false
                default:
                    if startsAmbiguousLineComment(at: index) || closesUnreadDollarBody(at: index) {
                        didAbortLexing = true
                        return false
                    }
                    if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                        if !span.isTerminated, Self.closingDelimiter(for: ch) != nil {
                            didAbortLexing = true
                            return false
                        }
                        index = max(span.end, index + 1)
                    } else if Self.isIdentifierUnit(ch) {
                        if skipWordMatchingAny(keywords), depth == 0 { return true }
                    } else {
                        index += 1
                    }
                }
            }
        }

        /// A `#` or `//` the plausible readings disagree about. Reading it as a comment where the
        /// engine reads an operator, or the other way round, hides the real `FROM`, so the parse
        /// gives up instead of guessing. `#` is a comment on MySQL and an operator on PostgreSQL.
        private func startsAmbiguousLineComment(at position: Int) -> Bool {
            let ch = units[position]
            if ch == 0x23 { return hashCommentsAreAmbiguous }
            return ch == 0x2F && unit(at: position + 1) == 0x2F && slashCommentsAreAmbiguous
        }

        /// A tagged dollar body that closes, on a grammar with no dollar quotes: the text cannot be
        /// lexed as that engine's SQL, so the statement must not resolve. An opener with no closer
        /// is an ordinary `$` in an identifier.
        private func closesUnreadDollarBody(at position: Int) -> Bool {
            guard units[position] == SqlDollarQuote.dollar, grammar.dollarQuoteStyle == nil,
                  case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                      at: position,
                      in: text,
                      bufLen: length
                  )
            else {
                return false
            }
            var cursor = position + openerLength
            while cursor < length {
                if units[cursor] == SqlDollarQuote.dollar,
                   SqlDollarQuote.matchesClose(at: cursor, tag: tag, in: text, bufLen: length) {
                    return true
                }
                cursor += 1
            }
            return false
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
