//
//  SnowflakeSQLTests.swift
//  TableProTests
//
//  Tests for SnowflakeSQL (compiled via symlink from SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake SQL Escaping")
struct SnowflakeSQLTests {
    // MARK: - Literals

    @Test("A quote is doubled")
    func testQuoteDoubling() {
        #expect(SnowflakeSQL.escapeLiteral("O'Brien") == "O''Brien")
        #expect(SnowflakeSQL.escapeLiteral("''") == "''''")
    }

    /// Snowflake reads `\'` inside a literal as a content quote, so an escaper that doubles the
    /// quote and leaves the backslash alone lets a name close the literal and run its own SQL.
    @Test("A backslash is doubled so it cannot escape the closing quote")
    func testBackslashDoubling() {
        #expect(SnowflakeSQL.escapeLiteral("a\\b") == "a\\\\b")
        #expect(SnowflakeSQL.escapeLiteral("\\") == "\\\\")
    }

    /// The payload works against a quote-only escaper: it becomes `x\'' OR 1=1 --`, Snowflake reads
    /// `\'` as a content quote, the next quote closes the literal, and `OR 1=1` runs. Doubling the
    /// backslash first leaves the quote with nothing to escape it.
    @Test("A backslash-quote injection payload stays inside the literal")
    func testInjectionPayloadIsNeutralised() {
        let escaped = SnowflakeSQL.escapeLiteral("x\\' OR 1=1 --")
        #expect(escaped == "x\\\\'' OR 1=1 --")

        let quoteOnly = "x\\' OR 1=1 --".replacingOccurrences(of: "'", with: "''")
        #expect(quoteOnly == "x\\'' OR 1=1 --")
        #expect(escaped != quoteOnly)
    }

    @Test("The backslash is doubled before the quotes, not after")
    func testEscapeOrder() {
        #expect(SnowflakeSQL.escapeLiteral("'") == "''")
        #expect(SnowflakeSQL.escapeLiteral("\\'") == "\\\\''")
    }

    @Test("An ordinary value is untouched")
    func testPlainLiteral() {
        #expect(SnowflakeSQL.escapeLiteral("PUBLIC") == "PUBLIC")
        #expect(SnowflakeSQL.escapeLiteral("") == "")
    }

    // MARK: - Identifiers

    @Test("An identifier is wrapped and its quotes doubled")
    func testIdentifierQuoting() {
        #expect(SnowflakeSQL.quoteIdentifier("orders") == "\"orders\"")
        #expect(SnowflakeSQL.quoteIdentifier("we\"ird") == "\"we\"\"ird\"")
        #expect(SnowflakeSQL.quoteIdentifier("a\".\"b") == "\"a\"\".\"\"b\"")
    }

    @Test("An identifier that tries to close its own quoting cannot")
    func testIdentifierInjectionIsNeutralised() {
        let quoted = SnowflakeSQL.quoteIdentifier("t\" ; DROP TABLE x; --")
        #expect(quoted == "\"t\"\" ; DROP TABLE x; --\"")
    }

    // MARK: - LIKE patterns

    @Test("LIKE wildcards in a name are escaped")
    func testLikePattern() {
        #expect(SnowflakeSQL.escapeLikePattern("my_table") == "my\\\\_table")
        #expect(SnowflakeSQL.escapeLikePattern("100%") == "100\\\\%")
    }

    @Test("A LIKE pattern escapes its literal first")
    func testLikePatternEscapesLiteralToo() {
        #expect(SnowflakeSQL.escapeLikePattern("O'Brien") == "O''Brien")
    }

    // MARK: - One owner

    /// Every statement builder in the plugin routes here. These pin that the wrappers stayed
    /// wrappers, because three copies of this logic drifting apart is what shipped the injection.
    @Test("The schema query wrappers delegate to the shared escaper")
    func testSchemaQueriesDelegate() {
        #expect(SnowflakeSchemaQueries.escapeLiteral("x\\'") == SnowflakeSQL.escapeLiteral("x\\'"))
        #expect(SnowflakeSchemaQueries.quote("we\"ird") == SnowflakeSQL.quoteIdentifier("we\"ird"))
        #expect(
            SnowflakeSchemaQueries.escapeLikePattern("my_t") == SnowflakeSQL.escapeLikePattern("my_t")
        )
    }

    @Test("The routine queries escape a schema name that carries a backslash")
    func testRoutineListEscapesSchema() {
        let sql = SnowflakeObjectQueries.routineList(schema: "x\\' OR 1=1 --")
        #expect(sql.contains("x\\\\'' OR 1=1 --"))
        #expect(!sql.contains("x\\' OR"))
    }
}
