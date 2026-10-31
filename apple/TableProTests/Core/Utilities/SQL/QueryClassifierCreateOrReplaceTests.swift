import Foundation
@testable import TablePro
import Testing

struct QueryClassifierCreateOrReplaceTests {
    @Test("Replacing a table, schema or database is destructive", arguments: [
        (DatabaseType.snowflake, "CREATE OR REPLACE TABLE orders (id INT)"),
        (.snowflake, "create or replace table orders as select * from orders where 1 = 0"),
        (.snowflake, "CREATE OR REPLACE TRANSIENT TABLE orders (id INT)"),
        (.snowflake, "CREATE OR REPLACE SCHEMA sales"),
        (.snowflake, "CREATE OR REPLACE DATABASE prod"),
        (.bigQuery, "CREATE OR REPLACE TABLE shop.orders (id INT64)"),
        (.duckdb, "CREATE OR REPLACE TEMP TABLE orders (id INT)"),
        (.duckdb, "CREATE OR REPLACE UNLOGGED TABLE orders (id INT)"),
        (.duckdb, "CREATE OR REPLACE TABLE function (id INT)"),
        (.snowflake, "CREATE OR REPLACE GLOBAL TEMPORARY TABLE orders (id INT)"),
        (.mariadb, "CREATE OR REPLACE TABLE orders (id INT)"),
        (.mariadb, "CREATE /* swap */ OR REPLACE\nTABLE orders (id INT)"),
        (.mariadb, "CREATE OR REPLACE DATABASE shop"),
        (.clickhouse, "CREATE OR REPLACE TABLE orders (id Int8) ENGINE = Memory"),
        (.clickhouse, "REPLACE TABLE orders (id Int8) ENGINE = Memory"),
    ])
    func replacingStoredDataIsDestructive(databaseType: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: databaseType) == .destructive)
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: databaseType))
    }

    @Test("Replacing a view or a routine, or creating a table, stays a write", arguments: [
        (DatabaseType.postgresql, "CREATE OR REPLACE VIEW v AS SELECT 1"),
        (.postgresql, "CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql"),
        (.snowflake, "CREATE OR REPLACE VIEW \"TABLE\" AS SELECT 1"),
        (.snowflake, "CREATE TABLE orders (id INT)"),
        (.snowflake, "CREATE OR REPLACE STREAM s ON TABLE orders"),
        (.oracle, "CREATE OR REPLACE TYPE ids AS TABLE OF NUMBER"),
        (.duckdb, "CREATE OR REPLACE MACRO m(x) AS TABLE SELECT x"),
        (.mysql, "REPLACE INTO orders (id) VALUES (1)"),
    ])
    func losingNoRowsStaysAWrite(databaseType: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: databaseType) == .write)
    }

    @Test("A caller that may not send DROP TABLE may not send CREATE OR REPLACE TABLE")
    func gateRefusesItWithoutTheDestructiveConfirmation() {
        let statement = ExternalStatementGate.Statement(
            sql: "CREATE OR REPLACE TABLE orders (id INT)",
            connectionId: UUID(),
            databaseType: .snowflake,
            externalAccess: .readWrite,
            loadsExtensions: false,
            allowsDestructive: false
        )
        #expect(throws: ExternalStatementGateError.self) {
            try ExternalStatementGate.classify(statement)
        }
    }
}
