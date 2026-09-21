//
//  QueryClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

enum QueryTier: Sendable, Equatable {
    case safe
    case write
    case destructive
}

struct QueryClassification: Sendable, Equatable {
    let tier: QueryTier
    let reachesFilesystemOrExecutesCode: Bool

    static let safe = QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)

    func escalated(to other: QueryTier) -> QueryClassification {
        QueryClassification(
            tier: QueryClassification.worse(tier, other),
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode
        )
    }

    func markingUnsafeSurface() -> QueryClassification {
        QueryClassification(
            tier: QueryClassification.worse(tier, .write),
            reachesFilesystemOrExecutesCode: true
        )
    }

    func escalated(with other: QueryClassification) -> QueryClassification {
        QueryClassification(
            tier: QueryClassification.worse(tier, other.tier),
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode || other.reachesFilesystemOrExecutesCode
        )
    }

    static func worse(_ lhs: QueryTier, _ rhs: QueryTier) -> QueryTier {
        if lhs == .destructive || rhs == .destructive { return .destructive }
        if lhs == .write || rhs == .write { return .write }
        return .safe
    }
}

/// Tiers SQL text by what the engine will run, not by how the text starts.
///
/// A gate question is asked of the whole text under every way the engine could lex it (``SQLLexicalReadings``), and
/// each reading splits the text into the statements that engine would see before any of them is tiered. The answer
/// is the worst over all of them: the most severe tier, and more than one statement if any reading finds more than
/// one. A text that hides a `DROP` behind a quote only one reading closes is therefore tiered by that `DROP`.
enum QueryClassifier {
    static func classify(_ sql: String, databaseType: DatabaseType) -> QueryClassification {
        classify(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    static func classify(
        _ sql: String,
        databaseType: DatabaseType,
        readings: SQLLexicalReadings
    ) -> QueryClassification {
        let trimmed = StatementBlank.trimming(strippingLeadingComments(sql))
        guard !trimmed.isEmpty else { return .safe }
        if let redis = redisClassification(trimmed, databaseType: databaseType) { return redis }
        if let ledger = beancountClassification(trimmed, databaseType: databaseType) { return ledger }
        if let document = documentStoreClassification(trimmed, databaseType: databaseType) { return document }
        return readings.distinct(for: sql).reduce(QueryClassification.safe) { worst, grammar in
            statements(of: sql, grammar: grammar).reduce(worst) { partial, statement in
                partial.escalated(with: statementClassification(statement, grammar: grammar, databaseType: databaseType))
            }
        }
    }

    static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        classify(sql, databaseType: databaseType).tier != .safe
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        isDangerousQuery(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    static func isDangerousQuery(_ sql: String, databaseType: DatabaseType, readings: SQLLexicalReadings) -> Bool {
        let classification = classify(sql, databaseType: databaseType, readings: readings)
        if classification.tier == .destructive { return true }
        guard databaseType != .redis else { return false }
        let trimmed = StatementBlank.trimming(strippingLeadingComments(sql))
        guard documentStoreClassification(trimmed, databaseType: databaseType) == nil else {
            let code = SQLCodeProjection.code(of: trimmed, grammar: readings.execution).uppercased()
            return leadingKeyword(of: trimmed) == "DELETE" && !hasWhereClause(code: code)
        }
        return readings.distinct(for: sql).contains { grammar in
            statements(of: sql, grammar: grammar).contains { statement in
                statementDeletesEverything(statement, grammar: grammar)
            }
        }
    }

    static func classifyTier(_ sql: String, databaseType: DatabaseType) -> QueryTier {
        classify(sql, databaseType: databaseType).tier
    }

    static func reachesFilesystemOrExecutesCode(_ sql: String, databaseType: DatabaseType) -> Bool {
        classify(sql, databaseType: databaseType).reachesFilesystemOrExecutesCode
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        isMultiStatement(sql, databaseType: databaseType, readings: databaseType.lexicalReadings)
    }

    static func isMultiStatement(_ sql: String, databaseType: DatabaseType, readings: SQLLexicalReadings) -> Bool {
        let model = QueryStatementModel.forDatabaseType(databaseType)
        return readings.distinct(for: sql).contains { grammar in
            QueryStatementScanner.executableStatements(in: sql, model: model, grammar: grammar).count > 1
        }
    }

    /// The statements `grammar` splits `sql` into, as the driver would receive them.
    static func statements(of sql: String, grammar: SQLLexicalGrammar) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    private static func statementClassification(
        _ statement: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> QueryClassification {
        if runsPLSQL(statement, grammar: grammar) {
            return plsqlBlockClassification(statement, grammar: grammar, databaseType: databaseType)
        }
        return sqlClassification(statement, grammar: grammar, databaseType: databaseType)
    }

    private static func statementDeletesEverything(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        if runsPLSQL(statement, grammar: grammar) {
            return plsqlBlockDeletesEverything(statement, grammar: grammar)
        }
        let code = SQLCodeProjection.code(of: statement, grammar: grammar).uppercased()
        guard leadingCodeKeyword(code) == "DELETE" else { return false }
        return !hasWhereClause(code: code)
    }

    static func isExplainStatement(_ sql: String) -> Bool {
        let upper = strippingLeadingComments(sql).uppercased()
        return explainPrefixes.contains { prefix in
            guard upper.hasPrefix(prefix), let boundary = upper.dropFirst(prefix.count).first else {
                return false
            }
            return boundary == "(" || boundary.isWhitespace
        }
    }

    static func explainedStatement(in sql: String) -> String? {
        let trimmed = StatementBlank.trimming(strippingLeadingComments(sql))
        let keyword = leadingKeyword(of: trimmed)
        guard explainPrefixes.contains(keyword) else { return nil }
        return explainInnerStatement(trimmed, keyword: keyword)?.statement
    }

    /// A parenthesised query expression is idiomatic when each arm of a set operation carries its
    /// own ORDER BY, so the opening parens are skipped to reach the keyword that classifies the
    /// statement. Skipping cannot loosen the classification: an unrecognised keyword still falls to
    /// the write arm, and the body-wide filesystem and destructive scans run over the whole text.
    static func leadingKeyword(of sql: String) -> String {
        var remaining = strippingLeadingComments(sql)[...]
        while remaining.first == "(" {
            remaining = StatementBlank.trimmingLeading(remaining.dropFirst())
            guard remaining.hasPrefix("--") || remaining.hasPrefix("/*") else { continue }
            remaining = strippingLeadingComments(String(remaining))[...]
        }
        return remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }

    static func strippingLeadingComments(_ sql: String) -> String {
        var remaining = sql[...]
        while true {
            let trimmed = StatementBlank.trimmingLeading(remaining)
            if trimmed.hasPrefix("--") {
                guard let lineBreak = trimmed.firstIndex(where: endsLineComment) else { return "" }
                remaining = trimmed[trimmed.index(after: lineBreak)...]
            } else if trimmed.hasPrefix("/*"), !startsConditionalComment(trimmed) {
                guard let close = trimmed.range(of: "*/") else { return "" }
                remaining = trimmed[close.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }

    /// The first keyword of a code projection, past any opening parentheses.
    static func leadingCodeKeyword(_ code: String) -> String {
        let remaining = code.drop { StatementBlank.isBlank($0) || $0 == "(" }
        return remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
    }
}

private extension QueryClassifier {
    static let explainPrefixes: [String] = ["EXPLAIN", "ANALYZE"]

    static let whereClauseRegex = try? NSRegularExpression(pattern: "\\sWHERE\\s", options: [])

    static let destructiveKeywords: Set<String> = ["DROP", "TRUNCATE"]

    static let conditionalCommentOpeners: [String] = ["/*!", "/*M!"]

    static let lineCommentTerminators: Set<Character> = ["\n", "\r", "\r\n"]

    static let filesystemOrCodeKeywords: Set<String> = [
        "COPY", "ATTACH", "DETACH", "DO", "LOAD", "INSTALL", "IMPORT", "EXPORT",
        "BACKUP", "RESTORE", "DUMP", "SOURCE", "UNLOAD"
    ]

    static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT",
        "ALTER", "CREATE", "RENAME", "GRANT", "REVOKE", "COMMENT", "DENY",
        "CALL", "EXEC", "EXECUTE", "PREPARE", "DEALLOCATE",
        "SET", "RESET", "LOCK", "UNLOCK", "USE", "PRAGMA",
        "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECK",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "END", "ABORT",
        "DECLARE", "FETCH", "CLOSE", "MOVE", "DISCARD", "CHECKPOINT", "FLUSH",
        "KILL", "SHUTDOWN", "PURGE", "MSCK", "BATCH", "APPLY",
        "DEFINE", "REMOVE", "RELATE", "LET", "SECURITY", "LISTEN", "UNLISTEN", "NOTIFY"
    ]

    static let readOnlyKeywords: Set<String> = [
        "SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE",
        "HELP", "INFO", "PRINT", "EXPLAIN", "ANALYZE"
    ]

    static let statementStartKeywords: Set<String> = [
        "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "TABLE", "VALUES", "CALL", "EXECUTE", "COPY", "DO"
    ]

    static let filesystemMarkers: [String] = [
        "INTO OUTFILE", "INTO DUMPFILE", "TO PROGRAM", "FROM PROGRAM", "VACUUM INTO",
        "LOAD_FILE(", "PG_READ_FILE(", "PG_READ_BINARY_FILE(", "PG_LS_DIR(",
        "LO_IMPORT(", "LO_EXPORT(", "PG_FILE_WRITE(", "LOAD_EXTENSION(",
        "READFILE(", "WRITEFILE(", "FN_GET_AUDIT_FILE(", "XP_CMDSHELL", "SP_OACREATE"
    ]

    static func startsConditionalComment(_ text: Substring) -> Bool {
        conditionalCommentOpeners.contains { text.hasPrefix($0) }
    }

    static func endsLineComment(_ character: Character) -> Bool {
        lineCommentTerminators.contains(character)
    }

    static func hasWhereClause(code: String) -> Bool {
        let range = NSRange(code.startIndex..., in: code)
        return whereClauseRegex?.firstMatch(in: code, options: [], range: range) != nil
    }

    static func sqlClassification(
        _ statement: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> QueryClassification {
        let projection = StatementProjection(statement: statement, grammar: grammar)
        let body = projection.body
        let touchesUnsafeSurface = filesystemMarkers.contains { body.contains($0) }
        let base = keywordClassification(projection, grammar: grammar, databaseType: databaseType)
        var classification = touchesUnsafeSurface ? base.markingUnsafeSurface() : base
        if let dynamic = dynamicSQLClassification(projection, grammar: grammar, databaseType: databaseType) {
            classification = classification.escalated(with: dynamic)
        }
        guard let conditional = conditionalCommentClassification(statement, grammar: grammar) else {
            return classification
        }
        return classification.escalated(with: conditional)
    }

    /// A MySQL `/*! ... */` runs its body, so it is tiered by what the body says whatever the grammar thinks of it:
    /// reading a comment another engine ignores as code only ever raises the tier.
    static func conditionalCommentClassification(
        _ statement: String,
        grammar: SQLLexicalGrammar
    ) -> QueryClassification? {
        guard conditionalCommentOpeners.contains(where: { statement.contains($0) }) else { return nil }
        let revealed = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
            .uppercased()
        guard conditionalCommentOpeners.contains(where: { revealed.contains($0) }) else { return nil }
        let dropsData = destructiveKeywords.contains { containsWord(revealed, $0) }
        let reachesFilesystemOrExecutesCode = filesystemMarkers.contains { revealed.contains($0) }
            || filesystemOrCodeKeywords.contains { containsWord(revealed, $0) }
        return QueryClassification(
            tier: dropsData ? .destructive : .write,
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode
        )
    }

    static func keywordClassification(
        _ projection: StatementProjection,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> QueryClassification {
        let body = projection.body
        let keyword = leadingCodeKeyword(body)

        if keyword == "EXPLAIN" || keyword == "ANALYZE" {
            return explainClassification(projection, keyword: keyword, grammar: grammar, databaseType: databaseType)
        }

        if filesystemOrCodeKeywords.contains(keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }

        if destructiveKeywords.contains(keyword) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }

        if keyword == "ALTER" {
            let tier: QueryTier = body.range(of: " DROP ", options: .literal) != nil ? .destructive : .write
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }

        if keyword == "WITH" {
            return commonTableExpressionClassification(body)
        }

        if keyword == "SELECT" || keyword == "TABLE" || keyword == "VALUES" {
            guard containsWord(body, "INTO") else { return .safe }
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }

        if writeKeywords.contains(keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }

        if readOnlyKeywords.contains(keyword) {
            return .safe
        }

        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
    }

    private static let routineDefinitionKinds: Set<String> = [
        "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "PACKAGE", "TYPE", "EVENT", "BODY"
    ]

    /// Words that stand between `CREATE` and the kind it defines without saying what that kind is.
    private static let routineDefinitionFillers: Set<String> = [
        "OR", "REPLACE", "ALTER", "DEFINER", "EDITIONABLE", "NONEDITIONABLE", "AGGREGATE", "TEMP", "TEMPORARY",
        "GLOBAL", "PUBLIC", "SECURE", "SQL", "SECURITY", "SET", "SESSION"
    ]

    private static let routineDefinitionLookahead = 3

    static func commonTableExpressionClassification(_ body: String) -> QueryClassification {
        for keyword in ["DROP", "TRUNCATE"] where containsWord(body, keyword) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
        for keyword in ["INSERT", "UPDATE", "DELETE", "MERGE"] where containsWord(body, keyword) {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        return .safe
    }

    /// A routine's body is not run by the statement that stores it, so a definition is tiered by what storing it does,
    /// as #2988 settled for PL/SQL units: a write whose effect the text does not show.
    static func definesRoutine(_ code: String) -> Bool {
        var words = code.uppercased().split(whereSeparator: { !$0.isLetter && $0 != "_" }).makeIterator()
        guard let first = words.next(), first == "CREATE" || first == "ALTER" else { return false }
        var seen = 0
        while let word = words.next(), seen < routineDefinitionLookahead {
            if routineDefinitionKinds.contains(String(word)) { return true }
            if routineDefinitionFillers.contains(String(word)) { continue }
            seen += 1
        }
        return false
    }

    /// `EXECUTE IMMEDIATE` runs a statement written as a literal, and once a dollar-quoted body is one literal a
    /// keyword scan of the statement around it no longer sees what the body runs. So the literal is classified as SQL
    /// of its own, a `DROP` or `TRUNCATE` anywhere in it makes the statement destructive, and the statement carries
    /// the code flag, as PostgreSQL's `DO` does.
    static func dynamicSQLClassification(
        _ projection: StatementProjection,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard !definesRoutine(projection.code) else { return nil }
        let text = projection.statement as NSString
        guard let keywordEnd = executeImmediateEnd(in: projection.code as NSString) else { return nil }
        let literalStart = skipBlanks(in: text, from: keywordEnd)
        guard let span = SQLNonCodeSpan.span(at: literalStart, in: text, grammar: grammar), span.kind == .quoted else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }
        let dynamic = literalBody(of: span, in: text, grammar: grammar)
        let dynamicCode = SQLCodeProjection.code(of: dynamic, grammar: grammar).uppercased()
        let dropsData = destructiveKeywords.contains { containsWord(dynamicCode, $0) }
        let inner = classify(dynamic, databaseType: databaseType)
        return QueryClassification(
            tier: QueryClassification.worse(inner.tier, dropsData ? .destructive : .write),
            reachesFilesystemOrExecutesCode: true
        )
    }

    static let executeImmediateRegex = try? NSRegularExpression(
        pattern: #"\bEXECUTE\s+IMMEDIATE\b"#,
        options: [.caseInsensitive]
    )

    /// Where `EXECUTE IMMEDIATE` ends in the code projection. The literal after it is blank there, so it is found in
    /// the statement itself from this offset.
    static func executeImmediateEnd(in code: NSString) -> Int? {
        let whole = NSRange(location: 0, length: code.length)
        guard let match = executeImmediateRegex?.firstMatch(in: code as String, range: whole) else { return nil }
        return match.range.location + match.range.length
    }

    /// The text between a literal's delimiters: the body of `'...'`, `E'...'`, `$tag$...$tag$` or `q'[...]'`, with a
    /// doubled quote folded back to one.
    static func literalBody(of span: SQLNonCodeSpan.Span, in text: NSString, grammar: SQLLexicalGrammar) -> String {
        let opener = text.character(at: span.start)
        let bodyStart = min(literalBodyStart(of: span, opener: opener, in: text, grammar: grammar), span.contentEnd)
        let body = text.substring(with: NSRange(location: bodyStart, length: span.contentEnd - bodyStart))
        guard opener == SqlLexer.singleQuote || opener == SqlLexer.doubleQuote else { return body }
        let quote = opener == SqlLexer.singleQuote ? "'" : "\""
        return body.replacingOccurrences(of: quote + quote, with: quote)
    }

    static func literalBodyStart(
        of span: SQLNonCodeSpan.Span,
        opener: UInt16,
        in text: NSString,
        grammar: SQLLexicalGrammar
    ) -> Int {
        switch opener {
        case SqlDollarQuote.dollar:
            var cursor = span.start + 1
            while cursor < span.contentEnd, text.character(at: cursor) != SqlDollarQuote.dollar {
                cursor += 1
            }
            return cursor + 1
        case SqlLexer.singleQuote, SqlLexer.doubleQuote:
            let isTriple = grammar.contains(.tripleQuotedStrings)
                && SqlLexer.startsTripleQuote(text, at: span.start, length: text.length)
            return span.start + (isTriple ? 3 : 1)
        case SqlLexer.smallN, SqlLexer.capitalN:
            return span.start + 4
        case SqlLexer.smallQ, SqlLexer.capitalQ:
            return span.start + 3
        case escapeStringPrefixes.lower, escapeStringPrefixes.upper:
            return span.start + 2
        default:
            return span.start + 1
        }
    }

    static let escapeStringPrefixes = (lower: UInt16(UnicodeScalar("e").value), upper: UInt16(UnicodeScalar("E").value))

    /// EXPLAIN's options read off the code projection, where every comment is already blank, so a comment between
    /// the options and the statement ends where the engine ends it.
    static func explainedInnerStatement(
        _ projection: StatementProjection,
        keyword: String
    ) -> (statement: String, executesStatement: Bool)? {
        let code = projection.code as NSString
        let length = code.length
        var options = keyword == "ANALYZE" ? "ANALYZE" : ""
        var cursor = skipBlanks(in: code, from: codeOffset(ofKeyword: keyword, in: code))
        while cursor < length {
            let unit = code.character(at: cursor)
            if unit == SqlLexer.openParen {
                let end = closingParenthesis(in: code, from: cursor)
                options += " " + code.substring(with: NSRange(location: cursor, length: end - cursor)).uppercased()
                cursor = skipBlanks(in: code, from: end)
                continue
            }
            if unit == equalsSign || unit == comma {
                cursor = skipBlanks(in: code, from: cursor + 1)
                continue
            }
            let wordEnd = endOfWord(in: code, from: cursor)
            guard wordEnd > cursor else { return nil }
            let word = code.substring(with: NSRange(location: cursor, length: wordEnd - cursor)).uppercased()
            if statementStartKeywords.contains(word) {
                let statement = (projection.statement as NSString).substring(from: cursor)
                return (statement, options.contains("ANALYZE"))
            }
            options += " " + word
            cursor = skipBlanks(in: code, from: wordEnd)
        }
        return nil
    }

    static let equalsSign = UInt16(UnicodeScalar("=").value)
    static let comma = UInt16(UnicodeScalar(",").value)

    static func codeOffset(ofKeyword keyword: String, in code: NSString) -> Int {
        let start = skipBlanks(in: code, from: 0)
        return min(code.length, start + (keyword as NSString).length)
    }

    static func skipBlanks(in code: NSString, from offset: Int) -> Int {
        var cursor = offset
        while cursor < code.length, StatementBlank.blankLength(in: code, at: cursor) > 0 {
            cursor += StatementBlank.blankLength(in: code, at: cursor)
        }
        return cursor
    }

    static func endOfWord(in code: NSString, from offset: Int) -> Int {
        var cursor = offset
        while cursor < code.length, SqlDollarQuote.isIdentifierPart(code.character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    static func closingParenthesis(in code: NSString, from offset: Int) -> Int {
        var depth = 0
        var cursor = offset
        while cursor < code.length {
            let unit = code.character(at: cursor)
            if unit == SqlLexer.openParen { depth += 1 }
            if unit == SqlLexer.closeParen {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return cursor
    }
}

/// A statement beside its code projection, read once and handed to every rule that asks about it.
///
/// ``code`` keeps the statement's UTF-16 offsets, so a rule that finds a keyword in it can take text from the
/// statement at the same offset. ``body`` is the uppercased form for keyword matching, whose offsets may differ.
private struct StatementProjection {
    let statement: String
    let code: String
    let body: String

    init(statement: String, grammar: SQLLexicalGrammar) {
        self.statement = statement
        self.code = SQLCodeProjection.code(of: statement, grammar: grammar)
        self.body = code.uppercased()
    }
}

private extension QueryClassifier {
    static func explainClassification(
        _ projection: StatementProjection,
        keyword: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> QueryClassification {
        guard let inner = explainedInnerStatement(projection, keyword: keyword) else {
            let tier: QueryTier = keyword == "ANALYZE" ? .write : .safe
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }
        let innerClassification = sqlClassification(inner.statement, grammar: grammar, databaseType: databaseType)
        guard inner.executesStatement else {
            return QueryClassification(
                tier: .safe,
                reachesFilesystemOrExecutesCode: innerClassification.reachesFilesystemOrExecutesCode
            )
        }
        return innerClassification
    }

    static func explainInnerStatement(
        _ trimmed: String,
        keyword: String
    ) -> (statement: String, executesStatement: Bool)? {
        var remainder = Substring(trimmed).dropFirst(keyword.count)
        var options = keyword == "ANALYZE" ? "ANALYZE" : ""
        var statementTriviaStart: String.Index?
        while true {
            remainder = remainder.drop { $0.isWhitespace }
            guard let first = remainder.first else { return nil }
            if remainder.hasPrefix("--") {
                statementTriviaStart = statementTriviaStart ?? remainder.startIndex
                guard let lineBreak = remainder.firstIndex(where: endsLineComment) else { return nil }
                remainder = remainder[remainder.index(after: lineBreak)...]
                continue
            }
            if remainder.hasPrefix("/*") {
                statementTriviaStart = statementTriviaStart ?? remainder.startIndex
                guard let afterComment = remainderAfterBlockComment(in: remainder) else { return nil }
                remainder = afterComment
                continue
            }
            if first == "(" {
                statementTriviaStart = nil
                var depth = 0
                var index = remainder.startIndex
                while index < remainder.endIndex {
                    if remainder[index] == "(" { depth += 1 }
                    if remainder[index] == ")" {
                        depth -= 1
                        if depth == 0 {
                            index = remainder.index(after: index)
                            break
                        }
                    }
                    index = remainder.index(after: index)
                }
                options += " " + remainder[remainder.startIndex..<index].uppercased()
                remainder = remainder[index...]
                continue
            }
            let token = remainder.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !token.isEmpty else {
                if first == "=" || first == "," {
                    statementTriviaStart = nil
                    remainder = remainder.dropFirst()
                    continue
                }
                return nil
            }
            let upperToken = token.uppercased()
            if statementStartKeywords.contains(upperToken) {
                let statement = statementTriviaStart.map { trimmed[$0...] } ?? remainder
                return (String(statement), options.contains("ANALYZE"))
            }
            options += " " + upperToken
            statementTriviaStart = nil
            remainder = remainder.dropFirst(token.count)
        }
    }

    static func remainderAfterBlockComment(in sql: Substring) -> Substring? {
        var depth = 1
        var index = sql.index(sql.startIndex, offsetBy: 2)
        while index < sql.endIndex {
            let next = sql.index(after: index)
            guard next < sql.endIndex else { return nil }
            let pair = sql[index...next]
            if pair == "/*" {
                depth += 1
                index = sql.index(after: next)
            } else if pair == "*/" {
                depth -= 1
                let afterClose = sql.index(after: next)
                if depth == 0 { return sql[afterClose...] }
                index = afterClose
            } else {
                index = next
            }
        }
        return nil
    }

    static func containsWord(_ body: String, _ word: String) -> Bool {
        var searchRange = body.startIndex..<body.endIndex
        while let found = body.range(of: word, options: .literal, range: searchRange) {
            let beforeOk = found.lowerBound == body.startIndex
                || !isIdentifierCharacter(body[body.index(before: found.lowerBound)])
            let afterOk = found.upperBound == body.endIndex
                || !isIdentifierCharacter(body[found.upperBound])
            if beforeOk, afterOk { return true }
            guard found.upperBound < body.endIndex else { return false }
            searchRange = found.upperBound..<body.endIndex
        }
        return false
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private extension QueryClassifier {
    static let redisReadCommands: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "SUBSTR", "EXISTS", "TYPE", "TTL", "PTTL",
        "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE", "DUMP",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HRANDFIELD",
        "HSCAN", "HSTRLEN", "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SRANDMEMBER", "SSCAN",
        "SDIFF", "SINTER", "SUNION", "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT",
        "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XINFO", "XPENDING", "XAUTOCLAIM",
        "PFCOUNT", "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        "SORT_RO", "OBJECT", "COMMAND", "INFO", "TIME", "LASTSAVE", "PING", "ECHO", "LOLWUT",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "JSON.STRLEN",
        "TS.RANGE", "TS.REVRANGE", "TS.GET", "TS.MGET", "TS.INFO", "FT.SEARCH", "FT.INFO"
    ]

    static let redisDestructiveCommands: Set<String> = [
        "FLUSHDB", "FLUSHALL", "SHUTDOWN", "MIGRATE", "SWAPDB", "REPLICAOF", "SLAVEOF",
        "CLUSTER", "FAILOVER", "RESET"
    ]

    static let redisCodeExecutionCommands: Set<String> = [
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO",
        "FUNCTION", "SCRIPT", "MODULE", "DEBUG"
    ]

    static let redisFilesystemCommands: Set<String> = [
        "SAVE", "BGSAVE", "BGREWRITEAOF", "DEBUG"
    ]

    static func redisClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard databaseType == .redis else { return nil }
        guard let arguments = RedisArgumentCodec.split(trimmed) else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        let statement = redisCommandPastDatabasePrefix(arguments.map { String(bytes: $0, encoding: .utf8) ?? "" })
        guard let command = statement.first?.uppercased() else { return .safe }

        let touchesUnsafeSurface = redisCodeExecutionCommands.contains(command)
            || redisFilesystemCommands.contains(command)

        if command == "CONFIG" {
            let tier: QueryTier = statement.dropFirst().first?.uppercased() == "GET" ? .safe : .destructive
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }

        if redisDestructiveCommands.contains(command) || command == "DEBUG" {
            return QueryClassification(
                tier: .destructive,
                reachesFilesystemOrExecutesCode: touchesUnsafeSurface
            )
        }

        if redisReadCommands.contains(command) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)
        }

        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    /// `DB <index> <command>` runs the command on the database it names, so the command decides
    /// the tier: read as the bare `DB`, `DB 0 FLUSHDB` would pass as an ordinary write. A prefix
    /// with nothing after its index is left whole, which classifies as a write. The words are read
    /// the way the driver reads them, so a quoted `"FLUSHALL"` is the command it runs.
    static func redisCommandPastDatabasePrefix(_ words: [String]) -> ArraySlice<String> {
        var rest = words[...]
        while rest.first?.uppercased() == "DB", rest.count > 2 {
            rest = rest.dropFirst(2)
        }
        return rest
    }

    static let mongoReadMethods: Set<String> = [
        "find", "findone", "aggregate", "count", "countdocuments", "estimateddocumentcount",
        "distinct", "explain", "getindexes", "listindexes", "listcollections", "getcollectionnames",
        "getcollectioninfos", "stats", "totalsize", "datasize", "watch", "getindexkeys", "help",
        "hello", "ismaster", "serverstatus", "dbstats", "collstats", "validate", "getshardversion"
    ]

    static let mongoDestructiveMethods: Set<String> = [
        "drop", "dropdatabase", "dropindex", "dropindexes", "dropcollection", "deletemany",
        "removeall", "renamecollection"
    ]

    static let mongoCodeExecutionMarkers: [String] = [
        "$where", "$function", "$accumulator", "mapreduce", ".eval(", "$out", "$merge"
    ]

    /// Beancount answers BQL, whose statements (`SELECT`, `BALANCES`, `JOURNAL`, `PRINT`) only
    /// read, and the two `PRAGMA` forms its driver accepts. Anything else falls through to SQL.
    static func beancountClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        guard databaseType == .beancount else { return nil }
        let lowered = trimmed.lowercased()
        guard beancountReadPrefixes.contains(where: lowered.hasPrefix) else { return nil }
        return .safe
    }

    private static let beancountReadPrefixes = ["bql:", "bql ", "pragma table_info", "pragma database_list"]

    static func documentStoreClassification(
        _ trimmed: String,
        databaseType: DatabaseType
    ) -> QueryClassification? {
        switch databaseType {
        case .mongodb:
            return mongoClassification(trimmed)
        case .etcd:
            return etcdClassification(trimmed)
        case .elasticsearch:
            return elasticsearchClassification(trimmed)
        case .typesense:
            return typesenseClassification(trimmed)
        case .weaviate:
            return weaviateClassification(trimmed)
        default:
            return nil
        }
    }

    static func mongoClassification(_ trimmed: String) -> QueryClassification {
        let lowered = trimmed.lowercased()
        let touchesUnsafeSurface = mongoCodeExecutionMarkers.contains { lowered.contains($0) }
        let methods = invokedMethodNames(in: lowered)
        guard !methods.isEmpty else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if methods.contains(where: { mongoDestructiveMethods.contains($0) }) {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        let allRead = methods.allSatisfy { mongoReadMethods.contains($0) }
        let writesThroughPipeline = lowered.contains("$out") || lowered.contains("$merge")
        guard allRead, !writesThroughPipeline else {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    /// Every method a MongoDB statement invokes, by either spelling.
    ///
    /// The query language is JavaScript, so `db.users.deleteMany({})` and
    /// `db.users["deleteMany"]({})` are the same call. Reading only the dotted form let the bracket
    /// form past the destructive gate, which is what decides whether an external or assistant
    /// client has to confirm before it runs.
    static func invokedMethodNames(in lowered: String) -> [String] {
        dottedMethodNames(in: lowered) + bracketedMethodNames(in: lowered)
    }

    private static func dottedMethodNames(in lowered: String) -> [String] {
        var names: [String] = []
        var current = ""
        var sawDot = false
        for character in lowered {
            if character == "." {
                sawDot = true
                current = ""
                continue
            }
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                current.append(character)
                continue
            }
            if character == "(", sawDot, !current.isEmpty {
                names.append(current)
            }
            if !character.isWhitespace {
                sawDot = false
            }
            current = ""
        }
        return names
    }

    /// Names taken through bracket access, whether or not they are called on the spot.
    ///
    /// A name is counted even without a following `(`, because `var drop = db.c["drop"]; drop()`
    /// reaches the same command and no scan of the text can follow the binding.
    private static func bracketedMethodNames(in lowered: String) -> [String] {
        var names: [String] = []
        var index = lowered.startIndex

        while let open = lowered[index...].firstIndex(of: "[") {
            var cursor = lowered.index(after: open)
            while cursor < lowered.endIndex, lowered[cursor].isWhitespace {
                cursor = lowered.index(after: cursor)
            }
            guard cursor < lowered.endIndex, lowered[cursor] == "\"" || lowered[cursor] == "'" else {
                index = lowered.index(after: open)
                continue
            }
            let quote = lowered[cursor]
            var name = ""
            cursor = lowered.index(after: cursor)
            while cursor < lowered.endIndex, lowered[cursor] != quote {
                name.append(lowered[cursor])
                cursor = lowered.index(after: cursor)
            }
            if !name.isEmpty { names.append(name) }
            index = cursor < lowered.endIndex ? lowered.index(after: cursor) : lowered.endIndex
        }
        return names
    }

    static let etcdReadCommands: Set<String> = ["GET", "RANGE", "WATCH", "LIST", "STATUS", "VERSION", "ENDPOINT"]

    static func etcdClassification(_ trimmed: String) -> QueryClassification {
        let command = trimmed.prefix { !$0.isWhitespace }.uppercased()
        if command == "SNAPSHOT" || command == "DEFRAG" {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }
        if command == "DEL" || command == "DELETE" || command == "COMPACT" || command == "COMPACTION" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
        if etcdReadCommands.contains(command) {
            return .safe
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
    }

    static let elasticsearchReadPaths: [String] = [
        "_SEARCH", "_COUNT", "_MSEARCH", "_EXPLAIN", "_ANALYZE", "_FIELD_CAPS",
        "_VALIDATE", "_RENDER", "_MAPPING", "_SETTINGS", "_STATS", "_CAT", "_SQL"
    ]

    static func elasticsearchClassification(_ trimmed: String) -> QueryClassification {
        let upper = trimmed.uppercased()
        let verb = upper.prefix { !$0.isWhitespace }
        let touchesUnsafeSurface = upper.contains("_SCRIPTS") || upper.contains("_PAINLESS_EXECUTE")
        if verb == "GET" || verb == "HEAD" {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "POST", elasticsearchReadPaths.contains(where: { upper.contains($0) }) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "DELETE" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    static let typesenseReadPaths: [String] = ["/MULTI_SEARCH", "/DOCUMENTS/SEARCH", "/DOCUMENTS/EXPORT"]

    /// `/operations/snapshot` writes the whole dataset to a server path the request names, and
    /// `/keys` mints API keys, so both widen reach beyond the data the request touches.
    static let typesenseUnsafePaths: [String] = ["/OPERATIONS/SNAPSHOT", "/KEYS"]

    /// The verb and the path, and nothing else. A Typesense console request is one header line
    /// followed by a JSON body, and the body is the caller's data: scanning the whole statement
    /// let `POST /collections/c/documents/import` carrying `"note": "/multi_search"` in a field
    /// read as a search, which is a read-only mode and MCP gate bypass. A URL path holds no raw
    /// space, so the path ends at the first one: that keeps a body written on the header line out
    /// of it, and stops `POST /collections/c /multi_search` from ending in a read path.
    static func typesenseRequestLine(_ trimmed: String) -> (verb: String, path: String) {
        let header = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let verb = parts.first else { return ("", "/") }
        guard parts.count == 2 else { return (String(verb).uppercased(), "/") }

        var path = parts[1].trimmingCharacters(in: .whitespaces)
        for marker in ["?", "#"] {
            if let stop = path.range(of: marker) {
                path = String(path[..<stop.lowerBound])
            }
        }
        path = String(path.prefix { !$0.isWhitespace })
        if !path.hasPrefix("/") { path = "/" + path }
        return (String(verb).uppercased(), path.uppercased())
    }

    static func typesenseClassification(_ trimmed: String) -> QueryClassification {
        let (verb, path) = typesenseRequestLine(trimmed)
        let touchesUnsafeSurface = typesenseUnsafePaths.contains { path == $0 || path.hasPrefix("\($0)/") }
        if verb == "GET" || verb == "HEAD" {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "POST", typesenseReadPaths.contains(where: { path == $0 || path.hasSuffix($0) }) {
            return QueryClassification(tier: .safe, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        if verb == "DELETE" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: touchesUnsafeSurface)
    }

    /// A bare operation, a `{"query": ...}` envelope and a console body are the same request, and
    /// the driver forwards the envelope verbatim, so the read-only gate has to read all three.
    static func weaviateDeclaresMutation(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("mutation") {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String
        else { return false }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("mutation")
    }

    /// The driver takes a body from the rest of the request line as well as from the lines below
    /// it, so the gate has to read the same two places.
    static func weaviateConsoleBody(_ trimmed: String) -> String {
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = lines.first.map(String.init) ?? ""
        let following = lines.count > 1 ? String(lines[1]) : ""
        let parts = header.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        let inline = parts.count > 2 ? String(parts[2]) : ""
        return inline.isEmpty ? following : inline
    }

    static func weaviateClassification(_ trimmed: String) -> QueryClassification {
        if trimmed.hasPrefix("WEAVIATE_SEARCH:") {
            return .safe
        }
        if trimmed.hasPrefix("WEAVIATE_WRITE:") {
            let encoded = String(trimmed.dropFirst("WEAVIATE_WRITE:".count))
            if let data = Data(base64Encoded: encoded),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["method"] as? String)?.uppercased() == "DELETE" {
                return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
            }
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("mutation") {
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        }
        if trimmed.hasPrefix("{") || lowered.hasPrefix("query") || lowered.hasPrefix("fragment") {
            return weaviateDeclaresMutation(trimmed)
                ? QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
                : .safe
        }
        let (verb, path) = typesenseRequestLine(trimmed)
        if verb == "GET" || verb == "HEAD" {
            return .safe
        }
        if verb == "POST", path == "/V1/GRAPHQL" {
            return weaviateDeclaresMutation(weaviateConsoleBody(trimmed))
                ? QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
                : .safe
        }
        if verb == "DELETE" {
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
        if verb.isEmpty {
            return .safe
        }
        return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
    }
}
