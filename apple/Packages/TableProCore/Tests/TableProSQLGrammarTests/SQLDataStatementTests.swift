import Foundation
import TableProSQLGrammar
import Testing

struct SQLDataStatementTests {
    private static func isData(_ sql: String, _ engine: String = "PostgreSQL") -> Bool {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.isDataStatement(sql, databaseTypeId: engine, readings: readings)
    }

    @Test("A read or a row change is a data statement", arguments: [
        ("SELECT * FROM orders WHERE id = 1", "PostgreSQL"),
        ("INSERT INTO orders (id, note) VALUES (1, 'a')", "PostgreSQL"),
        ("UPDATE orders SET paid = true WHERE id = 1", "PostgreSQL"),
        ("DELETE FROM orders WHERE id = 1", "PostgreSQL"),
        ("MERGE INTO orders o USING staged s ON o.id = s.id WHEN MATCHED THEN UPDATE SET note = s.note", "PostgreSQL"),
        ("WITH gone AS (DELETE FROM orders WHERE id = 1 RETURNING *) INSERT INTO archive SELECT * FROM gone", "PostgreSQL"),
        ("WITH recent AS (SELECT id FROM orders) UPDATE orders SET seen = true WHERE id IN (SELECT id FROM recent)",
         "PostgreSQL"),
        ("EXPLAIN ANALYZE UPDATE orders SET paid = true WHERE id = 1", "PostgreSQL"),
        ("EXPLAIN SELECT * FROM orders", "PostgreSQL"),
        ("INSERT INTO orders (id) VALUES (nextval('orders_id_seq'))", "PostgreSQL"),
        ("SELECT nextval('orders_id_seq')", "PostgreSQL"),
        ("SHOW search_path", "PostgreSQL"),
        ("REPLACE INTO orders (id) VALUES (1)", "MySQL"),
        ("INSERT INTO orders (id) VALUES (1) ON DUPLICATE KEY UPDATE note = 'b'", "MySQL"),
        ("UPSERT INTO orders (id, note) VALUES (1, 'a')", "CockroachDB"),
        ("INSERT OR REPLACE INTO orders (id) VALUES (1)", "SQLite"),
        ("UPDATE statistics SET hits = hits + 1 WHERE id = 1", "PostgreSQL"),
        ("BEGIN BATCH INSERT INTO ks.t (id) VALUES (1); UPDATE ks.t SET v = 'b' WHERE id = 2; APPLY BATCH", "Cassandra"),
        ("REPLACE orders VALUES (1)", "MySQL"),
        ("SELECT * FROM pg_settings WHERE name = 'search_path'", "PostgreSQL"),
        ("ALTER TABLE shop.orders UPDATE note = 'a' WHERE id = 1", "ClickHouse"),
        ("ALTER TABLE orders ON CLUSTER main DELETE WHERE id = 1", "ClickHouse"),
    ])
    func rowWorkIsData(sql: String, engine: String) {
        #expect(Self.isData(sql, engine))
    }

    @Test("A definition, a grant, a session or transaction statement and a call are not", arguments: [
        ("GRANT SELECT ON orders TO app", "PostgreSQL"),
        ("REVOKE ALL ON orders FROM app", "PostgreSQL"),
        ("ALTER ROLE app_user WITH SUPERUSER", "PostgreSQL"),
        ("SET session_replication_role = replica", "PostgreSQL"),
        ("RESET ALL", "PostgreSQL"),
        ("CREATE TABLE notes (id int)", "PostgreSQL"),
        ("ALTER TABLE orders ADD COLUMN note text", "PostgreSQL"),
        ("COMMENT ON TABLE orders IS 'x'", "PostgreSQL"),
        ("BEGIN", "PostgreSQL"),
        ("COMMIT", "PostgreSQL"),
        ("CALL purge_orders()", "PostgreSQL"),
        ("LOCK TABLE orders", "PostgreSQL"),
        ("VACUUM orders", "PostgreSQL"),
        ("ANALYZE orders", "PostgreSQL"),
        ("REFRESH MATERIALIZED VIEW totals", "PostgreSQL"),
        ("LISTEN orders_changed", "PostgreSQL"),
        ("PREPARE purge AS DELETE FROM orders WHERE id = $1", "PostgreSQL"),
        ("SELECT set_config('role', 'admin', false)", "PostgreSQL"),
        ("SELECT pg_terminate_backend(42)", "PostgreSQL"),
        ("SELECT pg_advisory_lock(1)", "PostgreSQL"),
        ("SELECT * INTO orders_copy FROM orders", "PostgreSQL"),
        ("EXPLAIN ANALYZE CREATE TABLE copy AS SELECT * FROM orders", "PostgreSQL"),
        ("WITH x AS (SELECT 1) SELECT * INTO copy FROM x", "PostgreSQL"),
        ("SELECT 1; GRANT ALL ON orders TO app", "PostgreSQL"),
        ("USE shop", "MySQL"),
        ("SET @limit = 10", "MySQL"),
        ("SELECT COUNT(*) INTO @total FROM orders", "MySQL"),
        ("LOCK TABLES orders WRITE", "MySQL"),
        ("UPDATE STATISTICS dbo.orders", "SQL Server"),
        ("INSERT INTO dbo.orders EXEC dbo.load_orders", "SQL Server"),
        ("EXEC sp_configure 'show advanced options', 1", "SQL Server"),
        ("PRAGMA foreign_keys = OFF", "SQLite"),
        ("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'", "Oracle"),
        ("BEGIN purge_orders; END;", "Oracle"),
        ("OPTIMIZE TABLE orders FINAL", "ClickHouse"),
        ("SYSTEM FLUSH LOGS", "ClickHouse"),
        ("DEFINE TABLE person SCHEMAFULL", "SurrealDB"),
        ("USE ks", "Cassandra"),
        ("GRANT SELECT ON ks.t TO app", "Cassandra"),
        ("REPLACE VIEW totals AS SELECT 1", "Teradata"),
        ("ALTER TABLE orders UPDATE note = 'a' WHERE id = 1, DROP COLUMN note", "ClickHouse"),
        ("ALTER TABLE orders ADD COLUMN note String", "ClickHouse"),
        ("ALTER TABLE orders UPDATE note = 'a' WHERE id = 1", "MySQL"),
    ])
    func schemaPrivilegeAndSessionAreNot(sql: String, engine: String) {
        #expect(!Self.isData(sql, engine))
    }

