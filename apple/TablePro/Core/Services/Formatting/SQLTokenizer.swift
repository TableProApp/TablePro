//
//  SQLTokenizer.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

enum SQLTokenType: Equatable {
    case keyword
    case identifier
    case number
    case string
    case `operator`
    case punctuation
    case whitespace
    case comment
    case placeholder
    // A line the client reads and the server never sees: `GO` in a T-SQL script, `DELIMITER //` in a MySQL one,
    // a lone `/` in a SQL*Plus one.
    case directive
}

struct SQLToken: Equatable {
    let type: SQLTokenType
    let value: String
    let upperValue: String

    init(type: SQLTokenType, value: String) {
        self.type = type
        self.value = value
        self.upperValue = value.uppercased()
    }
}

// Comments, literals, quoted identifiers and batch lines end where the engine's grammar says (`SQLNonCodeSpan`), so a
// formatted query keeps every one of them byte for byte. Only code between them is split into words and operators.
//
// Without a grammar the text is read exactly as before the formatter read grammars, because the query fingerprint is
// the one caller and its hashes are stored: a different reading would split or merge history groups after an upgrade.
struct SQLTokenizer {
    private static let standardKeywords: Set<String> = [
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

    // No engine reads one of these as two valid operators, so a run written together stays together whatever the
    // dialect declares: T-SQL's `+=`, SQLite's `==`, Oracle's `^=` and `**`, DuckDB's `//`. `<@` is not here: T-SQL
    // reads `a<@b` as `a < @b`.
    private static let commonOperators: Set<String> = [
        ">=", "<=", "<>", "!=", "!<", "!>", "||", "::", "->", "->>", ":=", "=>", "<=>", "&&", "<<", ">>",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "~=", "==", "**", "//",
    ]

    private let dialectKeywords: Set<String>
    private let operatorsByFirstUnit: [UInt16: [String]]

    init(dialectKeywords: Set<String> = [], operators: Set<String> = []) {
        self.dialectKeywords = dialectKeywords
        let multiCharacter = Self.commonOperators.union(operators.filter { symbol in
            symbol.utf16.count > 1 && symbol.utf16.allSatisfy(Lexer.isOperatorUnit)
        })
        var byFirst: [UInt16: [String]] = [:]
        for symbol in multiCharacter {
            guard let first = symbol.utf16.first else { continue }
            byFirst[first, default: []].append(symbol)
        }
        self.operatorsByFirstUnit = byFirst.mapValues { $0.sorted { $0.utf16.count > $1.utf16.count } }
    }

    func tokenize(_ sql: String) -> [SQLToken] {
        readsWithoutGrammar(sql)
    }

    func tokenize(_ sql: String, grammar: SQLLexicalGrammar) -> [SQLToken] {
        var lexer = Lexer(text: sql as NSString, grammar: grammar, tokenizer: self)
        return lexer.run()
    }

    // The 0-based lines on which `text` holds a client directive under `grammar`.
    func directiveLines(in text: String, grammar: SQLLexicalGrammar) -> Set<Int> {
        var lines: Set<Int> = []
        var line = 0
        for token in tokenize(text, grammar: grammar) {
            if token.type == .directive { lines.insert(line) }
            line += token.value.utf16.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return lines
    }

    fileprivate func isKeyword(_ upperWord: String) -> Bool {
        Self.standardKeywords.contains(upperWord) || dialectKeywords.contains(upperWord)
    }

    fileprivate func operatorCandidates(startingWith unit: UInt16) -> [String] {
        operatorsByFirstUnit[unit] ?? []
    }

    private func readsWithoutGrammar(_ sql: String) -> [SQLToken] {
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
                let isKW = Self.standardKeywords.contains(word.uppercased())
                    || dialectKeywords.contains(word.uppercased())
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

private struct Lexer {
    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let minus = UInt16(UnicodeScalar("-").value)
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let at = UInt16(UnicodeScalar("@").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let question = UInt16(UnicodeScalar("?").value)
    private static let ampersand = UInt16(UnicodeScalar("&").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let carriageReturn = UInt16(UnicodeScalar("\r").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let punctuationUnits: Set<UInt16> = Set("(),;.".utf16)
    private static let operatorUnits: Set<UInt16> = Set("=<>+-*/%&|^~!@#?:$".utf16)
    private static let delimiterWord = "DELIMITER"

    static func isOperatorUnit(_ unit: UInt16) -> Bool {
        operatorUnits.contains(unit)
    }

    let text: NSString
    let length: Int
    let grammar: SQLLexicalGrammar
    let tokenizer: SQLTokenizer
    private let batchSeparatorEnds: [Int: Int]
    private var delimiter = ";"
    private var atStatementStart = true
    private var tokens: [SQLToken] = []
    private var index = 0

    init(text: NSString, grammar: SQLLexicalGrammar, tokenizer: SQLTokenizer) {
        self.text = text
        self.length = text.length
        self.grammar = grammar
        self.tokenizer = tokenizer
        var ends: [Int: Int] = [:]
        for separator in SQLStatementScanner.batchSeparators(in: text as String, grammar: grammar) {
            ends[separator.range.location] = NSMaxRange(separator.range)
        }
        self.batchSeparatorEnds = ends
    }

    mutating func run() -> [SQLToken] {
        while index < length {
            step()
        }
        return tokens
    }

    private mutating func step() {
        let unit = text.character(at: index)

        if isBlank(unit) {
            let start = index
            while index < length, isBlank(text.character(at: index)) {
                index += 1
            }
            emit(.whitespace, from: start)
            return
        }
        if let end = batchSeparatorEnds[index] {
            let start = index
            index = end
            emit(.directive, from: start)
            return
        }
        if unit == Self.slash, grammar.contains(.slashLineTerminators),
           SQLStatementScanner.isSlashLine(text, at: index, length: length) {
            let start = index
            index += 1
            emit(.directive, from: start)
            return
        }
        if readDelimiterDirective() { return }
        if delimiter != ";", matches(delimiter, at: index) {
            let start = index
            index += (delimiter as NSString).length
            emit(.punctuation, from: start)
            return
        }
        if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
            emitSpan(span)
            return
        }
        if isDigit(unit) || startsFraction(unit) {
            readNumber()
            return
        }
        if isWordStart(unit) {
            readWord()
            return
        }
        if readPrefixedName(unit) { return }
        readOperatorOrPunctuation(unit)
    }

    // MARK: - Spans

    private mutating func emitSpan(_ span: SQLNonCodeSpan.Span) {
        let start = index
        index = max(span.end, index + 1)
        switch span.kind {
        case .lineComment:
            var value = substring(from: start, to: index)
            while value.hasSuffix("\r") {
                value.removeLast()
            }
            append(SQLToken(type: .comment, value: value))
        case .blockComment:
            emit(.comment, from: start)
        case .executableComment:
            emit(.string, from: start)
        case .parameter:
            emit(.placeholder, from: start)
        case .quoted:
            let opener = text.character(at: start)
            emit(opener == Self.backtick || opener == Self.openBracket ? .identifier : .string, from: start)
        }
    }

    // MARK: - Client directives

    // `DELIMITER //` at the start of a statement, on a line of its own, changes what ends a statement, as the mysql
    // client and the import read a script.
    private mutating func readDelimiterDirective() -> Bool {
        guard grammar.contains(.delimiterDirective), atStatementStart, isAtLineStart(index) else { return false }
        let wordLength = (Self.delimiterWord as NSString).length
        guard index + wordLength < length,
              substring(from: index, to: index + wordLength).uppercased() == Self.delimiterWord,
              isLineBlank(text.character(at: index + wordLength))
        else {
            return false
        }
        var end = index + wordLength
        while end < length, text.character(at: end) != Self.newline {
            end += 1
        }
        let line = substring(from: index, to: end).trimmingCharacters(in: .whitespaces)
        let newDelimiter = String(line.dropFirst(Self.delimiterWord.count)).trimmingCharacters(in: .whitespaces)
        guard !newDelimiter.isEmpty else { return false }
        delimiter = newDelimiter
        append(SQLToken(type: .directive, value: line))
        index = end
        return true
    }

    private func isAtLineStart(_ position: Int) -> Bool {
        var cursor = position - 1
        while cursor >= 0 {
            let unit = text.character(at: cursor)
            if unit == Self.newline { return true }
            guard isLineBlank(unit) else { return false }
            cursor -= 1
        }
        return true
    }

    private func matches(_ word: String, at position: Int) -> Bool {
        let wordLength = (word as NSString).length
        guard position + wordLength <= length else { return false }
        return text.substring(with: NSRange(location: position, length: wordLength)) == word
    }

    // MARK: - Numbers and words

    // A word glued to a number belongs to it: `0xFF` and `0b101` are literals, and MySQL's `2fa_codes` is a name.
    private mutating func readNumber() {
        let start = index
        while index < length, isDigit(text.character(at: index)) || text.character(at: index) == Self.dot {
            index += 1
        }
        if index + 2 < length, isExponentMarker(text.character(at: index)),
           [Self.plus, Self.minus].contains(text.character(at: index + 1)), isDigit(text.character(at: index + 2)) {
            index += 2
        }
        while index < length, continuesWord(at: index) {
            index += 1
        }
        let value = substring(from: start, to: index)
        append(SQLToken(type: Self.isNumberLiteral(value) ? .number : .identifier, value: value))
    }

    // `.5` is a number, but the `.2fa` of MySQL's `db.2fa` is the second half of a name.
    private func startsFraction(_ unit: UInt16) -> Bool {
        guard unit == Self.dot, index + 1 < length, isDigit(text.character(at: index + 1)) else { return false }
        guard index > 0 else { return true }
        let before = text.character(at: index - 1)
        return !isWordPart(before) && ![Self.backtick, Self.doubleQuote, Self.closeBracket, Self.closeParen].contains(before)
    }

    // `0xFF` and `0b101` are literals; MySQL's `0bar` and `0xyz` are names, since their digits are not hex or binary.
    private static func isNumberLiteral(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.count > 2, lower.hasPrefix("0x") { return lower.dropFirst(2).allSatisfy(\.isHexDigit) }
        if lower.count > 2, lower.hasPrefix("0b") { return lower.dropFirst(2).allSatisfy { $0 == "0" || $0 == "1" } }
        return lower.allSatisfy { $0.isNumber || $0 == "." || $0 == "e" || $0 == "+" || $0 == "-" }
    }

    // A literal introducer stays on its literal (`N'abc'`, `X'4D'`, `B'101'`, `_utf8mb4'a'`, `U&'d\0061'`). Any other
    // word before a quote is a word (`SELECT a'alias'` is the column `a` and its alias); the formatter still writes
    // the two together, so an introducer this list lacks keeps its literal. `E'...'` and `q'[...]'` are the grammar's.
    private static let literalIntroducers: Set<String> = ["N", "X", "B"]

    // MySQL's character sets, which `_name'...'` introduces (SHOW CHARACTER SET, 8.4).
    private static let mySQLCharacterSets: Set<String> = [
        "ARMSCII8", "ASCII", "BIG5", "BINARY", "CP1250", "CP1251", "CP1256", "CP1257", "CP850", "CP852", "CP866",
        "CP932", "DEC8", "EUCJPMS", "EUCKR", "GB18030", "GB2312", "GBK", "GEOSTD8", "GREEK", "HEBREW", "HP8",
        "KEYBCS2", "KOI8R", "KOI8U", "LATIN1", "LATIN2", "LATIN5", "LATIN7", "MACCE", "MACROMAN", "SJIS", "SWE7",
        "TIS620", "UCS2", "UJIS", "UTF16", "UTF16LE", "UTF32", "UTF8", "UTF8MB3", "UTF8MB4",
    ]

    private static func isLiteralIntroducer(_ upperWord: String) -> Bool {
        literalIntroducers.contains(upperWord)
            || (upperWord.hasPrefix("_") && mySQLCharacterSets.contains(String(upperWord.dropFirst())))
    }

    private mutating func readWord() {
        let start = index
        index += 1
        while index < length, continuesWord(at: index) {
            index += 1
        }
        let word = substring(from: start, to: index)
        let upper = word.uppercased()
        if tokenizer.isKeyword(upper) {
            append(SQLToken(type: .keyword, value: word))
            return
        }
        if upper == "U", index + 1 < length, text.character(at: index) == Self.ampersand,
           let span = quotedSpan(at: index + 1) {
            let opener = text.character(at: index + 1)
            index = span.end
            append(SQLToken(type: opener == Self.singleQuote ? .string : .identifier, value: substring(from: start, to: index)))
            return
        }
        if Self.isLiteralIntroducer(upper), index < length, text.character(at: index) == Self.singleQuote,
           let span = quotedSpan(at: index) {
            index = span.end
            append(SQLToken(type: .string, value: substring(from: start, to: index)))
            return
        }
        append(SQLToken(type: .identifier, value: word))
    }

    private func quotedSpan(at position: Int) -> SQLNonCodeSpan.Span? {
        guard position < length else { return nil }
        let unit = text.character(at: position)
        guard unit == Self.singleQuote || unit == Self.doubleQuote,
              let span = SQLNonCodeSpan.span(at: position, in: text, grammar: grammar), span.kind == .quoted
        else {
            return nil
        }
        return span
    }

    // `@name`, `@@version`, `:name`, `$1`, `?1` and T-SQL's `#temp` and `##global` are one token each.
    private mutating func readPrefixedName(_ unit: UInt16) -> Bool {
        let start = index
        switch unit {
        case Self.question:
            if let symbol = longestOperator(at: index) {
                index += (symbol as NSString).length
                emit(.operator, from: start)
                return true
            }
            index += 1
            while index < length, isDigit(text.character(at: index)) {
                index += 1
            }
            emit(.placeholder, from: start)
            return true
        case Self.colon:
            guard index + 1 < length, isWordPart(text.character(at: index + 1)) else { return false }
            index += 1
            consumeWordParts()
            emit(.placeholder, from: start)
            return true
        case Self.at, Self.hash:
            var cursor = index + 1
            if cursor < length, text.character(at: cursor) == unit {
                cursor += 1
            }
            // SQLite's `@1` and T-SQL's `@1st` are parameters; `#` starts a temp table name only before a letter.
            guard cursor < length,
                  unit == Self.at ? isWordPart(text.character(at: cursor)) : isWordStart(text.character(at: cursor))
            else {
                return false
            }
            index = cursor
            consumeWordParts()
            emit(unit == Self.at ? .placeholder : .identifier, from: start)
            return true
        case Self.dollar:
            guard index + 1 < length, isWordPart(text.character(at: index + 1)) else { return false }
            index += 1
            consumeWordParts()
            emit(.placeholder, from: start)
            return true
        default:
            return false
        }
    }

    private mutating func consumeWordParts() {
        while index < length, continuesWord(at: index) {
            index += 1
        }
    }

    // A custom delimiter ends a word it is glued to (`END$$`), as the mysql client and the import find it.
    private func continuesWord(at position: Int) -> Bool {
        guard isWordPart(text.character(at: position)) else { return false }
        return delimiter == ";" || !matches(delimiter, at: position)
    }

    // MARK: - Operators

    private mutating func readOperatorOrPunctuation(_ unit: UInt16) {
        let start = index
        if let symbol = longestOperator(at: index) {
            index += (symbol as NSString).length
            emit(.operator, from: start)
            return
        }
        index += 1
        emit(Self.punctuationUnits.contains(unit) ? .punctuation : .operator, from: start)
    }

    private func longestOperator(at position: Int) -> String? {
        tokenizer.operatorCandidates(startingWith: text.character(at: position)).first { matches($0, at: position) }
    }

    // MARK: - Characters

    private func isBlank(_ unit: UInt16) -> Bool {
        switch unit {
        case Self.space, Self.tab, Self.newline, Self.carriageReturn, 0x0B, 0x0C, 0x2028, 0x2029:
            return true
        default:
            return SQLSeparatingCharacter.kind(of: unit) == .nonASCIISpace
        }
    }

    private func isLineBlank(_ unit: UInt16) -> Bool {
        unit == Self.space || unit == Self.tab
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private func isExponentMarker(_ unit: UInt16) -> Bool {
        unit == UInt16(UnicodeScalar("e").value) || unit == UInt16(UnicodeScalar("E").value)
    }

    private func isWordStart(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return SqlDollarQuote.isIdentifierStart(unit)
        }
        return !isBlank(unit) && !SQLSeparatingCharacter.isSeparating(unit)
    }

    // `$` continues a name on every engine that has one in a name; `#` and `@` only where the grammar says (Oracle's
    // `v$session` and `SYS#`, T-SQL's `Part#` and `c@d`), since MySQL reads `a#b` as `a` and a comment.
    private func isWordPart(_ unit: UInt16) -> Bool {
        if isWordStart(unit) || isDigit(unit) || unit == Self.dollar { return true }
        if unit == Self.at { return grammar.contains(.hashAndAtInIdentifiers) }
        return unit == Self.hash && !grammar.isDisjoint(with: [.dollarAndHashInIdentifiers, .hashAndAtInIdentifiers])
    }

    // MARK: - Output

    private mutating func emit(_ type: SQLTokenType, from start: Int) {
        append(SQLToken(type: type, value: substring(from: start, to: index)))
    }

    private mutating func append(_ token: SQLToken) {
        tokens.append(token)
        switch token.type {
        case .whitespace, .comment:
            break
        case .directive:
            atStatementStart = true
        case .punctuation:
            atStatementStart = token.value == delimiter
        default:
            atStatementStart = false
        }
    }

    private func substring(from start: Int, to end: Int) -> String {
        text.substring(with: NSRange(location: start, length: end - start))
    }
}
