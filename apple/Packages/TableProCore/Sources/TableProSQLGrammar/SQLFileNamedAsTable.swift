import Foundation

// DuckDB reads a file named as a table. A quoted identifier counts only with a `/`, a `.` or a `\`.
public enum SQLFileNamedAsTable {
    private static let tableIntroducers: Set<String> = [
        "FROM", "JOIN", "USING", "TABLE", "DESCRIBE", "DESC", "SHOW", "SUMMARIZE", "PIVOT", "UNPIVOT",
    ]

    // Reserved words, so none is the alias in `FROM notes AS n, 'payroll.csv'`.
    private static let tableListEnders: Set<String> = [
        "SELECT", "WHERE", "GROUP", "HAVING", "WINDOW", "QUALIFY", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT",
        "EXCEPT", "RETURNING", "DO",
    ]

    // `extract(year FROM '2026-01-01'::DATE)` separates arguments with FROM.
    private static let functionsTakingFrom: Set<String> = ["EXTRACT", "TRIM", "SUBSTRING", "OVERLAY"]

    private static let nameContinuations = Set(".:&".utf16)

    private static let pathMarks = CharacterSet(charactersIn: "/.\\")
    private static let period = UInt16(UnicodeScalar(".").value)

    private enum Expectation {
        case nothing
        case table
        case restOfName
    }

    private struct Parentheses {
        var separatesArgumentsWithFrom = false
        var listsTables = false
        var expects = Expectation.nothing
    }

    public static func appears(in statement: String, grammar: SQLLexicalGrammar) -> Bool {
        let source = statement as NSString
        let tokens = TSQLTokens.read(source, grammar: grammar)
        var levels = [Parentheses()]
        for (index, token) in tokens.enumerated() {
            let top = levels.count - 1
            let expected = levels[top].expects
            levels[top].expects = .nothing
            switch keyword(of: token, in: source) {
            case .word("FROM") where levels[top].separatesArgumentsWithFrom || comparesDistinct(before: index, in: tokens):
                break
            case .word(let word) where tableIntroducers.contains(word):
                levels[top].expects = .table
                if word == "FROM" { levels[top].listsTables = true }
            case .word(let word) where tableListEnders.contains(word) && expected != .table:
                levels[top].listsTables = false
            case .word("ONLY") where expected == .table:
                levels[top].expects = .table
            case .word, .name:
                if expected == .table { levels[top].expects = .restOfName }
            case .quoted:
                guard expected == .table else { break }
                if namesFile(at: token.location, in: source, grammar: grammar) { return true }
                levels[top].expects = .restOfName
            case .open:
                // `FROM (notes JOIN 'payroll.csv' USING (id))` groups tables, and any other `(` starts afresh.
                levels.append(
                    Parentheses(
                        separatesArgumentsWithFrom: callsFunctionTakingFrom(before: index, in: tokens, source: source),
                        expects: expected == .table ? .table : .nothing
                    )
                )
            case .close:
                if top > 0 { levels.removeLast() }
            case .comma:
                if levels[top].listsTables { levels[top].expects = .table }
            case .other:
                let continuesName = nameContinuations.contains(source.character(at: token.location))
                if expected == .restOfName, continuesName { levels[top].expects = .table }
            case .terminator:
                break
            }
        }
        return false
    }

    private static func comparesDistinct(before index: Int, in tokens: [TSQLTokens.Token]) -> Bool {
        guard index >= 2, tokens[index - 1].word == "DISTINCT" else { return false }
        return tokens[index - 2].word == "IS" || tokens[index - 2].word == "NOT"
    }

    // `INSERT INTO trim (FROM 'a.csv')` holds a query: a table may carry one of the names.
    private static func callsFunctionTakingFrom(
        before index: Int,
        in tokens: [TSQLTokens.Token],
        source: NSString
    ) -> Bool {
        guard index >= 1, functionsTakingFrom.contains(tokens[index - 1].word ?? "") else { return false }
        guard index >= 2 else { return true }
        let before = tokens[index - 2]
        return before.word != "INTO" && (before.kind != .other || source.character(at: before.location) != period)
    }

    // `SELECT 1_000FROM 'a.csv'` and `SELECT @1FROM 'a.csv'` reach FROM, since a number or an operator ends there.
    private static func keyword(of token: TSQLTokens.Token, in source: NSString) -> TSQLTokens.Token.Kind {
        guard let word = token.word else { return token.kind }
        let runsOn = token.location > 0 && SqlDollarQuote.isIdentifierPart(source.character(at: token.location - 1))
        guard runsOn || !SqlDollarQuote.isIdentifierStart(source.character(at: token.location)) else {
            return token.kind
        }
        return tableIntroducers.first(where: word.hasSuffix).map { .word($0) } ?? token.kind
    }

    private static func namesFile(at location: Int, in source: NSString, grammar: SQLLexicalGrammar) -> Bool {
        guard source.character(at: location) == SqlLexer.doubleQuote,
              let span = SQLNonCodeSpan.span(at: location, in: source, grammar: grammar)
        else {
            return true
        }
        let name = source.substring(with: NSRange(location: location, length: span.end - location))
        return name.rangeOfCharacter(from: pathMarks) != nil
    }
}
