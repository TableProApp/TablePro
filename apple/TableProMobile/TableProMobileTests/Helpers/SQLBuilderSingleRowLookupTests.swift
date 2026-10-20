import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

struct SQLBuilderSingleRowLookupTests {
    private func driver(backslashEscaping: Bool = false) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.usesBackslashEscaping = backslashEscaping
        return driver
    }

    private func lookup(
        _ key: [(column: String, value: String)],
        schema: String? = nil,
        type: DatabaseType = .postgresql,
        backslashEscaping: Bool = false
    ) -> String {
        SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: schema, key: key,
            type: type, driver: driver(backslashEscaping: backslashEscaping)
        )
    }

    @Test("A plain value reads as one statement against the named column")
    func plainValue() {
        #expect(lookup([("code", "abc")]) == "SELECT * FROM \"parent\" WHERE \"code\" = 'abc' LIMIT 1 OFFSET 0")
    }

    @Test("A composite key matches every pair, so another tenant's row cannot answer")
    func compositeKeyMatchesEveryPair() {
        #expect(
            lookup([("tenant_id", "2"), ("id", "5")])
                == "SELECT * FROM \"parent\" WHERE \"tenant_id\" = '2' AND \"id\" = '5' LIMIT 1 OFFSET 0"
        )
    }

    @Test("Every pair of a composite key goes through the driver's escaper")
    func compositeKeyEscapesEveryValue() {
        let sql = lookup([("a", "x\\"), ("b", "O'Brien")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("WHERE `a` = 'x\\\\' AND `b` = 'O''Brien'"))
    }

    @Test("An empty key matches no row rather than any row")
    func emptyKeyMatchesNothing() {
        #expect(lookup([]) == "SELECT * FROM \"parent\" WHERE 1 = 0 LIMIT 1 OFFSET 0")
    }

    @Test("The schema is named, so the lookup cannot land on another schema's table")
    func schemaIsQualified() {
        #expect(
            lookup([("code", "abc")], schema: "sales", type: .mssql)
                .hasPrefix("SELECT * FROM [sales].[parent] WHERE [code] = 'abc'")
        )
    }

    // SQL Server and Oracle reject `LIMIT`, and the failure reads exactly like a key with no matching row.
    @Test("An OFFSET/FETCH engine gets its own clause")
    func offsetFetchEngines() {
        for type in [DatabaseType.mssql, .oracle] {
            let sql = lookup([("code", "abc")], type: type)
            #expect(sql.contains("OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"))
            #expect(!sql.contains("LIMIT"))
        }
    }

    @Test("A quote in the value is escaped rather than closing the literal")
    func quoteIsEscaped() {
        #expect(lookup([("code", "O'Brien")]).contains("= 'O''Brien'"))
    }

    // MySQL reads `\'` as an escaped quote, so doubling the quote alone ends the literal at the value's backslash.
    @Test("A backslash before a quote cannot break out of the literal")
    func backslashCannotBreakOut() {
        let sql = lookup([("code", "a\\' OR 1=1 -- ")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("= 'a\\\\'' OR 1=1 -- '"))
        #expect(!sql.contains("'a\\'' OR"))
    }

    @Test("A trailing backslash leaves the literal closed")
    func trailingBackslashIsEscaped() {
        let sql = lookup([("code", "C:\\")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("= 'C:\\\\'"))
    }

    @Test("Every escaped value goes through the driver, never a hand-written rule")
    func escapingFollowsTheDriver() {
        let ansi = lookup([("code", "a\\b")])
        let backslash = lookup([("code", "a\\b")], type: .mysql, backslashEscaping: true)
        #expect(ansi.contains("= 'a\\b'"))
        #expect(backslash.contains("= 'a\\\\b'"))
    }
}
