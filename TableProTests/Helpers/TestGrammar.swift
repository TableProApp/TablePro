//
//  TestGrammar.swift
//  TableProTests
//

@testable import TablePro
import TableProSQLGrammar

/// The grammar each engine family a test names is split with, taken from the app's own resolver so a test reads
/// exactly what the editor reads.
enum TestGrammar {
    static let postgres = DatabaseType.postgresql.lexicalGrammar
    static let mysql = DatabaseType.mysql.lexicalGrammar
    static let sqlite = DatabaseType.sqlite.lexicalGrammar
    static let duckdb = DatabaseType.duckdb.lexicalGrammar
    static let oracle = DatabaseType.oracle.lexicalGrammar
    static let sqlServer = DatabaseType.mssql.lexicalGrammar
    static let snowflake = DatabaseType.snowflake.lexicalGrammar
    static let standard = SQLLexicalGrammar.ansi
}

/// A statement split with no engine named is standard SQL, which is what a test that does not care about an engine's
/// quirks means.
extension SQLStatementScanner {
    static func allStatements(in sql: String) -> [String] {
        allStatements(in: sql, grammar: TestGrammar.standard)
    }

    static func executableStatements(in sql: String) -> [ExecutableStatement] {
        executableStatements(in: sql, grammar: TestGrammar.standard)
    }

    static func allStatementsPreservingSemicolons(in sql: String) -> [String] {
        allStatementsPreservingSemicolons(in: sql, grammar: TestGrammar.standard)
    }

    static func locatedStatements(in sql: String) -> [LocatedStatement] {
        locatedStatements(in: sql, grammar: TestGrammar.standard)
    }

    static func navigableStatements(in sql: String) -> [LocatedStatement] {
        navigableStatements(in: sql, grammar: TestGrammar.standard)
    }

    static func statementAtCursor(in sql: String, cursorPosition: Int) -> String {
        statementAtCursor(in: sql, cursorPosition: cursorPosition, grammar: TestGrammar.standard)
    }

    static func locatedStatementAtCursor(in sql: String, cursorPosition: Int) -> LocatedStatement {
        locatedStatementAtCursor(in: sql, cursorPosition: cursorPosition, grammar: TestGrammar.standard)
    }

    static func statementStart(after offset: Int, in sql: String) -> Int? {
        statementStart(after: offset, in: sql, grammar: TestGrammar.standard)
    }

    static func statementStart(before offset: Int, in sql: String) -> Int? {
        statementStart(before: offset, in: sql, grammar: TestGrammar.standard)
    }

    static func statementSelectionEnd(after offset: Int, in sql: String) -> Int? {
        statementSelectionEnd(after: offset, in: sql, grammar: TestGrammar.standard)
    }
}

/// Autocomplete tests name no engine, so they read standard SQL like the rest.
extension SQLContextAnalyzer {
    func analyze(query: String, cursorPosition: Int) -> SQLContext {
        analyze(query: query, cursorPosition: cursorPosition, grammar: TestGrammar.standard)
    }
}

extension QueryStatementScanner {
    static func executableStatements(in text: String, model: QueryStatementModel) -> [SQLStatementScanner.ExecutableStatement] {
        executableStatements(in: text, model: model, grammar: TestGrammar.standard)
    }

    static func locatedStatements(in text: String, model: QueryStatementModel) -> [SQLStatementScanner.LocatedStatement] {
        locatedStatements(in: text, model: model, grammar: TestGrammar.standard)
    }

    static func navigableStatements(in text: String, model: QueryStatementModel) -> [SQLStatementScanner.LocatedStatement] {
        navigableStatements(in: text, model: model, grammar: TestGrammar.standard)
    }

    static func locatedStatementAtCursor(
        in text: String,
        cursorPosition: Int,
        model: QueryStatementModel
    ) -> SQLStatementScanner.LocatedStatement {
        locatedStatementAtCursor(in: text, cursorPosition: cursorPosition, model: model, grammar: TestGrammar.standard)
    }
}
