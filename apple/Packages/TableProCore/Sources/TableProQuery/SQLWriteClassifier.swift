import Foundation
import TableProModels
import TableProPluginKit
import TableProRedisCore
import TableProSQLGrammar

/// Decides whether a statement batch writes, so Safe Mode can block or confirm it.
///
/// The rule is fail-closed: a statement counts as a read only when its leading keyword is one of a
/// short, closed set of read verbs. Everything else writes, including a keyword this classifier has
/// never heard of. A write-keyword allowlist cannot be safe, because anything it has not been
/// taught, or anything hidden behind a leading comment, runs unguarded. A query that passes the verb
/// rule is then read for what it calls, because `SELECT setval('seq', 1)` and
/// `SELECT pg_terminate_backend(pid)` open with a read verb and change state all the same.
///
/// The batch is split into statements the way its engine lexes it, by the grammar the Mac reads
/// too, and under every reading the engine could be using: the run splits by one reading, and a
/// `DELETE` hidden behind a quote that only another reading closes still reaches the server. Each
/// MySQL server version that skips a different set of `/*!` comments is one more reading. On an
/// engine that needs no `;`, every statement that begins inside one is read as well, because SQL
/// Server runs `SELECT 1` followed by `DROP TABLE t` as two statements.
public enum SQLWriteClassifier {
    // EXPLAIN and PRAGMA are absent: `EXPLAIN ANALYZE DELETE …` runs the delete on PostgreSQL, and
    // `PRAGMA journal_mode = WAL` writes on SQLite and DuckDB.
    private static let readKeywords: Set<String> = ["SHOW"]

    // MySQL and TiDB read `DESC ANALYZE DELETE …` as EXPLAIN ANALYZE, so only a DESCRIBE of a name reads.
    private static let describeKeywords: Set<String> = ["DESCRIBE", "DESC"]

    // `SELECT … INTO` materialises a table on SQL Server and a file on MySQL.
    private static let readUnlessIntoKeywords: Set<String> = ["SELECT", "TABLE", "VALUES"]

