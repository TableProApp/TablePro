//
//  SQLFormatterService.swift
//  TablePro
//
//  Token-based SQL formatter. Tokenizes input into a stream, then walks tokens
//  with clause/nesting context to produce properly indented, readable SQL.
//

import Foundation

// MARK: - Formatter Protocol

protocol SQLFormatterProtocol {
    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int?,
        options: SQLFormatterOptions
    ) throws -> SQLFormatterResult
}

// MARK: - Main Formatter Service

struct SQLFormatterService: SQLFormatterProtocol {
    private static let maxInputSize = 10 * 1_024 * 1_024

    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int? = nil,
        options: SQLFormatterOptions = .default
    ) throws -> SQLFormatterResult {
        guard sql.utf8.count <= Self.maxInputSize else {
            throw SQLFormatterError.internalError("SQL too large (max \(Self.maxInputSize / 1_024 / 1_024)MB)")
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLFormatterError.emptyInput
        }

        let sqlLength = sql.utf16.count
        if let cursor = cursorOffset, cursor > sqlLength {
            throw SQLFormatterError.invalidCursorPosition(cursor, max: sqlLength)
        }

        let dialectProvider = SQLDialectFactory.createDialect(for: dialect)
        let dialectKeywords = dialectProvider.keywords
            .union(dialectProvider.functions)
            .union(dialectProvider.dataTypes)

        let tokenizer = SQLTokenizer(dialectKeywords: dialectKeywords)
        let tokens = tokenizer.tokenize(sql)
        var tokenFormatter = SQLTokenFormatter(options: options)
        let formatted = tokenFormatter.format(tokens)

        let newCursor = cursorOffset.map { original in
            mapCursorPosition(original: original, oldLength: sql.utf16.count, newLength: formatted.utf16.count)
        }

        return SQLFormatterResult(formattedSQL: formatted, cursorOffset: newCursor)
    }

    private func mapCursorPosition(original: Int, oldLength: Int, newLength: Int) -> Int {
        guard oldLength > 0 else { return 0 }
        let ratio = Double(original) / Double(oldLength)
        return min(Int(ratio * Double(newLength)), newLength)
    }
}

// MARK: - Token Formatter (Stateful Walker)

/// Walks the token stream with clause/nesting context to produce formatted output.
/// Extracted from SQLFormatterService to keep each function under lint limits.
internal struct SQLTokenFormatter {
    let options: SQLFormatterOptions

    init(options: SQLFormatterOptions) {
        self.options = options
    }

    // Mutable state
    private var output = ""
    private var indent = 0
    private var clauseStack: [ClauseContext] = []
    private var afterNewline = true
    private var isFirstClause = true
    private var selectColumnIndent = 0
    private var inSelectColumns = false
    private var skipCount = 0
    private var suppressNextSpace = false
    private var caseBaseIndent = 0
    /// Stack to save/restore selectColumnIndent across subquery boundaries
    private var selectColumnIndentStack: [Int] = []

    private enum ClauseContext {
        case select, from, where_, join, caseExpr, subquery, with
        case insert, update, set, createTable, createTableBody
        case inlineParen, windowParen
    }

    /// True after BETWEEN keyword — suppresses the next AND from being a clause break
    private var afterBetween = false

    // MARK: - Public

