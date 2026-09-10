import Foundation
import TableProModels
import Testing
@testable import TableProQuery

@Suite("SQLWriteClassifier")
struct SQLWriteClassifierTests {
    private func isWrite(_ sql: String, _ type: DatabaseType = .postgresql) -> Bool {
        SQLWriteClassifier.isWriteQuery(sql, databaseType: type)
    }

    // MARK: - The reported bypasses

    @Test("a leading line comment does not hide a write")
    func lineCommentBypass() {
        #expect(isWrite("-- cleanup\nDELETE FROM users"))
        #expect(isWrite("--cleanup\r\nTRUNCATE TABLE users"))
    }

    @Test("a leading block comment does not hide a write")
    func blockCommentBypass() {
        #expect(isWrite("/* nightly */ DELETE FROM users"))
        #expect(isWrite("/* one */ /* two */\n UPDATE users SET a = 1"))
    }

    @Test("a CTE that ends in a write is a write")
    func cteBypass() {
        #expect(isWrite("WITH d AS (SELECT id FROM users) DELETE FROM users WHERE id IN (SELECT id FROM d)"))
        #expect(isWrite("WITH t AS (SELECT 1) INSERT INTO log SELECT * FROM t"))
    }

    @Test("a CTE that only reads is a read")
    func readOnlyCTE() {
        #expect(!isWrite("WITH d AS (SELECT id FROM users) SELECT * FROM d"))
    }

    @Test("a CTE ending in SELECT INTO materialises a table, so it is a write")
    func cteSelectIntoIsWrite() {
        #expect(isWrite("WITH x AS (SELECT 1 AS a) SELECT * INTO backup FROM x", .mssql))
    }

    @Test("a column whose name merely starts with a verb does not make a CTE a write")
    func cteIdentifierPrefixIsNotAVerb() {
        #expect(!isWrite("WITH x AS (SELECT into_count FROM users) SELECT * FROM x"))
    }

    @Test("a CTE calling a function whose name matches a statement verb is still a read")
    func cteFunctionNameIsNotAVerb() {
        #expect(!isWrite("WITH x AS (SELECT replace(name, 'a', 'b') FROM users) SELECT * FROM x"))
        #expect(!isWrite("WITH x AS (SELECT copy_count FROM users) SELECT * FROM x"))
    }

    @Test("a write verb appearing only inside a string literal does not make a CTE a write")
    func cteWriteWordInsideLiteral() {
        #expect(!isWrite("WITH d AS (SELECT 'DELETE FROM users' AS note) SELECT * FROM d"))
    }

    // MARK: - Keywords the old allowlist never had

    @Test("statements the old keyword list omitted are writes")
    func unlistedWriteKeywords() {
        #expect(isWrite("MERGE INTO target USING source ON target.id = source.id WHEN MATCHED THEN UPDATE SET a = 1"))
        #expect(isWrite("GRANT SELECT ON users TO analyst"))
        #expect(isWrite("REVOKE SELECT ON users FROM analyst"))
        #expect(isWrite("SET search_path TO app"))
        #expect(isWrite("COPY users FROM '/tmp/users.csv'"))
        #expect(isWrite("CALL rebuild_indexes()"))
        #expect(isWrite("EXEC sp_who"))
    }

    @Test("an unrecognised keyword fails closed")
    func unknownKeywordIsWrite() {
        #expect(isWrite("FROBNICATE the_widgets"))
        #expect(isWrite("\u{FFFD}\u{FFFD}"))
    }

    // MARK: - Reads

    @Test("plain reads are reads")
    func reads() {
        #expect(!isWrite("SELECT * FROM users"))
        #expect(!isWrite("  select 1  "))
        #expect(!isWrite("SHOW TABLES", .mysql))
        #expect(!isWrite("DESCRIBE users", .mysql))
        #expect(!isWrite("-- just a note\nSELECT 1"))
        #expect(!isWrite("SELECT count(*) FROM users"))
    }

    @Test("a statement that runs its plan or writes a pragma is a write")
    func explainAndPragmaAreWrites() {
        #expect(isWrite("EXPLAIN ANALYZE DELETE FROM users"))
        #expect(isWrite("EXPLAIN SELECT * FROM users"))
        #expect(isWrite("PRAGMA journal_mode = WAL", .sqlite))
    }

    @Test("SELECT INTO materialises a table, so it is a write")
    func selectIntoIsWrite() {
        #expect(isWrite("SELECT * INTO backup FROM users", .mssql))
        #expect(isWrite("SELECT * FROM users INTO OUTFILE '/tmp/u.csv'", .mysql))
        #expect(!isWrite("SELECT 'INTO' FROM users"))
    }

    @Test("a backslash does not swallow the quote that ends a literal")
    func backslashDoesNotHideABatch() {
        #expect(isWrite(#"SELECT 'a\' ; DELETE FROM users"#))
    }

    @Test("Redis reads are reads and Redis writes are writes")
    func redisCommands() {
        #expect(!isWrite("GET user:1", .redis))
        #expect(!isWrite("HGETALL user:1", .redis))
        #expect(!isWrite("SCAN 0", .redis))
        #expect(!isWrite("TTL user:1", .redis))
        #expect(!isWrite("CONFIG GET maxmemory", .redis))
        #expect(isWrite("SET user:1 bob", .redis))
        #expect(isWrite("DEL user:1", .redis))
        #expect(isWrite("FLUSHALL", .redis))
        #expect(isWrite("CONFIG SET maxmemory 0", .redis))
        #expect(isWrite("SOMETHINGNEW key", .redis))
    }

    @Test("empty and comment-only input is not a write")
    func emptyInput() {
        #expect(!isWrite(""))
        #expect(!isWrite("   \n  "))
        #expect(!isWrite("-- nothing here"))
        #expect(!isWrite("/* nothing */"))
        #expect(!isWrite(";;;"))
    }

    // MARK: - Batches

    @Test("any write in a batch makes the batch a write")
    func batchWithWrite() {
        #expect(isWrite("SELECT 1; DELETE FROM users"))
        #expect(isWrite("SELECT 1;\n-- cleanup\nDELETE FROM users"))
        #expect(!isWrite("SELECT 1; SELECT 2"))
    }

    @Test("a semicolon inside a literal does not split a statement")
    func semicolonInsideLiteral() {
        #expect(!isWrite("SELECT 'a;b' FROM users"))
        #expect(isWrite("SELECT 'a;b' FROM users; UPDATE users SET a = 1"))
    }

    @Test("a semicolon inside a quoted identifier does not split a statement")
    func semicolonInsideIdentifier() {
        #expect(!isWrite(#"SELECT "odd;name" FROM users"#))
    }

    @Test("a doubled quote does not end a literal")
    func doubledQuote() {
        #expect(!isWrite("SELECT 'it''s; fine' FROM users"))
    }

    @Test("a semicolon inside a comment does not split a statement")
    func semicolonInsideComment() {
        #expect(!isWrite("SELECT 1 -- ; DELETE FROM users"))
        #expect(!isWrite("SELECT 1 /* ; DELETE FROM users */"))
    }
}
