import Foundation
import TableProSQLGrammar
import Testing

/// The statement count each engine's server produced for texts that hide a statement behind a lexical trick,
/// measured on 2026-09-19 against PostgreSQL 17.11, MySQL 8.4.11, MariaDB 11.8.9, Azure SQL Edge 15.0, DM8 V8,
/// Oracle 23.26, DuckDB 1.5.2 and SQLite 3.54 (`scripts/check-sql-lexical-grammar.sh` re-runs them). `executed` is
/// the count the execution grammar splits into, `plausible` the highest count any reading of the engine finds, which
/// is what a gate counts.
@Suite("SQL lexical corpus")
struct SQLLexicalCorpusTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let engine: String
        let sql: String
        let executed: Int
        let plausible: Int
        let measured: String

        var testDescription: String { "\(engine): \(measured)" }
    }

    static let backslash = "SELECT 'C:\\' AS p; DROP TABLE lexer_canary"
    static let nestedComment = "SELECT 1 /* /* */ ' */; DROP TABLE lexer_canary; --'"
    static let bracket = "SELECT [it's] FROM lexer_t; DROP TABLE lexer_canary; SELECT 'x'"
    static let dollar = "SELECT $$it's$$; DROP TABLE lexer_canary; SELECT 'x'"
    static let nonASCIITag = "SELECT $ü$it's$ü$; DROP TABLE lexer_canary; SELECT 'x'"
    static let escapeString = "SELECT E'\\''; DROP TABLE lexer_canary; --'"
    static let hashComment = "SELECT 1 # '\n; DROP TABLE lexer_canary; -- '"
    static let mySQLEscape = "SELECT 'a\\'; DROP TABLE lexer_canary; -- '"
    static let doubledBracket = "SELECT 1 AS [a]]'b]; DROP TABLE lexer_canary; SELECT 'x'"
    static let alternativeQuote = "SELECT q'[it's]' FROM dual; DROP TABLE lexer_canary; --'"
    static let doubleSlash = "SELECT 1 FROM DUAL // '\n; DELETE FROM lexer_canary; -- '"
    static let carriageReturn = "SELECT 1 -- x\r; DROP TABLE lexer_canary"
    static let tightDashes = "SELECT 1 --x; DROP TABLE lexer_canary"
    static let tclParameter = "SELECT $a('); DROP TABLE lexer_canary; --'"
    static let gluedDollars = "SELECT 1 AS x$$; DROP TABLE lexer_canary; --$$"
    static let gluedNonASCIIDollars = "SELECT 1 AS é$$; DROP TABLE lexer_canary; --$$"
    static let tripleQuote = "SELECT '''it's'''; DROP TABLE lexer_canary; SELECT 'x'"

    static let cases: [Case] = [
        Case(engine: "PostgreSQL", sql: backslash, executed: 2, plausible: 2, measured: "PQexec ran the DROP"),
        Case(engine: "DuckDB", sql: backslash, executed: 2, plausible: 2, measured: "duckdb_query ran the DROP"),
        Case(engine: "SQL Server", sql: backslash, executed: 2, plausible: 2, measured: "the batch ran the DROP"),
        Case(engine: "SQLite", sql: backslash, executed: 2, plausible: 2, measured: "sqlite3 ran the DROP"),
        Case(engine: "Dameng", sql: backslash, executed: 2, plausible: 2, measured: "DM8 ran the DELETE"),
        Case(engine: "Oracle", sql: backslash, executed: 2, plausible: 2, measured: "ORA-03405 at the ;"),
        Case(engine: "MySQL", sql: backslash, executed: 1, plausible: 2, measured: "one string, 2 with NO_BACKSLASH"),

        Case(engine: "PostgreSQL", sql: nestedComment, executed: 2, plausible: 2, measured: "comments nest"),
        Case(engine: "DuckDB", sql: nestedComment, executed: 2, plausible: 2, measured: "comments nest"),
        Case(engine: "SQL Server", sql: nestedComment, executed: 2, plausible: 2, measured: "comments nest"),
        Case(engine: "MySQL", sql: nestedComment, executed: 1, plausible: 1, measured: "flat, the DROP stayed"),
        Case(engine: "SQLite", sql: nestedComment, executed: 1, plausible: 1, measured: "flat, the DROP stayed"),
        Case(engine: "Oracle", sql: nestedComment, executed: 1, plausible: 1, measured: "flat"),
        Case(engine: "Dameng", sql: nestedComment, executed: 1, plausible: 1, measured: "flat"),

        Case(engine: "SQL Server", sql: bracket, executed: 3, plausible: 3, measured: "[it's] is an identifier"),
        Case(engine: "SQLite", sql: bracket, executed: 3, plausible: 3, measured: "[it's] is an identifier"),
        Case(engine: "PostgreSQL", sql: bracket, executed: 1, plausible: 1, measured: "a syntax error"),
        Case(engine: "ClickHouse", sql: bracket, executed: 1, plausible: 1, measured: "[ is an array"),

        Case(engine: "PostgreSQL", sql: dollar, executed: 3, plausible: 3, measured: "PQexec ran the DROP"),
        Case(engine: "DuckDB", sql: dollar, executed: 3, plausible: 3, measured: "duckdb_query ran the DROP"),
        Case(engine: "Snowflake", sql: dollar, executed: 3, plausible: 3, measured: "$$ body, from the reference"),
        Case(engine: "Cassandra", sql: dollar, executed: 3, plausible: 3, measured: "$$ body, from the reference"),
        Case(engine: "SQLite", sql: dollar, executed: 1, plausible: 1, measured: "$$ is not a quote"),
        Case(engine: "MySQL", sql: dollar, executed: 1, plausible: 3, measured: "8.4 refuses $$, 9 reads it"),

        Case(engine: "PostgreSQL", sql: nonASCIITag, executed: 3, plausible: 3, measured: "$ü$ is a tag"),
        Case(engine: "DuckDB", sql: nonASCIITag, executed: 3, plausible: 3, measured: "$ü$ is a tag"),
        Case(engine: "Snowflake", sql: nonASCIITag, executed: 1, plausible: 1, measured: "only $$ quotes"),

        Case(engine: "PostgreSQL", sql: escapeString, executed: 2, plausible: 2, measured: "E'\\'' ran the DROP"),
        Case(engine: "DuckDB", sql: escapeString, executed: 2, plausible: 2, measured: "E'\\'' ran the DROP"),
        Case(engine: "SQLite", sql: escapeString, executed: 1, plausible: 1, measured: "no E'' prefix"),

        Case(engine: "MySQL", sql: hashComment, executed: 2, plausible: 2, measured: "# is a comment"),
        Case(engine: "MariaDB", sql: hashComment, executed: 2, plausible: 2, measured: "# is a comment"),
        Case(engine: "PostgreSQL", sql: hashComment, executed: 1, plausible: 1, measured: "# is an operator"),

        Case(engine: "MySQL", sql: mySQLEscape, executed: 1, plausible: 2, measured: "one string by default"),
        Case(engine: "PostgreSQL", sql: mySQLEscape, executed: 2, plausible: 2, measured: "PQexec ran the DROP"),
        Case(engine: "SQL Server", sql: mySQLEscape, executed: 2, plausible: 2, measured: "the batch ran the DROP"),

        Case(engine: "SQL Server", sql: doubledBracket, executed: 3, plausible: 3, measured: "]] escapes"),
        Case(engine: "SQLite", sql: doubledBracket, executed: 1, plausible: 1, measured: "]] closes, the DROP stayed"),

        Case(engine: "Oracle", sql: alternativeQuote, executed: 2, plausible: 2, measured: "q'[it's]' is one literal"),
        Case(engine: "Dameng", sql: alternativeQuote, executed: 2, plausible: 2, measured: "DM8 ran the DELETE"),

        Case(engine: "Dameng", sql: doubleSlash, executed: 2, plausible: 2, measured: "// is a comment on DM8"),
        Case(engine: "Oracle", sql: doubleSlash, executed: 1, plausible: 1, measured: "// is not a comment"),

        Case(engine: "PostgreSQL", sql: carriageReturn, executed: 2, plausible: 2, measured: "CR ends --"),
        Case(engine: "SQL Server", sql: carriageReturn, executed: 2, plausible: 2, measured: "CR ends --"),
        Case(engine: "MySQL", sql: carriageReturn, executed: 1, plausible: 1, measured: "only LF ends --"),
        Case(engine: "SQLite", sql: carriageReturn, executed: 1, plausible: 1, measured: "only LF ends --"),

        Case(engine: "MySQL", sql: tightDashes, executed: 2, plausible: 2, measured: "--x is arithmetic"),
        Case(engine: "PostgreSQL", sql: tightDashes, executed: 1, plausible: 1, measured: "--x is a comment"),

        Case(engine: "SQLite", sql: tclParameter, executed: 2, plausible: 2, measured: "$a(') ran the DROP"),
        Case(engine: "PostgreSQL", sql: gluedDollars, executed: 2, plausible: 2, measured: "x$$ is an identifier"),
        Case(engine: "PostgreSQL", sql: gluedNonASCIIDollars, executed: 2, plausible: 2, measured: "é$$ ran the DROP"),
        Case(engine: "DuckDB", sql: gluedNonASCIIDollars, executed: 2, plausible: 2, measured: "é$$ ran the DROP"),

        Case(engine: "Spanner", sql: tripleQuote, executed: 3, plausible: 3, measured: "''' literal on GoogleSQL"),
        Case(engine: "BigQuery", sql: tripleQuote, executed: 3, plausible: 3, measured: "''' literal, from ZetaSQL"),
    ]

    @Test(arguments: cases)
    func splitsWhereTheEngineSplits(_ corpus: Case) throws {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: corpus.engine, declared: nil, session: nil)
        let executed = SQLStatementScanner.executableStatements(in: corpus.sql, grammar: readings.execution).count
        let plausible = readings.distinct(for: corpus.sql).map { grammar in
            SQLStatementScanner.executableStatements(in: corpus.sql, grammar: grammar).count
        }.max()
        #expect(executed == corpus.executed)
        #expect(plausible == corpus.plausible)
    }

    @Test("An engine TablePro does not know is counted under every grammar it does know")
    func unknownEngineTakesTheHighestCount() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        for sql in [Self.backslash, Self.nestedComment, Self.bracket, Self.dollar, Self.hashComment] {
            let counts = readings.distinct(for: sql).map { grammar in
                SQLStatementScanner.executableStatements(in: sql, grammar: grammar).count
            }
            #expect((counts.max() ?? 0) > 1, "\(sql)")
        }
    }
}
