import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

/// The foreign key preview built its own literal and doubled the quote by hand, which a
/// MySQL-family server does not read the way ANSI does: a backslash there escapes the quote that
/// follows it, so a value ending in one closes the literal and the rest of it is SQL.
@Suite("SQLBuilder single row lookup")
struct SQLBuilderSingleRowLookupTests {
    private func driver(backslashEscaping: Bool = false) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.usesBackslashEscaping = backslashEscaping
        return driver
    }

    @Test("A plain value reads as one statement against the named column")
    func plainValue() {
        #expect(
            SQLBuilder.buildSingleRowLookup(
                table: "parent", schema: nil, column: "code", value: "abc",
                type: .postgresql, driver: driver()
            ) == "SELECT * FROM \"parent\" WHERE \"code\" = 'abc' LIMIT 1 OFFSET 0"
        )
    }

    @Test("The schema is named, so the lookup cannot land on another schema's table")
    func schemaIsQualified() {
        #expect(
            SQLBuilder.buildSingleRowLookup(
                table: "parent", schema: "sales", column: "code", value: "abc",
                type: .mssql, driver: driver()
            ).hasPrefix("SELECT * FROM [sales].[parent] WHERE [code] = 'abc'")
        )
    }

    /// SQL Server and Oracle reject `LIMIT`, and the failure reads exactly like a key with no
    /// matching row.
    @Test("An OFFSET/FETCH engine gets its own clause")
    func offsetFetchEngines() {
        for type in [DatabaseType.mssql, .oracle] {
            let sql = SQLBuilder.buildSingleRowLookup(
                table: "parent", schema: nil, column: "code", value: "abc",
                type: type, driver: driver()
            )
            #expect(sql.contains("OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"))
            #expect(!sql.contains("LIMIT"))
        }
    }

    @Test("A quote in the value is escaped rather than closing the literal")
    func quoteIsEscaped() {
        #expect(
            SQLBuilder.buildSingleRowLookup(
                table: "parent", schema: nil, column: "code", value: "O'Brien",
                type: .postgresql, driver: driver()
            ).contains("= 'O''Brien'")
        )
    }

    /// The payload that used to break out: MySQL reads `\'` as an escaped quote, so doubling the
    /// quote alone ends the literal at the value's own backslash and runs the rest.
    @Test("A backslash before a quote cannot break out of the literal")
    func backslashCannotBreakOut() {
        let sql = SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: nil, column: "code", value: "a\\' OR 1=1 -- ",
            type: .mysql, driver: driver(backslashEscaping: true)
        )
        #expect(sql.contains("= 'a\\\\'' OR 1=1 -- '"))
        #expect(!sql.contains("'a\\'' OR"))
    }

    /// A lone trailing backslash is an ordinary value, a Windows path or a regex, and it used to
    /// leave the statement unterminated.
    @Test("A trailing backslash leaves the literal closed")
    func trailingBackslashIsEscaped() {
        let sql = SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: nil, column: "code", value: "C:\\",
            type: .mysql, driver: driver(backslashEscaping: true)
        )
        #expect(sql.contains("= 'C:\\\\'"))
    }

    @Test("Every escaped value goes through the driver, never a hand-written rule")
    func escapingFollowsTheDriver() {
        let value = "a\\b"
        let ansi = SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: nil, column: "code", value: value,
            type: .postgresql, driver: driver()
        )
        let backslash = SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: nil, column: "code", value: value,
            type: .mysql, driver: driver(backslashEscaping: true)
        )
        #expect(ansi.contains("= 'a\\b'"))
        #expect(backslash.contains("= 'a\\\\b'"))
    }
}
