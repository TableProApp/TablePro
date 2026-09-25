//
//  ClickHouseTableListTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The table list read `currentDatabase()` whatever database it was asked about, so a caller holding
/// one connection and asking about each database in turn, which the export dialog does, was answered
/// about the session's database every time and listed its tables under every name.
struct ClickHouseTableListTests {
    @Test("A named database is what the read filters on")
    func namedDatabaseIsFiltered() {
        let sql = ClickHousePluginDriver.tableListSQL(schema: "analytics")
        #expect(sql.contains("WHERE database = 'analytics'"))
        #expect(!sql.contains("currentDatabase()"))
    }

    @Test("No database named means the one the session is on")
    func noDatabaseUsesTheSession() {
        #expect(ClickHousePluginDriver.tableListSQL(schema: nil).contains("WHERE database = currentDatabase()"))
        #expect(ClickHousePluginDriver.tableListSQL(schema: "").contains("WHERE database = currentDatabase()"))
    }

    @Test("A quote in a database name is escaped")
    func quotesAreEscaped() {
        #expect(ClickHousePluginDriver.tableListSQL(schema: "o'brien").contains("WHERE database = 'o''brien'"))
    }

    /// A ClickHouse literal takes backslash escapes as well as doubled quotes, and a database name
    /// is free to hold either. Measured on 24.8.14.39 with quote-only escaping: a database created
    /// as `trail\` answered `Code 62 SYNTAX_ERROR`, "Single quoted string is not closed".
    @Test("A backslash in a database name is escaped")
    func backslashesAreEscaped() {
        #expect(
            ClickHousePluginDriver.tableListSQL(schema: #"back\slash"#)
                .contains(#"WHERE database = 'back\\slash'"#)
        )
        #expect(
            ClickHousePluginDriver.tableListSQL(schema: #"trail\"#)
                .contains(#"WHERE database = 'trail\\'"#)
        )
    }

    /// The same measurement: a database created as `q\' OR 1=1 -- ` closed the literal early under
    /// quote-only escaping and the read returned every table on the server.
    @Test("A backslashed quote cannot close the literal early")
    func literalStaysClosed() {
        let sql = ClickHousePluginDriver.tableListSQL(schema: #"q\' OR 1=1 -- "#)
        #expect(sql.contains(#"WHERE database = 'q\\'' OR 1=1 -- ' AND"#))
    }

    @Test("The read still hides internal tables and sorts by name")
    func readKeepsItsShape() {
        let sql = ClickHousePluginDriver.tableListSQL(schema: "analytics")
        #expect(sql.contains("name NOT LIKE '.%'"))
        #expect(sql.contains("ORDER BY name"))
    }
}