    // `REPLACE` and `COPY` are left out because they are also function and column names.
    private static let writeKeywordsInsideCTE: [String] = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "DROP", "TRUNCATE", "ALTER", "CREATE", "INTO"
    ]

    /// `NEXT VALUE FOR seq` (SQL Server, MariaDB, Db2) and `NEXTVAL FOR seq` (Db2) advance a sequence with
    /// no call for the function scanner to see. Matches QueryClassifier.sequenceAdvanceRegex.
    private static let sequenceAdvanceRegex = try? NSRegularExpression(
        pattern: "\\bNEXT(?:\\s+VALUE|VAL)\\s+FOR\\b",
        options: []
    )

    /// `seq.NEXTVAL` does the same on the engines that have the pseudo-column. Elsewhere `t.nextval` is a column.
    private static let sequencePseudoColumnRegex = try? NSRegularExpression(
        pattern: "\\.\\s*NEXTVAL\\b",
        options: []
    )

    /// QueryClassifier.enginesWithSequencePseudoColumns without SAP HANA, which only the Mac connects to.
    private static let enginesWithSequencePseudoColumns: Set<DatabaseType> = [.oracle, .snowflake, .dameng, .mariadb]

    public static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        if databaseType == .redis {
            return RedisCommandSplitter.commands(in: sql).contains { redisWrites($0.text) }
        }
        if databaseType == .mongodb {
            let verdict = MongoStatementClassifier.verdict(
                sql, shadowsCollection: MongoCollectionAccessor.isShadowedByDatabaseMember
            )
            return verdict.tier != .read
        }
        let readings = SQLLexicalReadings.resolve(databaseTypeId: databaseType.rawValue, declared: nil, session: nil)
        guard let lexings = readings.lexings(of: sql) else { return true }
        var seen: Set<SQLLexing> = []
        return lexings.contains { lexing in
            SQLStatementScanner.executableStatements(in: lexing.text, grammar: lexing.grammar).contains { statement in
                SQLUnterminatedStatements.runnable(in: statement.sql, grammar: lexing.grammar).contains { runnable in
                    seen.insert(SQLLexing(grammar: lexing.grammar, text: runnable)).inserted
                        && statementWrites(runnable, grammar: lexing.grammar, databaseType: databaseType)
                }
            }
        }
    }

    /// Reads the statement's code with every literal and comment blanked by its engine's own rules. A MySQL
    /// `/*! ... */` is kept as the code it is, so a keyword the server runs from one is never mistaken for a read.
    private static func statementWrites(
        _ statement: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType,
        depth: Int = 0
    ) -> Bool {
        // Each nested CTE copies and reads what is left of the text, so nesting past this counts as a write.
        guard depth <= 32 else { return true }
        let code = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
        let body = String(code.drop { $0.isWhitespace || $0 == "(" })
        guard let keyword = leadingKeyword(of: body) else { return true }
        if keyword == "WITH" {
            return commonTableExpressionWrites(
                statement, code: code, grammar: grammar, databaseType: databaseType, depth: depth
            )
                || queryChangesState(statement, code: code, grammar: grammar, databaseType: databaseType)
        }
        if describeKeywords.contains(keyword) {
            return SQLExplainStatement.read(statement, grammar: grammar)?.reading != .describesObject
        }
        if readUnlessIntoKeywords.contains(keyword) {
            return containsWord("INTO", in: code.uppercased())
                || queryChangesState(statement, code: code, grammar: grammar, databaseType: databaseType)
        }
        return !readKeywords.contains(keyword)
    }

    /// A query's verb says nothing about what it calls: a function in the select list can move a sequence,
    /// end a session or drop a large object. A callee the scanner cannot name counts as one that changes
    /// state. Mirrors QueryClassifier.stateChangingCallTier.
    private static func queryChangesState(
        _ statement: String,
        code: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> Bool {
        if advancesSequence(code.uppercased(), databaseType: databaseType) { return true }
        let callsChangeState = SQLFunctionCallScanner.calls(in: statement as NSString, code: code as NSString)
            .contains { call in
                guard case .named(let name, _) = call.callee else { return true }
                return SQLStateChangingFunctions.contains(name)
            }
        return callsChangeState || SQLStateChangingFunctions.namesStateChangingTable(in: statement, grammar: grammar)
    }

    private static func advancesSequence(_ body: String, databaseType: DatabaseType) -> Bool {
        let range = NSRange(body.startIndex..., in: body)
        if sequenceAdvanceRegex?.firstMatch(in: body, options: [], range: range) != nil { return true }
        guard enginesWithSequencePseudoColumns.contains(databaseType) else { return false }
        return sequencePseudoColumnRegex?.firstMatch(in: body, options: [], range: range) != nil
    }

    // Read as the driver reads it, so a quoted verb is the command that runs. Unparseable text counts as a write.
    private static func redisWrites(_ command: String) -> Bool {
        guard let arguments = RedisArgumentCodec.split(command) else { return true }
        let words = arguments.map { String(bytes: $0, encoding: .utf8) ?? "" }
        return !RedisReadCommands.onlyReads(words[...])
    }

    // After the CTE list only a query reads, and each body is read as a statement of its own.
    private static func commonTableExpressionWrites(
        _ statement: String,
        code: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType,
        depth: Int
    ) -> Bool {
        let masked = code.uppercased()
        if writeKeywordsInsideCTE.contains(where: { containsWord($0, in: masked) }) { return true }
        guard let list = SQLCommonTableExpressions.read(statement, grammar: grammar) else { return true }
        let text = statement as NSString
        let main = text.substring(from: list.mainStatement)
        let mainCode = SQLCodeProjection.code(of: main, grammar: grammar)
        guard readUnlessIntoKeywords.contains(SQLLeadingComments.leadingCodeKeyword(mainCode)) else { return true }
        return ([main] + list.bodies.map(text.substring(with:))).contains { part in
            statementWrites(part, grammar: grammar, databaseType: databaseType, depth: depth + 1)
        }
    }

    private static func containsWord(_ word: String, in haystack: String) -> Bool {
        let characters = Array(haystack)
        let needle = Array(word)
        guard characters.count >= needle.count else { return false }
        for start in 0...(characters.count - needle.count) {
            guard Array(characters[start ..< start + needle.count]) == needle else { continue }
            let before = start > 0 ? characters[start - 1] : " "
            let afterIndex = start + needle.count
            let after = afterIndex < characters.count ? characters[afterIndex] : " "
            if !isIdentifierCharacter(before) && !isIdentifierCharacter(after) { return true }
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func leadingKeyword(of statement: String) -> String? {
        var keyword = ""
        for character in statement {
            if isIdentifierCharacter(character) {
                keyword.append(character)
            } else {
                break
            }
        }
        return keyword.isEmpty ? nil : keyword.uppercased()
    }
}
