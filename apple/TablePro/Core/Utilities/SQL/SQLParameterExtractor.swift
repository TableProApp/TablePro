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
                values.append(param.isNull ? nil : param.value)
            } else {
                values.append(nil)
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
    private static let closeBracket = UInt16(UnicodeScalar("]").value)

    // A `:` written against the end of a name, a literal, a subscript, a call or another `:` is the engine's own
    // syntax: a cast (`a::int`), a path (`src:customer`), a slice (`arr[lo:hi]`), a typed slot (`{id:UInt32}`).
    private static func scan(
        sql: String,
        grammar: SQLLexicalGrammar,
        onParameter: (_ name: String, _ range: NSRange) -> Void
    ) {
        let text = sql as NSString
        let length = text.length
        var index = 0
        var followsOperand = false

        while index < length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                index = max(span.end, index + 1)
                followsOperand = !span.kind.isComment
                continue
            }
            let unit = text.character(at: index)
            if unit == colon, !followsOperand, index + 1 < length,
               SqlDollarQuote.isIdentifierStart(text.character(at: index + 1)) {
                var nameEnd = index + 2
                while nameEnd < length, SqlDollarQuote.isIdentifierPart(text.character(at: nameEnd)) {
                    nameEnd += 1
                }
                let name = text.substring(with: NSRange(location: index + 1, length: nameEnd - index - 1))
                onParameter(name, NSRange(location: index, length: nameEnd - index))
                index = nameEnd
                followsOperand = true
                continue
            }
            followsOperand = unit == colon || unit == closeBracket || unit == SqlLexer.closeParen
                || SQLNonCodeSpan.isWordUnit(unit)
            index += 1
        }
    }
}
