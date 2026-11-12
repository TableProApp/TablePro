//
//  SQLParameterExtractor.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

enum SQLParameterExtractor {
    // The text the parameter panel reads names from: every statement that can bind one, joined. A definition is left
    // out: `:NEW` in a trigger body is a pseudo-record, and rewriting it into a placeholder stores a broken trigger.
    static func parameterSource(of statements: [SQLStatementScanner.ExecutableStatement]) -> String {
        statements.filter(\.acceptsBindParameters).map(\.sql).joined(separator: "; ")
    }

    // The grammar a caller that names none is read with: the quotes and escapes this reader took for every engine
    // before it read grammars.
    static let unspecifiedGrammar: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .taggedDollarQuotes,
    ]

    static func extractParameters(from sql: String, grammar: SQLLexicalGrammar = unspecifiedGrammar) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        scan(sql: sql, grammar: grammar) { name, _ in
            if !seen.contains(name) {
                seen.insert(name)
                result.append(name)
            }
        }
        return result
    }

    static func convertToNativeStyle(
        sql: String,
        parameters: [QueryParameter],
        style: ParameterStyle,
        grammar: SQLLexicalGrammar = unspecifiedGrammar
    ) -> (sql: String, values: [Any?]) {
        let nsSQL = sql as NSString
        let length = nsSQL.length
        guard length > 0 else { return (sql: sql, values: []) }

        let paramLookup = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var resultSQL = ""
        var values: [Any?] = []
        var dollarIndex = 1
        var lastCopied = 0

        scan(sql: sql, grammar: grammar) { name, range in
            if lastCopied < range.location {
                resultSQL += nsSQL.substring(with: NSRange(location: lastCopied, length: range.location - lastCopied))
            }

            if let param = paramLookup[name] {
                values.append(
                    param.isNull ? nil : TypedParameterValue(text: param.value, kind: param.type.pluginKind(for: param.value))
                )
            } else {
                values.append(nil)
            }

            // `LIMIT:n` becomes `LIMIT $1`: PostgreSQL reads `$` inside a name, so `LIMIT$1` would be one identifier.
            if range.location > 0, SQLNonCodeSpan.isWordUnit(nsSQL.character(at: range.location - 1)) {
                resultSQL += " "
            }

            switch style {
            case .questionMark:
                resultSQL += "?"
            case .dollar:
                resultSQL += "$\(dollarIndex)"
                dollarIndex += 1
            }

            lastCopied = range.location + range.length
        }

        if lastCopied < length {
            resultSQL += nsSQL.substring(with: NSRange(location: lastCopied, length: length - lastCopied))
        }

        return (sql: resultSQL, values: values)
    }

    // MARK: - Private

    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)

    // Reserved on every engine that takes `:name`, Snowflake included, and always followed by an operand, so a `:`
    // glued to one starts a bind: `IN:ids`, `BETWEEN:a AND:b`, `THEN:p`.
    private static let operandKeywords: Set<String> = [
        "AND", "BETWEEN", "ELSE", "HAVING", "ILIKE", "IN", "LIKE", "NOT", "OR", "SELECT", "THEN", "WHEN", "WHERE",
    ]

    // Snowflake leaves both unreserved, so `SELECT limit:currency` there is a path into a column. Each is the
    // row-limit clause, and the `:` after it a bind, only right after an operand: `FROM t LIMIT:n`, `10 OFFSET:m`.
    private static let rowLimitKeywords: Set<String> = ["LIMIT", "OFFSET"]

    // An operand comes next after one of these, so a `limit` there is a column. `ALL` is one only after `SELECT`
    // (`LIMIT ALL OFFSET:m` is the clause) and `TOP n` is checked two tokens back.
    private static let operandStarters: Set<String> = operandKeywords.union([
        "AS", "BY", "CASE", "DISTINCT", "FROM", "ON", "QUALIFY", "RETURNING", "SET",
    ])

    private enum PrecedingToken {
        case operandStart
        case operandEnd
        case word(NSRange)
    }

    // A `:` written against the end of a name, a literal, a subscript, a call or another `:` is the engine's own
    // syntax: a cast (`a::int`), a path (`src:customer`), a slice (`arr[lo:hi]`), a typed slot (`{id:UInt32}`).
    // Against a keyword that takes an operand it is a bind.
    private static func scan(
        sql: String,
        grammar: SQLLexicalGrammar,
        onParameter: (_ name: String, _ range: NSRange) -> Void
    ) {
        let text = sql as NSString
        let length = text.length
        var index = 0
        var followsOperand = false
        var precedingToken = PrecedingToken.operandStart
        var tokenBeforePreceding = PrecedingToken.operandStart
        var wordStart: Int?
        var tokenBeforeWord = PrecedingToken.operandStart
        var tokenTwoBeforeWord = PrecedingToken.operandStart
        var wordFollowsPath = false

        func push(_ token: PrecedingToken) {
            tokenBeforePreceding = precedingToken
            precedingToken = token
        }

        func endWord(at end: Int) {
            guard let start = wordStart else { return }
            wordStart = nil
            push(.word(NSRange(location: start, length: end - start)))
        }

        func upperWord(_ range: NSRange) -> String {
            text.substring(with: range).uppercased()
        }

        func keywordBeforeTakesBind(colonAt colonIndex: Int) -> Bool {
            guard let start = wordStart, !wordFollowsPath else { return false }
            let word = upperWord(NSRange(location: start, length: colonIndex - start))
            if operandKeywords.contains(word) { return true }
            guard rowLimitKeywords.contains(word) else { return false }
            switch tokenBeforeWord {
            case .operandStart: return false
            case .operandEnd: return true
            case .word(let range):
                let previous = upperWord(range)
                if operandStarters.contains(previous) { return false }
                guard case .word(let earlierRange) = tokenTwoBeforeWord else { return true }
                let earlier = upperWord(earlierRange)
                return earlier != "TOP" && !(previous == "ALL" && earlier == "SELECT")
            }
        }

        while index < length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                endWord(at: index)
                index = max(span.end, index + 1)
                followsOperand = !span.kind.isComment
                if followsOperand { push(.operandEnd) }
                continue
            }
            let unit = text.character(at: index)
            if unit == colon, index + 1 < length, SqlDollarQuote.isIdentifierStart(text.character(at: index + 1)),
               !followsOperand || keywordBeforeTakesBind(colonAt: index) {
                var nameEnd = index + 2
                while nameEnd < length, SqlDollarQuote.isIdentifierPart(text.character(at: nameEnd)) {
                    nameEnd += 1
                }
                let name = text.substring(with: NSRange(location: index + 1, length: nameEnd - index - 1))
                onParameter(name, NSRange(location: index, length: nameEnd - index))
                index = nameEnd
                followsOperand = true
                wordStart = nil
                push(.operandEnd)
                continue
            }
            if SQLNonCodeSpan.isWordUnit(unit) {
                if wordStart == nil {
                    wordStart = index
                    tokenBeforeWord = precedingToken
                    tokenTwoBeforeWord = tokenBeforePreceding
                    // A path step (`src:in`, `t.limit`) or a typed slot's name (`{limit:UInt32}`) is never a keyword.
                    let before = index > 0 ? text.character(at: index - 1) : 0
                    wordFollowsPath = before == dot || before == colon || before == openBrace
                }
                followsOperand = true
            } else {
                endWord(at: index)
                let closes = unit == closeBracket || unit == SqlLexer.closeParen
                followsOperand = unit == colon || closes
                if closes {
                    push(.operandEnd)
                } else if !isSpace(unit) {
                    push(.operandStart)
                }
            }
            index += 1
        }
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit == 0x20 || (unit >= 0x09 && unit <= 0x0D) }
        return UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}
