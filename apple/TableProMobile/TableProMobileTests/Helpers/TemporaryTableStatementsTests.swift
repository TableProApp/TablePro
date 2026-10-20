import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct TemporaryTableStatementsTests {
    @Test("A temporary table a statement creates is noted, by its unquoted lowercased name")
    func createdTables() {
        let mysql = TemporaryTableStatements.change(
            in: ["CREATE TEMPORARY TABLE IF NOT EXISTS scratch (id int)", "SELECT 1"], databaseType: .mysql
        )
        let postgres = TemporaryTableStatements.change(
            in: [#"CREATE TEMP TABLE "Scratch Pad" AS SELECT 1"#], databaseType: .postgresql
        )

        #expect(mysql.created == ["scratch"])
        #expect(postgres.created == ["scratch pad"])
    }

    @Test("A dropped table is noted, and a later create in the same run wins")
    func droppedTables() {
        let change = TemporaryTableStatements.change(
            in: ["CREATE TEMPORARY TABLE a (id int)", "DROP TEMPORARY TABLE a", "DROP TABLE IF EXISTS b"],
            databaseType: .mysql
        )

        #expect(change.created.isEmpty)
        #expect(change.dropped == ["a", "b"])
    }

    @Test("A permanent table, a comment or a string names no temporary table")
    func ignoresTheRest() {
        let change = TemporaryTableStatements.change(
            in: ["CREATE TABLE t (id int)", "-- CREATE TEMP TABLE x\nSELECT 1", "SELECT 'CREATE TEMP TABLE y'"],
            databaseType: .postgresql
        )

        #expect(change.created.isEmpty)
    }
}
