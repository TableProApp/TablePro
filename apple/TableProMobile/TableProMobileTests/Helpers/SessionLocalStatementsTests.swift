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

        let commented = SessionLocalStatements.effect(
            of: ["CREATE TEMPORARY TABLE /* scratch */ orders (id INT)"], databaseType: .mysql
        )

        #expect(mysql.temporaryTables == ["scratch"])
        #expect(commented.temporaryTables == ["orders"])
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
        #expect(!effect.leavesCatalog)
    }

    @Test("USE moves the session to another database, quoted or inside a SQL Server batch")
    func useLeavesTheCatalog() {
        #expect(SessionLocalStatements.effect(of: ["USE archive"], databaseType: .mysql).leavesCatalog)
        #expect(SessionLocalStatements.effect(of: ["use `old shop`"], databaseType: .mysql).leavesCatalog)
        #expect(
            SessionLocalStatements.effect(of: ["SELECT 1\nUSE [archive]\nSELECT 2"], databaseType: .mssql)
                .leavesCatalog
        )
    }

    @Test("A procedure call, dynamic SQL or an anonymous block may make a table only the session sees")
    func opaqueStatementsLeaveTheCatalog() {
        #expect(SessionLocalStatements.effect(of: ["CALL make_scratch()"], databaseType: .mysql).leavesCatalog)
        #expect(SessionLocalStatements.effect(of: ["EXECUTE stmt"], databaseType: .mysql).leavesCatalog)
        #expect(SessionLocalStatements.effect(of: ["EXEC dbo.make_scratch"], databaseType: .mssql).leavesCatalog)
        #expect(
            SessionLocalStatements.effect(of: ["DO $$ BEGIN PERFORM 1; END $$"], databaseType: .postgresql)
                .leavesCatalog
        )
        let plain = SessionLocalStatements.effect(
            of: [
                "SELECT 1", "INSERT INTO t VALUES (1)", "CREATE TABLE u (id int)", "SET @a = 1", "SHOW TABLES",
                "CREATE DATABASE archive", "DROP DATABASE archive"
            ],
            databaseType: .mysql
        )
        #expect(!plain.leavesCatalog)
    }

    @Test("A statement inside a MySQL executable comment may make a temporary table, so it leaves the catalog")
    func executableCommentLeavesTheCatalog() {
        let effect = SessionLocalStatements.effect(
            of: ["/*!50000 CREATE TEMPORARY TABLE orders (draft_note INT) */"], databaseType: .mysql
        )
        #expect(effect.leavesCatalog)
    }

    @Test("A role or a search path set on the session leaves the catalog connection behind")
    func sessionContextLeavesTheCatalog() {
        for statement in [
            "SET ROLE limited_user", "SET SESSION AUTHORIZATION 'reporter'", "SET search_path TO sales",
            "set local search_path = archive", "SET SCHEMA 'sales'", "RESET ROLE", "DISCARD ALL",
            "ALTER SESSION SET CURRENT_SCHEMA = hr"
        ] {
            #expect(SessionLocalStatements.effect(of: [statement], databaseType: .postgresql).leavesCatalog, "\(statement)")
        }
        let quiet = SessionLocalStatements.effect(
            of: ["SET statement_timeout = 0", "SET TIME ZONE 'UTC'", "SET @rolename = 'x'"], databaseType: .postgresql
        )
        #expect(!quiet.leavesCatalog)
    }

    @Test("Dropping, altering or restoring a database is seen, in a comment or a string it is not")
    func databaseChanges() {
        #expect(SessionLocalStatements.changesDatabases("USE master; DROP DATABASE appdb", databaseType: .mssql))
        #expect(SessionLocalStatements.changesDatabases("alter database appdb set single_user", databaseType: .mssql))
        #expect(!SessionLocalStatements.changesDatabases("-- DROP DATABASE appdb\nSELECT 1", databaseType: .mssql))
        #expect(!SessionLocalStatements.changesDatabases("SELECT 'DROP DATABASE appdb'", databaseType: .mssql))
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

        #expect(!effect.leavesCatalog)
    }
}
