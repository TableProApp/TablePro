import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct SessionLocalStatementsTests {
    @Test("A temporary table a statement creates is noted, by its unquoted lowercased name")
    func createdTables() {
        let mysql = SessionLocalStatements.effect(
            of: ["CREATE TEMPORARY TABLE IF NOT EXISTS scratch (id int)", "SELECT 1"], databaseType: .mysql
        )
        let postgres = SessionLocalStatements.effect(
            of: [#"CREATE TEMP TABLE "Scratch Pad" AS SELECT 1"#], databaseType: .postgresql
        )

        #expect(mysql.temporaryTables == ["scratch"])
        #expect(postgres.temporaryTables == ["scratch pad"])
    }

    @Test("A dropped temporary table stays noted, since a failed script may never have reached the DROP")
    func droppedTableStaysNoted() {
        let effect = SessionLocalStatements.effect(
            of: ["CREATE TEMPORARY TABLE a (id int)", "SELECT * FROM missing", "DROP TEMPORARY TABLE a"],
            databaseType: .mysql
        )

        #expect(effect.temporaryTables == ["a"])
    }

    @Test("A permanent table, a comment or a string names no temporary table")
    func ignoresTheRest() {
        let effect = SessionLocalStatements.effect(
            of: ["CREATE TABLE t (id int)", "-- CREATE TEMP TABLE x\nSELECT 1", "SELECT 'CREATE TEMP TABLE y'"],
            databaseType: .postgresql
        )

        #expect(effect.temporaryTables.isEmpty)
        #expect(!effect.switchesDatabase)
    }

    @Test("USE moves the session to another database, quoted or inside a SQL Server batch")
    func useSwitchesDatabase() {
        #expect(SessionLocalStatements.effect(of: ["USE archive"], databaseType: .mysql).switchesDatabase)
        #expect(SessionLocalStatements.effect(of: ["use `old shop`"], databaseType: .mysql).switchesDatabase)
        #expect(
            SessionLocalStatements.effect(of: ["SELECT 1\nUSE [archive]\nSELECT 2"], databaseType: .mssql)
                .switchesDatabase
        )
    }

    @Test("An index hint, a longer word, a comment or a string is not a USE")
    func useLookalikes() {
        let effect = SessionLocalStatements.effect(
            of: [
                "SELECT * FROM t USE INDEX (i)",
                "SELECT * FROM t USE KEY (k)",
                "SELECT user, use_count FROM t",
                "-- USE archive\nSELECT 1",
                "SELECT 'USE archive'"
            ],
            databaseType: .mysql
        )

        #expect(!effect.switchesDatabase)
    }
}