    mutating func format(_ tokens: [SQLToken]) -> String {
        let meaningful = tokens.compactMap { t -> SQLToken? in
            t.type == .whitespace ? nil : t
        }

        for mi in meaningful.indices {
            if skipCount > 0 {
                skipCount -= 1
                continue
            }

            let token = meaningful[mi]
            let next: SQLToken? = mi + 1 < meaningful.count ? meaningful[mi + 1] : nil
            let prev: SQLToken? = mi > 0 ? meaningful[mi - 1] : nil
            let next2: SQLToken? = mi + 2 < meaningful.count ? meaningful[mi + 2] : nil

            processToken(token, prev: prev, next: next, next2: next2)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token Processing

    private mutating func processToken(_ token: SQLToken, prev: SQLToken?, next: SQLToken?, next2: SQLToken?) {
        if token.type == .comment {
            handleComment(token)
            return
        }

        if token.type == .punctuation {
            handlePunctuation(token, prev: prev, next: next)
            return
        }

        if token.type == .keyword {
            handleKeyword(token, prev: prev, next: next, next2: next2)
            return
        }

        // All other tokens: identifiers, numbers, strings, operators, placeholders
        appendToken(token.value)
    }

    // MARK: - Comment Handling

    private mutating func handleComment(_ token: SQLToken) {
        guard options.preserveComments else { return }
        if !afterNewline { newline() }
        output += token.value
        output += "\n"
        afterNewline = true
    }

    // MARK: - Punctuation Handling

    private mutating func handlePunctuation(_ token: SQLToken, prev: SQLToken?, next: SQLToken?) {
        switch token.value {
        case ";":
            output += ";"
            output += "\n"
            afterNewline = true
            isFirstClause = true
            indent = 0
            clauseStack.removeAll()
            inSelectColumns = false

        case ",":
            output += ","
            if inSelectColumns {
                output += "\n" + String(repeating: " ", count: selectColumnIndent)
                afterNewline = false
                suppressNextSpace = true
            } else if currentContext == .set {
                output += "\n" + indentStr() + "    "
                afterNewline = false
                suppressNextSpace = true
            } else if currentContext == .createTableBody {
                output += "\n"
                afterNewline = true
            }

        case "(":
            handleOpenParen(next: next, prev: prev)

        case ")":
            handleCloseParen()

        case ".":
            // Qualified name dot — no spaces around it
            output += "."
            afterNewline = false
            suppressNextSpace = true

        default:
            appendToken(token.value)
        }
    }

    private mutating func handleOpenParen(next: SQLToken?, prev: SQLToken?) {
        // Subquery: ( SELECT ...
        if next?.upperValue == "SELECT" {
            if suppressNextSpace {
                output += "("
            } else {
                output += " ("
            }
            output += "\n"
            selectColumnIndentStack.append(selectColumnIndent)
            indent += 1
            afterNewline = true
            isFirstClause = true
            suppressNextSpace = false
            clauseStack.append(.subquery)
            return
        }
        // CTE body: AS (
        if prev?.upperValue == "AS" && clauseStack.contains(.with) {
            output += " ("
            output += "\n"
            selectColumnIndentStack.append(selectColumnIndent)
            indent += 1
            afterNewline = true
            isFirstClause = true
            suppressNextSpace = false
            clauseStack.append(.subquery)
            return
        }
        // CREATE TABLE columns: table_name (
        if clauseStack.contains(.createTable) && !clauseStack.contains(.createTableBody) {
            output += " ("
            output += "\n"
            indent += 1
            afterNewline = true
            suppressNextSpace = false
            clauseStack.append(.createTableBody)
            return
        }
        // Window function: OVER(...)
        if prev?.upperValue == "OVER" {
            output += "("
            afterNewline = false
            suppressNextSpace = true
            clauseStack.append(.windowParen)
            return
        }
        // Inline parenthesized expression: COUNT(*), VARCHAR(255), etc.
        output += "("
        afterNewline = false
        suppressNextSpace = true
        clauseStack.append(.inlineParen)
    }

    private mutating func handleCloseParen() {
        // Inline or window paren: just close it
        if currentContext == .inlineParen || currentContext == .windowParen {
            clauseStack.removeLast()
            output += ")"
            afterNewline = false
            suppressNextSpace = false
            return
        }
        // Block paren (subquery or CREATE TABLE body): pop back to the block opener
        if let idx = clauseStack.lastIndex(where: { $0 == .subquery || $0 == .createTableBody }) {
            clauseStack.removeSubrange(idx...)
            indent = max(0, indent - 1)
            output += "\n" + indentStr() + ")"
            afterNewline = false
            isFirstClause = false
            // Restore outer SELECT state after leaving subquery
            inSelectColumns = clauseStack.contains(.select)
            if let saved = selectColumnIndentStack.popLast() {
                selectColumnIndent = saved
            }
            suppressNextSpace = false
            return
        }
        // Unmatched paren — just append
        output += ")"
        afterNewline = false
        suppressNextSpace = false
    }

    // MARK: - Keyword Handling

    private mutating func handleKeyword(_ token: SQLToken, prev: SQLToken?, next: SQLToken?, next2: SQLToken?) {
        let upper = token.upperValue
        let kw = options.uppercaseKeywords ? upper : token.value

        switch upper {
        case "SELECT":
            handleSelect(kw: kw)
        case "FROM":
            handleFrom(kw: kw, prev: prev)
        case "WHERE":
            handleClauseKeyword(kw: kw, context: .where_)
        case "AND", "OR":
            handleAndOr(kw: kw, upper: upper)
        case "JOIN":
            handleClauseKeyword(kw: kw, context: .join)
        case "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL":
            handleJoinPrefix(upper: upper, kw: kw, next: next, next2: next2)
        case "OUTER":
            break // absorbed by JOIN prefix handler
        case "ON":
            handleOn(kw: kw)
        case "OVER":
            appendToken(kw)
        case "PARTITION":
            appendToken(kw)
        case "BETWEEN":
            afterBetween = true
            appendToken(kw)
        case "ORDER", "GROUP":
            handleOrderGroup(upper: upper, kw: kw, next: next)
        case "BY":
            // standalone BY (not consumed by ORDER/GROUP) — should not happen normally
            appendToken(kw)
        case "HAVING", "LIMIT", "OFFSET":
            handleClauseKeyword(kw: kw, context: nil)
        case "UNION", "INTERSECT", "EXCEPT":
            handleSetOperation(upper: upper, kw: kw, next: next)
        case "ALL":
            // standalone ALL (not consumed by UNION ALL)
            appendToken(kw)
        case "CASE":
            handleCase(kw: kw)
        case "WHEN", "ELSE":
            handleWhenElse(kw: kw)
        case "THEN":
            output += " " + kw
            afterNewline = false
        case "END":
            handleEnd(kw: kw)
        case "WITH":
            handleWith(kw: kw)
        case "INSERT":
            handleInsert(kw: kw, next: next)
        case "INTO":
            // standalone INTO (not consumed by INSERT INTO)
            appendToken(kw)
        case "VALUES":
            newline()
            appendToken(kw)
        case "UPDATE":
            handleStatementStart(kw: kw, context: .update)
        case "SET":
            handleClauseKeyword(kw: kw, context: .set)
        case "DELETE":
            handleStatementStart(kw: kw, context: nil)
        case "CREATE":
            handleStatementStart(kw: kw, context: .createTable)
        case "TABLE", "AS":
            appendToken(kw)
        default:
            appendToken(kw)
        }
    }

    // MARK: - Specific Keyword Handlers

    private mutating func handleSelect(kw: String) {
        if !isFirstClause { newline() }
        output += (afterNewline ? indentStr() : "") + kw
        isFirstClause = false
        afterNewline = false
        inSelectColumns = true
        selectColumnIndent = indent * options.indentSize + 7
        clauseStack.append(.select)
    }

    private mutating func handleFrom(kw: String, prev: SQLToken?) {
        if prev?.upperValue == "DELETE" {
            newline()
            appendToken(kw)
            inSelectColumns = false
            return
        }
        inSelectColumns = false
        newline()
        appendToken(kw)
        replaceTop(with: .from)
    }

    private mutating func handleClauseKeyword(kw: String, context: ClauseContext?) {
        inSelectColumns = false
        newline()
        appendToken(kw)
        if let ctx = context { replaceTop(with: ctx) }
    }

    private mutating func handleAndOr(kw: String, upper: String) {
        // BETWEEN x AND y — AND stays inline
        if upper == "AND" && afterBetween {
            afterBetween = false
            output += " " + kw
            afterNewline = false
            return
        }
        if currentContext == .where_ {
            newline()
            output += indentStr() + "  " + kw
            afterNewline = false
        } else {
            output += " " + kw
            afterNewline = false
        }
    }

    private mutating func handleJoinPrefix(upper: String, kw: String, next: SQLToken?, next2: SQLToken?) {
        // LEFT OUTER JOIN → skip 2 tokens (OUTER, JOIN)
        if next?.upperValue == "OUTER" && next2?.upperValue == "JOIN" {
            inSelectColumns = false
            let joinKw = options.uppercaseKeywords ? "\(upper) OUTER JOIN" : "\(upper.lowercased()) outer join"
            newline()
            appendToken(joinKw)
            replaceTop(with: .join)
            skipCount = 2
        // LEFT JOIN → skip 1 token (JOIN)
        } else if next?.upperValue == "JOIN" {
            inSelectColumns = false
            let joinKw = options.uppercaseKeywords ? "\(upper) JOIN" : "\(upper.lowercased()) join"
            newline()
            appendToken(joinKw)
            replaceTop(with: .join)
            skipCount = 1
        } else {
            appendToken(kw)
        }
    }

    private mutating func handleOn(kw: String) {
        if currentContext == .join {
            newline()
            output += indentStr() + "  " + kw
            afterNewline = false
        } else {
            output += " " + kw
            afterNewline = false
        }
    }

    private mutating func handleOrderGroup(upper: String, kw: String, next: SQLToken?) {
        // Inside window function parens — stay inline
        if clauseStack.contains(.windowParen) {
            if next?.upperValue == "BY" {
                let byKw = options.uppercaseKeywords ? "BY" : "by"
                output += " " + kw + " " + byKw
                afterNewline = false
                skipCount = 1
            } else {
                appendToken(kw)
            }
            return
        }
        inSelectColumns = false
        if next?.upperValue == "BY" {
            let byKw = options.uppercaseKeywords ? "BY" : "by"
            newline()
            output += indentStr() + kw + " " + byKw
            afterNewline = false
            skipCount = 1
        } else {
            appendToken(kw)
        }
    }

    private mutating func handleSetOperation(upper: String, kw: String, next: SQLToken?) {
        inSelectColumns = false
        indent = 0
        clauseStack.removeAll()
        if upper == "UNION" && next?.upperValue == "ALL" {
            let allKw = options.uppercaseKeywords ? "ALL" : "all"
            output += "\n\n" + kw + " " + allKw + "\n"
            skipCount = 1 // skip ALL
        } else {
            output += "\n\n" + kw + "\n"
        }
        afterNewline = true
        isFirstClause = true
    }

    private mutating func handleCase(kw: String) {
        if inSelectColumns {
            caseBaseIndent = selectColumnIndent
        } else {
            caseBaseIndent = indent * options.indentSize
        }
        appendToken(kw)
        clauseStack.append(.caseExpr)
    }

    private mutating func handleWhenElse(kw: String) {
        let whenIndent = caseBaseIndent + options.indentSize
        output += "\n" + String(repeating: " ", count: whenIndent) + kw
        afterNewline = false
        suppressNextSpace = false
    }

    private mutating func handleEnd(kw: String) {
        if clauseStack.last == .caseExpr { clauseStack.removeLast() }
        // Align END at same level as CASE
        output += "\n" + String(repeating: " ", count: caseBaseIndent)
        output += kw
        afterNewline = false
    }

    private mutating func handleWith(kw: String) {
        if !isFirstClause { output += "\n" }
        output += kw
        isFirstClause = false
        afterNewline = false
        clauseStack.append(.with)
    }

    private mutating func handleInsert(kw: String, next: SQLToken?) {
        if !isFirstClause { output += "\n" }
        if next?.upperValue == "INTO" {
            let intoKw = options.uppercaseKeywords ? "INTO" : "into"
            output += kw + " " + intoKw
            skipCount = 1 // skip INTO
        } else {
            output += kw
        }
        isFirstClause = false
        afterNewline = false
        clauseStack.append(.insert)
    }

    private mutating func handleStatementStart(kw: String, context: ClauseContext?) {
        if !isFirstClause { output += "\n" }
        output += kw
        isFirstClause = false
        afterNewline = false
        if let ctx = context { clauseStack.append(ctx) }
    }

    // MARK: - Helpers

    private var currentContext: ClauseContext? { clauseStack.last }

    private mutating func replaceTop(with ctx: ClauseContext) {
        if !clauseStack.isEmpty { clauseStack.removeLast() }
        clauseStack.append(ctx)
    }

    private func indentStr() -> String {
        String(repeating: " ", count: indent * options.indentSize)
    }

    private mutating func newline() {
        output += "\n"
        afterNewline = true
    }

    private mutating func appendToken(_ value: String) {
        if afterNewline {
            output += indentStr() + value
        } else if suppressNextSpace {
            output += value
        } else {
            output += " " + value
        }
        afterNewline = false
        suppressNextSpace = false
    }
}
