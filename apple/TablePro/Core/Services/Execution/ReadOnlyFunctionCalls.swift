//
//  ReadOnlyFunctionCalls.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// What Read-Only needs to know about a connection before it lets a read call a function.
internal struct ReadOnlyFunctionPolicy: Sendable, Equatable {
    // The live driver cannot run a statement in the engine's read-only mode, and a function on this engine can write.
    var functionsCanWrite = false
    // A configuration profile or the connection's floor holds it at Read-Only, so no answer may let a write through.
    var levelIsHeld = false
}

// The one place that says which calls Read-Only lets through without asking, on an engine whose functions can write and
// a driver that cannot hold the statement to the engine's read-only mode. A built-in here reads only: nothing that
// writes, locks, sleeps, waits or reaches a file (GET_LOCK, SLEEP, LOAD_FILE, NEXTVAL, SETVAL, a DBMS_ package) is listed.
// A qualified or quoted name, a name the scanner cannot read, and anything else may be a function the user wrote. A
// call written without parentheses, which Oracle and Dameng accept for a function with no arguments, cannot be told
// from a column and is not seen.
internal enum ReadOnlyFunctionCalls {
    static let commonBuiltins: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "STDDEV", "STDDEV_POP", "STDDEV_SAMP", "VARIANCE", "VAR_POP", "VAR_SAMP",
        "CORR", "COVAR_POP", "COVAR_SAMP", "GROUPING",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE", "LAG", "LEAD", "FIRST_VALUE",
        "LAST_VALUE", "NTH_VALUE",
        "COALESCE", "NULLIF", "GREATEST", "LEAST", "CAST", "EXTRACT",
        "LOWER", "UPPER", "LENGTH", "TRIM", "LTRIM", "RTRIM", "SUBSTR", "SUBSTRING", "REPLACE", "CONCAT", "LPAD", "RPAD",
        "REVERSE", "ASCII", "REGEXP_REPLACE", "REGEXP_SUBSTR", "REGEXP_INSTR", "REGEXP_LIKE", "POSITION", "TRANSLATE",
        "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "MOD", "POWER", "SQRT", "EXP", "LN", "LOG", "SIGN", "SIN", "COS",
        "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP",
        "JSON_VALUE", "JSON_QUERY", "JSON_OBJECT", "JSON_ARRAY", "JSON_TABLE",
    ]

    // Oracle and Dameng.
    static let oracleBuiltins: Set<String> = [
        "NVL", "NVL2", "DECODE", "LNNVL", "NANVL", "LISTAGG", "MEDIAN", "RATIO_TO_REPORT",
        "TO_CHAR", "TO_DATE", "TO_NUMBER", "TO_TIMESTAMP", "TO_TIMESTAMP_TZ", "TO_DSINTERVAL", "TO_YMINTERVAL",
        "NUMTODSINTERVAL", "NUMTOYMINTERVAL", "TO_NCHAR", "HEXTORAW", "RAWTOHEX", "ROWIDTOCHAR", "CONVERT",
        "INSTR", "INSTRB", "LENGTHB", "SUBSTRB", "INITCAP", "CHR", "SOUNDEX", "REGEXP_COUNT",
        "TRUNC", "BITAND", "WIDTH_BUCKET", "REMAINDER",
        "ADD_MONTHS", "MONTHS_BETWEEN", "LAST_DAY", "NEXT_DAY", "NEW_TIME", "FROM_TZ", "TZ_OFFSET", "SYS_EXTRACT_UTC",
        "SYS_GUID", "SYS_CONTEXT", "USERENV", "ORA_HASH", "STANDARD_HASH", "XMLTABLE",
    ]

    // MySQL, MariaDB and the servers that answer as MySQL.
    static let mysqlBuiltins: Set<String> = [
        "IF", "IFNULL", "ISNULL", "GROUP_CONCAT", "JSON_ARRAYAGG", "JSON_OBJECTAGG", "BIT_AND", "BIT_OR", "BIT_XOR",
        "ANY_VALUE", "CONVERT",
        "CONCAT_WS", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "BIT_LENGTH", "LCASE", "UCASE", "LEFT", "RIGHT",
        "MID", "LOCATE", "INSTR", "FIND_IN_SET", "FIELD", "ELT", "STRCMP", "SUBSTRING_INDEX", "REPEAT", "SPACE", "CHAR",
        "FORMAT", "QUOTE", "SOUNDEX", "HEX", "UNHEX", "BIN", "OCT", "CONV",
        "TRUNCATE", "POW", "LOG2", "LOG10", "COT", "DEGREES", "RADIANS", "PI", "RAND", "CRC32",
        "NOW", "SYSDATE", "CURDATE", "CURTIME", "LOCALTIME", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "DATE", "TIME",
        "TIMESTAMP", "YEAR", "QUARTER", "MONTH", "WEEK", "WEEKDAY", "WEEKOFYEAR", "YEARWEEK", "DAY", "DAYOFMONTH",
        "DAYOFWEEK", "DAYOFYEAR", "DAYNAME", "MONTHNAME", "HOUR", "MINUTE", "SECOND", "MICROSECOND", "DATE_FORMAT",
        "TIME_FORMAT", "STR_TO_DATE", "DATE_ADD", "DATE_SUB", "ADDDATE", "SUBDATE", "ADDTIME", "SUBTIME", "DATEDIFF",
        "TIMEDIFF", "TIMESTAMPDIFF", "TIMESTAMPADD", "UNIX_TIMESTAMP", "FROM_UNIXTIME", "FROM_DAYS", "TO_DAYS",
        "TO_SECONDS", "SEC_TO_TIME", "TIME_TO_SEC", "MAKEDATE", "MAKETIME", "PERIOD_ADD", "PERIOD_DIFF", "LAST_DAY",
        "CONVERT_TZ",
        "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_CONTAINS", "JSON_CONTAINS_PATH", "JSON_KEYS", "JSON_LENGTH", "JSON_TYPE",
        "JSON_VALID", "JSON_SEARCH", "JSON_DEPTH",
        "MD5", "SHA", "SHA1", "SHA2", "UUID", "UUID_SHORT",
        "DATABASE", "SCHEMA", "USER", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "VERSION", "CONNECTION_ID",
    ]

    // An older PostgreSQL-family driver without the mode.
    static let postgresBuiltins: Set<String> = [
        "NOW", "TO_CHAR", "TO_DATE", "TO_NUMBER", "TO_TIMESTAMP", "DATE_TRUNC", "DATE_PART", "AGE", "TRUNC", "LEFT",
        "RIGHT", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "SPLIT_PART", "STRING_AGG", "ARRAY_AGG",
        "ARRAY_LENGTH", "INITCAP", "CHR", "MD5", "FORMAT", "CONCAT_WS", "TO_JSON", "TO_JSONB", "JSON_AGG", "JSONB_AGG",
        "JSON_BUILD_OBJECT", "JSONB_BUILD_OBJECT", "JSON_BUILD_ARRAY", "JSONB_BUILD_ARRAY", "GENERATE_SERIES",
        "BOOL_AND", "BOOL_OR", "EVERY", "POW", "LOG10", "PI", "RANDOM",
    ]

    private static let oracleFamily: Set<DatabaseType> = [.oracle, .dameng]
    private static let mysqlFamily: Set<DatabaseType> = [.mysql, .mariadb, .oceanbase, .tidb, .starrocks, .databend]
    private static let postgresFamily: Set<DatabaseType> = [.postgresql, .cockroachdb, .pglite, .kingbasees, .redshift]

    private static let oracleCalls = commonBuiltins.union(oracleBuiltins)
    private static let mysqlCalls = commonBuiltins.union(mysqlBuiltins)
    private static let postgresCalls = commonBuiltins.union(postgresBuiltins)
    private static let anyCalls = commonBuiltins.union(oracleBuiltins).union(mysqlBuiltins).union(postgresBuiltins)

    static func builtins(for databaseType: DatabaseType) -> Set<String> {
        if oracleFamily.contains(databaseType) { return oracleCalls }
        if mysqlFamily.contains(databaseType) { return mysqlCalls }
        if postgresFamily.contains(databaseType) { return postgresCalls }
        return anyCalls
    }

    // Reserved in Oracle, MySQL and PostgreSQL alike, so no function a query calls can carry the bare name.
    static let reservedWords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS", "AS", "ON", "WITH", "GROUP", "ORDER", "HAVING",
        "UNION", "DISTINCT", "ELSE", "THEN", "ALL", "VALUES", "BETWEEN", "TABLE",
    ]

    // A word another engine lets a user function carry stands before a parenthesis only in this syntax.
    private enum Syntax {
        // Right after a call's closing parenthesis: `SUM(x) OVER (`.
        case afterCall
        // After a call, opening with this word: `COUNT(*) FILTER (WHERE`, `MAX(x) KEEP (DENSE_RANK`.
        case afterCallOpening(String)
        // After one of these words: `GROUP BY (`, `GROUPING SETS (`, `USE INDEX (`.
        case afterWord(Set<String>)
        // After a name, a literal or a closing parenthesis: `t PARTITION (`, `x LIKE (`, `) EXCEPT (`.
        case afterOperand
        // Opening with one of these words: `ARRAY(SELECT`, `LATERAL (SELECT`.
        case opening(Set<String>)
        // After a comparison: `= ANY (`.
        case afterComparison
        // Its parenthesized part followed by one of these words: `MATCH (a) AGAINST`, `INTERVAL (n) DAY`.
        case followedBy(Set<String>)
    }

    private static let intervalUnits: Set<String> = [
        "MICROSECOND", "SECOND", "MINUTE", "HOUR", "DAY", "WEEK", "MONTH", "QUARTER", "YEAR",
    ]

    private static let syntax: [String: [Syntax]] = [
        "BY": [.afterWord(["GROUP", "ORDER", "PARTITION", "CONNECT"])],
        "OVER": [.afterCall],
        "FILTER": [.afterCallOpening("WHERE")],
        "KEEP": [.afterCallOpening("DENSE_RANK")],
        "AGAINST": [.afterCall],
        "MATCH": [.followedBy(["AGAINST"])],
        "INTERVAL": [.followedBy(intervalUnits)],
        "CASE": [.followedBy(["WHEN"])],
        "WHEN": [.afterOperand, .afterWord(["CASE"])],
        "PARTITION": [.afterOperand],
        "PIVOT": [.afterOperand],
        "UNPIVOT": [.afterOperand],
        "CUBE": [.afterWord(["BY"])],
        "ROLLUP": [.afterWord(["BY"])],
        "SETS": [.afterWord(["GROUPING"])],
        "ARRAY": [.opening(["SELECT", "WITH"])],
        "LATERAL": [.opening(["SELECT", "WITH"])],
        "ANY": [.afterComparison],
        "SOME": [.afterComparison],
        "JOIN": [.afterOperand, .afterWord(["INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "FOR"])],
        "USING": [.afterOperand],
        "INDEX": [.afterWord(["USE", "FORCE", "IGNORE"])],
        "KEY": [.afterWord(["USE", "FORCE", "IGNORE"])],
        "LIKE": [.afterOperand],
        "IS": [.afterOperand],
        "INTERSECT": [.afterOperand],
        "EXCEPT": [.afterOperand],
        "MINUS": [.afterOperand],
        "LIMIT": [.afterOperand],
        "OFFSET": [.afterOperand],
        // Word operators: `10 DIV (2)`, `a XOR (b)`.
        "DIV": [.afterOperand],
        "XOR": [.afterOperand],
        "REGEXP": [.afterOperand],
        "RLIKE": [.afterOperand],
        "ILIKE": [.afterOperand],
        "ESCAPE": [.afterOperand],
    ]

    // After one of these a call can start, so a word that follows it is not standing after an operand. Word operators
    // are among them: `10 DIV pivot(1)` calls `pivot`.
    private static let introducers: Set<String> = reservedWords.union(syntax.keys).union([
        "SET", "INTO", "RETURN", "RETURNING", "PRIOR", "CALL", "DO", "EXECUTE", "FOR", "CONNECT",
        "MOD", "COLLATE", "BINARY", "UNIQUE", "SOUNDS", "MEMBER", "OF", "SIMILAR", "TO", "ASC", "DESC", "NULLS",
    ])

    private static let openParenthesis = UInt16(UnicodeScalar("(").value)
    private static let closeParenthesis = UInt16(UnicodeScalar(")").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let quoteOpeners: Set<UInt16> = [0x22, 0x60, 0x5B]
    private static let comparisons: Set<UInt16> = [0x3D, 0x3C, 0x3E, 0x21]

    // Under every way the engine could lex the text, as the classifier reads it. A type with a length, such as
    // `DECIMAL(10, 2)` in a cast, is the engine's own type, not a call.
    static func callsUnlistedFunction(_ sql: String, databaseType: DatabaseType) -> Bool {
        let typeNames = Set(
            (PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?.dataTypes ?? [])
                .map { $0.uppercased() }
        )
        let known = builtins(for: databaseType)
        return databaseType.lexicalReadings.all.contains { grammar in
            SQLStatementClassifier.statements(of: sql, grammar: grammar).contains { statement in
                statementCallsUnlistedFunction(statement, grammar: grammar, builtins: known, typeNames: typeNames)
            }
        }
    }

    private static func statementCallsUnlistedFunction(
        _ statement: String,
        grammar: SQLLexicalGrammar,
        builtins: Set<String>,
        typeNames: Set<String>
    ) -> Bool {
        // A plain EXPLAIN plans its statement without running it.
        if let explain = SQLExplainStatement.read(statement, grammar: grammar) {
            switch explain.reading {
            case .describesObject, .explains(_, false):
                return false
            case .explains(_, true), .unreadable:
                break
            }
        }
        let source = statement as NSString
        let code = SQLCodeProjection.code(of: statement, grammar: grammar) as NSString
        var quoted: [Range<Int>]?
        return SQLFunctionCallScanner.calls(in: source, code: code).contains { call in
            guard case .named(let name, let start) = call.callee,
                  !quoteOpeners.contains(source.character(at: start))
            else { return true }
            let word = name.uppercased()
            switch qualifier(before: start, in: code) {
            case .member:
                return true
            case .cast:
                return !typeNames.contains(word)
            case .unqualified:
                break
            }
            if builtins.contains(word) || typeNames.contains(word) || reservedWords.contains(word) { return false }
            guard let rules = syntax[word] else { return true }
            let spans = quoted ?? quotedSpans(in: source, grammar: grammar)
            quoted = spans
            let site = CallSite(code: code, quotedSpans: spans, nameStart: start, parenthesis: call.parenthesis)
            return !rules.contains { site.matches($0) }
        }
    }

    // Where a literal or a quoted name sits. The projection blanks comments too, and a comment is not a token.
    private static func quotedSpans(in source: NSString, grammar: SQLLexicalGrammar) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var index = 0
        while index < source.length {
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) else {
                index += 1
                continue
            }
            if span.kind == .quoted { spans.append(span.start..<span.end) }
            index = max(span.end, index + 1)
        }
        return spans
    }

    private enum Qualifier {
        case unqualified
        // `schema.name(`, `package.name(`.
        case member
        // PostgreSQL's `value::numeric(10, 2)`.
        case cast
    }

    private static func qualifier(before start: Int, in code: NSString) -> Qualifier {
        var cursor = start - 1
        while cursor >= 0, SQLFunctionCallScanner.isBlank(code.character(at: cursor)) {
            cursor -= 1
        }
        guard cursor >= 0 else { return .unqualified }
        let unit = code.character(at: cursor)
        if unit == period { return .member }
        guard unit == colon else { return .unqualified }
        return cursor > 0 && code.character(at: cursor - 1) == colon ? .cast : .member
    }

    private enum Neighbor: Equatable {
        case start
        case word(String)
        case symbol(UInt16)
        // A literal or a quoted name, which the projection blanked.
        case quoted
    }

    private struct CallSite {
        let code: NSString
        let quotedSpans: [Range<Int>]
        let nameStart: Int
        let parenthesis: Int

        func matches(_ rule: Syntax) -> Bool {
            switch rule {
            case .afterCall:
                return before == .symbol(ReadOnlyFunctionCalls.closeParenthesis)
            case .afterCallOpening(let word):
                return before == .symbol(ReadOnlyFunctionCalls.closeParenthesis) && firstWord(after: parenthesis) == word
            case .afterWord(let words):
                guard case .word(let word) = before else { return false }
                return words.contains(word)
            case .afterOperand:
                switch before {
                case .quoted:
                    return true
                case .symbol(let unit):
                    return unit == ReadOnlyFunctionCalls.closeParenthesis
                case .word(let word):
                    return !ReadOnlyFunctionCalls.introducers.contains(word)
                case .start:
                    return false
                }
            case .opening(let words):
                return firstWord(after: parenthesis).map { words.contains($0) } ?? false
            case .afterComparison:
                guard case .symbol(let unit) = before else { return false }
                return ReadOnlyFunctionCalls.comparisons.contains(unit)
            case .followedBy(let words):
                return wordAfterGroup().map { words.contains($0) } ?? false
            }
        }

        private var before: Neighbor {
            var cursor = nameStart - 1
            while cursor >= 0, SQLFunctionCallScanner.isBlank(code.character(at: cursor)) {
                if quotedSpans.contains(where: { $0.contains(cursor) }) { return .quoted }
                cursor -= 1
            }
            guard cursor >= 0 else { return .start }
            let unit = code.character(at: cursor)
            guard SQLFunctionCallScanner.isIdentifierUnit(unit) else { return .symbol(unit) }
            var start = cursor
            while start > 0, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: start - 1)) {
                start -= 1
            }
            return .word(code.substring(with: NSRange(location: start, length: cursor - start + 1)).uppercased())
        }

        private func firstWord(after index: Int) -> String? {
            var cursor = index + 1
            while cursor < code.length, SQLFunctionCallScanner.isBlank(code.character(at: cursor)) {
                cursor += 1
            }
            var end = cursor
            while end < code.length, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: end)) {
                end += 1
            }
            guard end > cursor else { return nil }
            return code.substring(with: NSRange(location: cursor, length: end - cursor)).uppercased()
        }

        private func wordAfterGroup() -> String? {
            var depth = 0
            for index in parenthesis..<code.length {
                let unit = code.character(at: index)
                if unit == ReadOnlyFunctionCalls.openParenthesis {
                    depth += 1
                } else if unit == ReadOnlyFunctionCalls.closeParenthesis {
                    depth -= 1
                    if depth == 0 { return firstWord(after: index) }
                }
            }
            return nil
        }
    }
}