    @Test("A row change on a table the server acts on is not", arguments: [
        ("UPDATE pg_settings SET setting = 'replica' WHERE name = 'session_replication_role'", "PostgreSQL"),
        ("UPDATE pg_catalog.pg_authid SET rolsuper = true WHERE rolname = 'app'", "PostgreSQL"),
        ("INSERT INTO \"pg_catalog\".\"pg_authid\" (rolname) VALUES ('x')", "PostgreSQL"),
        ("UPDATE sys_settings SET setting = 'x' WHERE name = 'search_path'", "KingbaseES"),
        ("UPSERT INTO system.users (username) VALUES ('x')", "CockroachDB"),
        ("UPDATE mysql.user SET Super_priv = 'Y' WHERE User = 'app'", "MySQL"),
        ("UPDATE `performance_schema`.`setup_consumers` SET ENABLED = 'NO'", "MariaDB"),
        ("UPDATE orders SET note = set_config('role', 'admin', false) WHERE id = 1", "PostgreSQL"),
        ("INSERT INTO log SELECT pg_terminate_backend(pid) FROM pg_stat_activity", "PostgreSQL"),
        ("UPDATE U&\"pg\\005fsettings\" SET setting = 'x' WHERE name = 'search_path'", "PostgreSQL"),
        ("INSERT INTO msdb.dbo.sysjobsteps (job_id, command) VALUES (1, 'x')", "SQL Server"),
        ("UPDATE system.help SET text = 'x'", "Oracle"),
    ])
    func systemRelationsAreNot(sql: String, engine: String) {
        #expect(!Self.isData(sql, engine))
    }

    @Test("A scope in the engine's own schemas is a system scope, in any case, and only on that engine")
    func systemScopesFollowTheEngine() {
        #expect(SQLStatementClassifier.isSystemScope(database: "mysql", schema: nil, databaseTypeId: "MariaDB"))
        #expect(SQLStatementClassifier.isSystemScope(database: "MSDB", schema: "dbo", databaseTypeId: "SQL Server"))
        #expect(SQLStatementClassifier.isSystemScope(database: "app", schema: "pg_catalog", databaseTypeId: "PostgreSQL"))
        #expect(!SQLStatementClassifier.isSystemScope(database: "mysql", schema: nil, databaseTypeId: "PostgreSQL"))
        #expect(!SQLStatementClassifier.isSystemScope(database: "shop", schema: nil, databaseTypeId: "MySQL"))
        #expect(!SQLStatementClassifier.isSystemScope(database: "ORCL", schema: "SYSTEM", databaseTypeId: "Oracle"))
        #expect(SQLStatementClassifier.isSystemScope(database: "ORCL", schema: "sys", databaseTypeId: "Oracle"))
    }

    @Test("A call that happens to start like a catalog name is not a catalog relation")
    func catalogNamedCallIsData() {
        #expect(Self.isData("UPDATE orders SET pid = pg_backend_pid() WHERE id = 1"))
    }

    @Test("A request form with no data reading is refused, and its own reading decides")
    func requestFormsAnswerForThemselves() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)
        let tagged: SQLStatementClassifier.RequestClassification = { statement, _ in
            statement.hasPrefix("REQ ") ? .write : nil
        }
        #expect(!SQLStatementClassifier.isDataStatement(
            "REQ CreateTable", databaseTypeId: "PostgreSQL", readings: readings, request: tagged
        ))
        #expect(SQLStatementClassifier.isDataStatement(
            "REQ PutItem", databaseTypeId: "PostgreSQL", readings: readings, request: tagged,
            requestIsData: { statement, _ in statement.hasPrefix("REQ ") ? statement.hasSuffix("PutItem") : nil }
        ))
    }
}
