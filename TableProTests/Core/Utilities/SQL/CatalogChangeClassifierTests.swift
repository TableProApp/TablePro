//
//  CatalogChangeClassifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct CatalogChangeClassifierTests {
    private func kinds(_ sql: String, _ type: DatabaseType = .postgresql) -> CatalogObjectKinds {
        CatalogChangeClassifier.effect(of: sql, databaseType: type).kinds
    }

    @Test("reads and row writes leave the catalog alone", arguments: [
        "SELECT * FROM orders",
        "WITH recent AS (SELECT 1) SELECT * FROM recent",
        "INSERT INTO orders (id) VALUES (1)",
        "UPDATE orders SET total = 0",
        "DELETE FROM orders WHERE id = 1",
        "TRUNCATE TABLE orders",
        "SHOW TABLES",
        "EXPLAIN SELECT 1",
        "SET search_path TO public",
        "USE shop",
        "VACUUM ANALYZE orders",
        "GRANT SELECT ON orders TO reporter",
        "BEGIN",
        "START TRANSACTION",
        ""
    ])
    func statementsThatCannotChangeTheCatalog(_ sql: String) {
        #expect(kinds(sql).isEmpty)
    }

    @Test("definitions map to the kind of object they name")
    func definitionsMapByObjectKeyword() {
        let cases: [(sql: String, expected: CatalogObjectKinds)] = [
            ("CREATE TABLE sidebar_probe (id int)", .tables),
            ("DROP TABLE IF EXISTS sidebar_probe", .tables),
            ("ALTER TABLE orders ADD COLUMN note text", .tables),
            ("CREATE OR REPLACE VIEW v AS SELECT 1", .tables),
            ("CREATE MATERIALIZED VIEW mv AS SELECT 1", .tables),
            ("CREATE UNIQUE INDEX idx ON orders (id)", .tables),
            ("RENAME TABLE a TO b", .tables),
            ("COMMENT ON TABLE orders IS 'x'", .tables),
            ("CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql", .routines),
            ("DROP PROCEDURE p", .routines),
            ("CREATE TRIGGER trg BEFORE INSERT ON orders FOR EACH ROW EXECUTE FUNCTION f()", .triggers),
            ("CREATE TYPE mood AS ENUM ('ok')", .types),
            ("DROP SCHEMA staging CASCADE", [.schemas, .objects]),
            ("DROP DATABASE shop", .everything),
            ("CREATE KEYSPACE ks WITH replication = {}", .everything)
        ]
        for testCase in cases {
            #expect(kinds(testCase.sql) == testCase.expected, "\(testCase.sql)")
        }
    }

    @Test("a leading comment does not hide a definition")
    func leadingCommentIsSkipped() {
        #expect(kinds("-- cleanup\n/* old */ DROP TABLE sidebar_probe") == .tables)
    }

    @Test("a MySQL executable comment is read as the statement it wraps")
    func executableCommentIsRevealed() {
        #expect(kinds("/*!50001 CREATE ALGORITHM=UNDEFINED */ /*!50001 VIEW `v` AS select 1 */", .mysql) == .tables)
        #expect(kinds("/*!40101 SET NAMES utf8mb4 */", .mysql).isEmpty)
    }

    @Test("a SQL Server batch is read past its first command")
    func sqlServerBatchIsReadPastItsFirstCommand() {
        let cases: [(sql: String, expected: CatalogObjectKinds)] = [
            ("SET NOCOUNT ON\nCREATE TABLE hidden (id int)", .tables),
            ("BEGIN TRANSACTION\nDROP VIEW reporting", .tables),
            ("DECLARE @n int = 1\nEXEC dbo.rebuild @n", .everything),
            ("INSERT INTO audit VALUES (1)\nALTER PROCEDURE p AS SELECT 1", .routines)
        ]
        for testCase in cases {
            #expect(kinds(testCase.sql, .mssql) == testCase.expected, "\(testCase.sql)")
        }
    }

    @Test("a query reading a column named like a keyword does not refresh the catalog", arguments: [
        "SELECT comment, remove_flag FROM posts",
        "SELECT * FROM notes WHERE body = 'DROP TABLE users'",
        "UPDATE posts SET comment = 'create' WHERE id = 1"
    ])
    func keywordLikeColumnsAreNotDefinitions(_ sql: String) {
        #expect(kinds(sql).isEmpty)
    }

    @Test("SELECT INTO creates a table")
    func selectIntoCreatesATable() {
        #expect(kinds("SELECT * INTO archive_orders FROM orders") == .tables)
    }

    @Test("statements whose effect the text cannot show refresh every kind, containers included", arguments: [
        "CALL rebuild_reporting()",
        "EXEC dbo.rebuild",
        "DO $$ BEGIN CREATE SCHEMA staging; END $$",
        "BEGIN CREATE TABLE t (id int); END;",
        "SOMETHING_NEW orders"
    ])
    func opaqueStatementsRefreshEverything(_ sql: String) {
        #expect(kinds(sql) == .everything)
    }

    @Test("ATTACH and DETACH change the database list")
    func attachChangesDatabases() {
        #expect(kinds("ATTACH 'other.duckdb' AS other", .duckdb) == .everything)
        #expect(kinds("DETACH other", .duckdb) == .everything)
    }

    @Test("dropping a user changes objects only with CASCADE")
    func principalsChangeObjectsOnlyWithCascade() {
        #expect(kinds("DROP USER reporter").isEmpty)
        #expect(kinds("DROP USER app CASCADE", .oracle) == [.schemas, .objects])
        #expect(kinds("DROP OWNED BY app") == [.schemas, .objects])
    }

    @Test("a transaction end is reported, and changes nothing by itself", arguments: [
        "COMMIT", "END", "ROLLBACK", "ABORT"
    ])
    func transactionEndsAreReported(_ sql: String) {
        let effect = CatalogChangeClassifier.effect(of: sql, databaseType: .postgresql)
        #expect(effect.endsTransaction)
        #expect(effect.kinds.isEmpty)
    }

    @Test("rolling back to a savepoint keeps the transaction open", arguments: [
        "ROLLBACK TO SAVEPOINT s", "ROLLBACK TO s", "ROLLBACK WORK TO SAVEPOINT s"
    ])
    func rollbackToSavepointDoesNotEndTheTransaction(_ sql: String) {
        #expect(CatalogChangeClassifier.effect(of: sql, databaseType: .postgresql) == .none)
    }

    @Test("a script reports the union of its statements")
    func scriptsUnionTheirStatements() {
        let effect = CatalogChangeClassifier.effect(
            ofStatements: ["CREATE TABLE a (id int)", "CREATE FUNCTION f() RETURNS int AS 'x'", "COMMIT"],
            databaseType: .postgresql
        )
        #expect(effect.kinds == [.tables, .routines])
        #expect(effect.endsTransaction)
    }

    @Test("a document store refreshes on any write and never on a read")
    func documentStoresFollowTheirReadTier() {
        #expect(kinds("db.users.find({})", .mongodb).isEmpty)
        #expect(kinds("db.createCollection('events')", .mongodb) == .everything)
        #expect(kinds("db.dropDatabase()", .mongodb) == .everything)
    }

    @Test("Redis commands never change the catalog")
    func redisIsIgnored() {
        #expect(kinds("FLUSHDB", .redis).isEmpty)
        #expect(kinds("SET key value", .redis).isEmpty)
    }
}
