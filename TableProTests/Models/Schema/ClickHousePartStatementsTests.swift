//
//  ClickHousePartStatementsTests.swift
//  TableProTests
//
//  The Parts tab's statements name the tab's own database, because ClickHouse resolves an
//  unqualified one from a request parameter the app moves whenever any tab runs elsewhere.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ClickHouse part statements")
struct ClickHousePartStatementsTests {
    private let quote: (String) -> String = { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }
    private let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "\\'") }

    /// The defect: an unqualified DROP PARTITION deleted data from whichever database the shared
    /// driver was last pinned to, while the tab reported it was acting on its own.
    @Test("Every statement names the database it was given")
    func statementsCarryTheDatabase() {
        #expect(
            ClickHousePartStatements.optimize(database: "analytics", table: "events", quote: quote)
                == "OPTIMIZE TABLE `analytics`.`events` FINAL"
        )
        #expect(
            ClickHousePartStatements.dropPartition(
                database: "analytics", table: "events", partition: "202401",
                quote: quote, escape: escape
            ) == "ALTER TABLE `analytics`.`events` DROP PARTITION '202401'"
        )
        #expect(
            ClickHousePartStatements.detachPartition(
                database: "analytics", table: "events", partition: "202401",
                quote: quote, escape: escape
            ) == "ALTER TABLE `analytics`.`events` DETACH PARTITION '202401'"
        )
    }

    /// `currentDatabase()` answers with the request parameter, so the list showed another database's
    /// parts under this table's name.
    @Test("The parts read filters on the named database, never the connection's current one")
    func partsReadNamesTheDatabase() {
        let sql = ClickHousePartStatements.parts(
            database: "analytics", table: "events", escape: escape
        )
        #expect(sql.contains("WHERE database = 'analytics'"))
        #expect(sql.contains("AND table = 'events'"))
        #expect(!sql.contains("currentDatabase()"))
    }

    /// A connection saved with no database of its own has nothing to qualify against, and an empty
    /// qualifier is a statement the server refuses. The parts read has to fall back too: comparing
    /// against '' matches nothing, where ClickHouse's own default database is what the user sees.
    @Test("With no database the name stays unqualified and the read asks the server")
    func emptyDatabaseLeavesTheNameBare() {
        #expect(
            ClickHousePartStatements.qualifiedName(database: "", table: "events", quote: quote)
                == "`events`"
        )
        #expect(
            ClickHousePartStatements.optimize(database: "", table: "events", quote: quote)
                == "OPTIMIZE TABLE `events` FINAL"
        )
        let sql = ClickHousePartStatements.parts(database: "", table: "events", escape: escape)
        #expect(sql.contains("WHERE database = currentDatabase()"))
        #expect(!sql.contains("database = ''"))
    }

    @Test("A quote in a partition value is escaped, and a backtick in a name is quoted")
    func valuesAreEscaped() {
        let sql = ClickHousePartStatements.dropPartition(
            database: "we`ird", table: "ev`ents", partition: "it's",
            quote: quote, escape: escape
        )
        #expect(sql.contains("`we``ird`.`ev``ents`"))
        #expect(sql.contains("'it\\'s'"))
    }
}
