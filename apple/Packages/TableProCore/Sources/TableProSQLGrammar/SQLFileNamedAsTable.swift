import Foundation

// DuckDB reads a file named as a table. A quoted identifier, in `"` or a backtick, counts only with a `/`, a `.` or a
// `\`. So does a dotted name ending in a file extension, and a table function DuckDB does not keep inside the database.
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

    // Only a FROM or JOIN list holds table functions; PIVOT's and USING's parentheses hold expressions.
    private static let callingIntroducers: Set<String> = ["FROM", "JOIN"]

    // An allowlist: an extension DuckDB loads on its own brings table functions no list here knows.
    static let tableFunctionsInsideDatabase: Set<String> = [
        "RANGE", "GENERATE_SERIES", "UNNEST", "REPEAT", "JSON_EACH", "JSON_TREE", "DUCKDB_COLUMNS",
        "DUCKDB_CONSTRAINTS", "DUCKDB_DATABASES", "DUCKDB_DEPENDENCIES", "DUCKDB_FUNCTIONS", "DUCKDB_INDEXES",
        "DUCKDB_KEYWORDS", "DUCKDB_SCHEMAS", "DUCKDB_SEQUENCES", "DUCKDB_SETTINGS", "DUCKDB_TABLES", "DUCKDB_TYPES",
        "DUCKDB_VARIABLES", "DUCKDB_VIEWS", "PRAGMA_DATABASE_SIZE", "PRAGMA_PLATFORM", "PRAGMA_SHOW",
        "PRAGMA_STORAGE_INFO", "PRAGMA_TABLE_INFO", "PRAGMA_VERSION",
    ]

    // DuckDB joins a dotted table name with `.` and reads it as a file in the working folder.
    static let fileExtensions: Set<String> = [
        "CSV", "TSV", "GZ", "ZST", "PARQUET", "JSON", "JSONL", "NDJSON", "GEOJSON", "GEOJSONL", "DB", "DDB", "DUCKDB",
    ]

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
        var introducer = ""
        var nameParts = 0
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
                levels[top].introducer = word
                levels[top].nameParts = 0
                if word == "FROM" { levels[top].listsTables = true }
            case .word(let word) where tableListEnders.contains(word) && expected != .table:
                levels[top].listsTables = false
            case .word("ONLY") where expected == .table, .word("LATERAL") where expected == .table:
                levels[top].expects = .table
            case .word(let word):
                guard expected == .table else { break }
                levels[top].nameParts += 1
                if levels[top].nameParts > 1, fileExtensions.contains(word) { return true }
                levels[top].expects = .restOfName
            case .name:
                if expected == .table { levels[top].expects = .restOfName }
            case .quoted:
                guard expected == .table else { break }
                if namesFile(at: token.location, in: source, grammar: grammar) { return true }
                levels[top].nameParts += 1
                let quotedName = identifier(at: token.location, in: source, grammar: grammar)?.uppercased()
                if levels[top].nameParts > 1, let quotedName, fileExtensions.contains(quotedName) { return true }
                levels[top].expects = .restOfName
            case .open:
                if expected == .restOfName, callingIntroducers.contains(levels[top].introducer),
                   !callsTableFunctionInsideDatabase(before: index, in: tokens, source: source, grammar: grammar) {
                    return true
                }
                // `FROM (notes JOIN 'payroll.csv' USING (id))` groups tables, and any other `(` starts afresh.
                levels.append(
                    Parentheses(
                        separatesArgumentsWithFrom: callsFunctionTakingFrom(before: index, in: tokens, source: source),
                        expects: expected == .table ? .table : .nothing,
                        introducer: expected == .table ? levels[top].introducer : ""
                    )
                )
            case .close:
                if top > 0 { levels.removeLast() }
            case .comma:
                if levels[top].listsTables {
                    levels[top].expects = .table
                    levels[top].nameParts = 0
                }
            case .other:
                let mark = source.character(at: token.location)
                if expected == .restOfName, nameContinuations.contains(mark) {
                    levels[top].expects = .table
                    if mark != period { levels[top].nameParts = 0 }
                }
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

    // A name the scanner cannot read counts as unknown.
    private static func callsTableFunctionInsideDatabase(
        before index: Int,
        in tokens: [TSQLTokens.Token],
        source: NSString,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        guard index >= 1 else { return false }
        let callee = tokens[index - 1]
        let name: String? = switch callee.kind {
        case .word(let word): word
        case .quoted: identifier(at: callee.location, in: source, grammar: grammar)?.uppercased()
        default: nil
        }
        guard let name else { return false }
        return name == "VALUES" || tableFunctionsInsideDatabase.contains(name)
    }

    private static func identifier(at location: Int, in source: NSString, grammar: SQLLexicalGrammar) -> String? {
        guard [SqlLexer.doubleQuote, SqlLexer.backtick].contains(source.character(at: location)),
              let span = SQLNonCodeSpan.span(at: location, in: source, grammar: grammar)
        else {
            return nil
        }
        return source.substring(with: NSRange(location: location + 1, length: max(0, span.contentEnd - location - 1)))
    }

    private static func namesFile(at location: Int, in source: NSString, grammar: SQLLexicalGrammar) -> Bool {
        guard [SqlLexer.doubleQuote, SqlLexer.backtick].contains(source.character(at: location)),
              let span = SQLNonCodeSpan.span(at: location, in: source, grammar: grammar)
        else {
            return true
        }
        let name = source.substring(with: NSRange(location: location, length: span.end - location))
        return name.rangeOfCharacter(from: pathMarks) != nil
    }
}
