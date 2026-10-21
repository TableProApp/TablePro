import Foundation
import TableProModels
import TableProRedisCore
import TableProSQLGrammar

/// Decides whether a statement batch writes, so Safe Mode can block or confirm it.
///
/// The rule is fail-closed: a statement counts as a read only when its leading keyword is one of a
/// short, closed set of read verbs. Everything else writes, including a keyword this classifier has
/// never heard of. A write-keyword allowlist cannot be safe, because anything it has not been
/// taught, or anything hidden behind a leading comment, runs unguarded.
///
/// The batch is split into statements the way its engine lexes it, by the grammar the Mac reads
/// too, and under every reading the engine could be using: the run splits by one reading, and a
/// `DELETE` hidden behind a quote that only another reading closes still reaches the server. On an
/// engine that needs no `;`, every statement that begins inside one is read as well, because SQL
/// Server runs `SELECT 1` followed by `DROP TABLE t` as two statements.
public enum SQLWriteClassifier {
    /// `EXPLAIN` and `PRAGMA` are deliberately absent: `EXPLAIN ANALYZE DELETE …` runs the delete on
    /// PostgreSQL, and `PRAGMA journal_mode = WAL` writes on SQLite and DuckDB.
    private static let readKeywords: Set<String> = ["SHOW", "DESCRIBE", "DESC"]

    /// A `SELECT` reads unless it materialises a table, which `SELECT … INTO` does on SQL Server and
    /// `SELECT … INTO OUTFILE` does on MySQL. Mirrors QueryClassifier.swift:288-291.
    private static let readUnlessIntoKeywords: Set<String> = ["SELECT", "TABLE", "VALUES"]

    /// Statement verbs only. `REPLACE`, `INTO` and `COPY` are left out because they collide with
    /// ordinary function and column names, and a CTE that merely calls `replace()` is a read.
    /// Matches QueryClassifier.swift:304-312.
    private static let writeKeywordsInsideCTE: [String] = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "DROP", "TRUNCATE", "ALTER", "CREATE", "INTO"
    ]

    public static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        if databaseType == .redis {
            return RedisCommandSplitter.commands(in: sql).contains { redisWrites($0.text) }
        }
        let readings = SQLLexicalReadings.resolve(databaseTypeId: databaseType.rawValue, declared: nil, session: nil)
        return readings.distinct(for: sql).contains { grammar in
            SQLStatementScanner.executableStatements(in: sql, grammar: grammar).contains { statement in
                SQLUnterminatedStatements.runnable(in: statement.sql, grammar: grammar).contains { runnable in
                    statementWrites(runnable, grammar: grammar)
                }
            }
        }
    }

    /// Reads the statement's code with every literal and comment blanked by its engine's own rules. A MySQL
    /// `/*! ... */` is kept as the code it is, so a keyword the server runs from one is never mistaken for a read.
    private static func statementWrites(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        let code = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
        let body = String(code.drop { $0.isWhitespace })
        guard let keyword = leadingKeyword(of: body) else { return true }
        if keyword == "WITH" { return commonTableExpressionWrites(code) }
        if readUnlessIntoKeywords.contains(keyword) {
            return containsWord("INTO", in: code.uppercased())
        }
        return !readKeywords.contains(keyword)
    }

    // Read as the driver reads it, so a quoted verb is the command that runs. Unparseable text counts as a write.
    private static func redisWrites(_ command: String) -> Bool {
        guard let arguments = RedisArgumentCodec.split(command) else { return true }
        let words = arguments.map { String(bytes: $0, encoding: .utf8) ?? "" }
        return !RedisReadCommands.onlyReads(words[...])
    }

    /// A CTE's leading keyword says nothing about what the statement finally does, so its code is
    /// searched for a write verb.
    private static func commonTableExpressionWrites(_ code: String) -> Bool {
        let masked = code.uppercased()
        return writeKeywordsInsideCTE.contains { keyword in
            containsWord(keyword, in: masked)
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
