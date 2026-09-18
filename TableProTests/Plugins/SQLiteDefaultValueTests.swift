//
//  SQLiteDefaultValueTests.swift
//  TableProTests
//
//  Measured against SQLite 3.54.0. `DEFAULT (datetime('now'))` reads back from
//  `pragma_table_info` as `datetime('now')` and will not parse bare. `DEFAULT abc` is a text
//  literal that stores the string `abc` and reads back as `abc`; re-emitting it as `(abc)` fails
//  with `default value of column [a] is not constant`.
//

import Testing

@Suite("SQLite catalog default round trip")
struct SQLiteDefaultValueTests {
    @Test(
        "A pragma default becomes SQL that recreates it",
        arguments: [
            (catalog: "'abc'", expected: "'abc'"),
            (catalog: "''", expected: "''"),
            (catalog: "CURRENT_TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (catalog: "CURRENT_DATE", expected: "CURRENT_DATE"),
            (catalog: "CURRENT_TIME", expected: "CURRENT_TIME"),
            (catalog: "NULL", expected: "NULL"),
            (catalog: "0", expected: "0"),
            (catalog: "-1.5", expected: "-1.5"),
            (catalog: "TRUE", expected: "TRUE"),
            (catalog: "X'0102'", expected: "X'0102'"),
            (catalog: "datetime('now')", expected: "(datetime('now'))"),
            (catalog: "unixepoch()", expected: "(unixepoch())"),
            (catalog: "(datetime('now'))", expected: "(datetime('now'))"),
            (catalog: "abc", expected: "'abc'"),
            (catalog: "it's", expected: "'it''s'"),
            (catalog: "'x' || 'y'", expected: "('x' || 'y')"),
            (catalog: "'it''s'", expected: "'it''s'")
        ]
    )
    func roundTrip(catalog: String, expected: String) {
        #expect(sqliteDefaultValueFromCatalog(catalog) == expected)
        #expect(libSQLDefaultValueFromCatalog(catalog) == expected)
        #expect(cloudflareD1DefaultValueFromCatalog(catalog) == expected)
    }

    @Test("No default at all stays absent")
    func absentDefault() {
        #expect(sqliteDefaultValueFromCatalog(nil) == nil)
        #expect(sqliteDefaultValueFromCatalog("") == nil)
        #expect(libSQLDefaultValueFromCatalog(nil) == nil)
        #expect(cloudflareD1DefaultValueFromCatalog(nil) == nil)
    }
}