// Export, Transfer To, Data Compare and Copy Objects read rows outside the editor, so text the user wrote into them, a
// row filter or the query an export runs again, meets the gate's Read-Only decision before any row is read.
internal enum ReadOnlyReadGate {
    @MainActor
    static func authorize(
        _ statements: [String],
        connectionId: UUID,
        databaseType: DatabaseType,
        gate: any ExecutionGate,
        operationDescription: String = String(localized: "Export"),
        canPrompt: Bool = true,
        manager: DatabaseManager? = nil
    ) async throws {
        guard !statements.isEmpty, ExecutionGateProvider.runsAtReadOnly(connectionId, in: manager) else { return }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: statements.joined(separator: ";\n"),
                kind: .readQuery,
                caller: .userInterface,
                capabilities: canPrompt ? .interactiveUser : CallerCapabilities.interactiveUser.union(.cannotPrompt),
                operationDescription: operationDescription,
                statements: statements
            )
        )
        if let denial = decision.denialError { throw denial }
    }

    // The read each filtered object runs, in the form the gate reads it.
    static func rowScopeStatements(
        _ objects: [ExportObjectItem],
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> [String] {
        objects.compactMap { object in
            filterStatement(
                table: object.name,
                schema: object.databaseName,
                filter: object.rowScope.sanitizedFilter,
                databaseType: databaseType,
                quote: quote
            )
        }
    }

    static func filterStatement(
        table: String,
        schema: String?,
        filter: String?,
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> String? {
        guard let filter, !filter.isEmpty else { return nil }
        let name = SchemaQualifiedName.render(name: table, schema: schema, databaseType: databaseType, quote: quote)
        return "SELECT * FROM \(name) WHERE \(filter)"
    }
}
