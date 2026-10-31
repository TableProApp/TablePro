//
//  QueryClassifierSnowflakePipeTests.swift
//  TableProTests
//
//  Snowflake's pipe operator runs every statement of `SELECT 1 ->> DELETE FROM t` in order, and no `;` separates them,
//  so a gate that tiered the chain by its first word would see a read. These hold the tier to the worst statement in
//  the chain.
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierSnowflakePipeTests {
    @Test("A write chained after a read is a write", arguments: [
        "SELECT 1 ->> DELETE FROM orders",
        "SELECT 1 ->> UPDATE orders SET paid = TRUE",
        "SELECT 1 ->> CALL purge_orders()",
        "SHOW TABLES ->> INSERT INTO log SELECT * FROM $1",
        "SHOW TABLES ->> CREATE TABLE copy AS SELECT * FROM orders",
        "SHOW TABLES ->> GRANT ROLE admin TO USER eve",
        "SELECT 1\n->>\nDELETE FROM orders\n->> SELECT * FROM $1",
        "SELECT 1->>DELETE FROM orders",
    ])
    func chainedWriteIsAWrite(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .snowflake) == .write)
        #expect(QueryClassifier.isWriteQuery(sql, databaseType: .snowflake))
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .snowflake))
    }

    @Test("A DROP or TRUNCATE chained after a read is destructive", arguments: [
        "SHOW TABLES ->> DROP TABLE orders",
        "SELECT 1 ->> TRUNCATE TABLE orders",
        "SELECT 1 ->> ALTER TABLE orders DROP COLUMN paid",
    ])
    func chainedDropIsDestructive(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .snowflake) == .destructive)
    }

    @Test("A DELETE without WHERE is caught in a chain as it is on its own")
    func chainedUnfilteredDeleteIsDangerous() {
        #expect(QueryClassifier.isDangerousQuery("SELECT 1 ->> DELETE FROM orders", databaseType: .snowflake))
        #expect(!QueryClassifier.isDangerousQuery("SELECT 1 ->> DELETE FROM orders WHERE id = 1", databaseType: .snowflake))
    }

    @Test("An unload chained after a read reaches the filesystem")
    func chainedUnloadReachesTheFilesystem() {
        let sql = "SHOW TABLES ->> COPY INTO @stage FROM orders"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .snowflake) == .write)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .snowflake))
    }

    @Test("A chain of reads stays a read", arguments: [
        "SHOW TABLES ->> SELECT \"name\" FROM $1",
        "SHOW TABLES ->> SELECT \"name\" FROM $1 ->> SELECT COUNT(*) FROM $2",
        "SELECT 1\n->>\nSELECT $1.col",
    ])
    func chainedReadIsARead(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .snowflake) == .safe)
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .snowflake))
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .snowflake))
    }

    @Test("An operator inside a literal or a comment chains nothing", arguments: [
        "SELECT '->> DELETE FROM orders'",
        "SELECT $$->> DELETE FROM orders$$",
        "SELECT 1 // ->> DELETE FROM orders",
        "SELECT 1 /* ->> DELETE FROM orders */",
    ])
    func quotedOperatorChainsNothing(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .snowflake) == .safe)
    }

    @Test("On an engine where ->> reads JSON, a statement is still tiered by its first word", arguments: [
        DatabaseType.postgresql, .mysql, .sqlite, .clickhouse,
    ])
    func jsonOperatorEnginesAreUnchanged(databaseType: DatabaseType) {
        let sql = "SELECT doc ->> 'delete' FROM t"
        #expect(QueryClassifier.classifyTier(sql, databaseType: databaseType) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT 1 ->> DELETE FROM t", databaseType: databaseType) == .safe)
    }
}
