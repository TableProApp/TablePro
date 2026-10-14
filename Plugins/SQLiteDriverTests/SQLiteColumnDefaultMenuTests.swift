//
//  SQLiteColumnDefaultMenuTests.swift
//  SQLiteDriverTests
//

import Foundation
import Testing

// The SQLite-family Default menu, which TableProTests' ColumnDefaultRoundTripTests pins ColumnDefaultVocabulary to.
struct SQLiteColumnDefaultMenuTests {
    @Test("Every SQLite-family menu value is already what the catalog normaliser would produce")
    func menuValuesAreStable() {
        let menu = ["NULL", "''", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "(datetime('now'))", "(unixepoch())"]
        for sql in menu {
            #expect(sqliteDefaultValueFromCatalog(sql) == sql, "\(sql)")
        }
    }
}
