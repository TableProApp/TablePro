//
//  AutocommitOnlyStatementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

private enum AutocommitOnlyFixture {
    static let sqlServer = TestGrammar.standard.union(.bracketQuotedIdentifiers)

    static func matches(_ statement: String, _ family: TransactionEngineFamily) -> Bool {
        AutocommitOnlyStatement.matches(statement, family: family, grammar: grammar(for: family))
    }

    static func grammar(for family: TransactionEngineFamily) -> SQLLexicalGrammar {
        switch family {
        case .postgres, .redshift, .cockroach:
            return TestGrammar.postgres
        case .mysql:
            return TestGrammar.mysql
        case .sqlite, .duckdb:
            return TestGrammar.sqlite
        case .sqlServer:
            return sqlServer
        case .oracle:
            return TestGrammar.oracle
        case .redis, .other:
            return TestGrammar.standard
        }
    }
}

struct AutocommitOnlyStatementPostgreSQLTests {
    @Test(
        "PostgreSQL 17 refuses these inside a transaction block",
        arguments: [
            "VACUUM",
            "VACUUM FULL t",
            "VACUUM (VERBOSE, ANALYZE) t",
            "/* maintenance */ VACUUM t",
            "-- nightly\nVACUUM t",
            "CREATE DATABASE app",
            "DROP DATABASE IF EXISTS app",
            "CREATE TABLESPACE fast LOCATION '/mnt/fast'",
            "DROP TABLESPACE fast",
            "ALTER DATABASE postgres SET TABLESPACE pg_default",
            "ALTER SYSTEM SET work_mem = '8MB'",
            "ALTER SYSTEM RESET ALL",
            "CREATE INDEX CONCURRENTLY t_v ON t(v)",
            "CREATE UNIQUE INDEX CONCURRENTLY t_v ON t(v)",
            "DROP INDEX CONCURRENTLY t_v",
            "REINDEX INDEX CONCURRENTLY t_v",
            "REINDEX TABLE CONCURRENTLY t",
            "REINDEX (CONCURRENTLY) TABLE t",
            "REINDEX (CONCURRENTLY true) TABLE t",
            "REINDEX (CONCURRENTLY 1) TABLE t",
            "REINDEX (VERBOSE, CONCURRENTLY) TABLE t",
            "REINDEX SCHEMA public",
            "REINDEX DATABASE app",
            "REINDEX SYSTEM app",
            "CLUSTER",
            "CLUSTER VERBOSE",
            "CLUSTER (VERBOSE)",
            "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p",
            "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p WITH (connect)",
            "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p WITH (enabled = false)",
            "DROP SUBSCRIPTION s",
            "ALTER SUBSCRIPTION s REFRESH PUBLICATION",
            "ALTER SUBSCRIPTION s SET PUBLICATION p",
            "ALTER SUBSCRIPTION s ADD PUBLICATION p",
            "ALTER SUBSCRIPTION s DROP PUBLICATION p",
            "ALTER SUBSCRIPTION s SET (failover = true)",
            "COMMIT PREPARED 'gx'",
            "ROLLBACK PREPARED 'gx'",
            "DISCARD ALL",
            "ALTER TABLE p DETACH PARTITION p1 CONCURRENTLY",
            "ALTER TYPE mood ADD VALUE 'c'"
        ]
    )
    func postgresRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .postgres))
    }

    @Test(
        "PostgreSQL 17 takes these inside a transaction block",
        arguments: [
            "ALTER DATABASE postgres SET work_mem = '8MB'",
            "ANALYZE t",
            "CHECKPOINT",
            "LISTEN channel",
            "LOAD 'auto_explain'",
            "REINDEX TABLE t",
            "REINDEX (CONCURRENTLY false) TABLE t",
            "REINDEX (CONCURRENTLY off) TABLE t",
            "REINDEX (CONCURRENTLY 0) TABLE t",
            "REINDEX (TABLESPACE fast) TABLE t",
            "CREATE INDEX \"concurrently\" ON t(v)",
            "CLUSTER c USING c_id",
            "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p WITH (connect = false)",
            "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p WITH (create_slot = off)",
            "ALTER SUBSCRIPTION s SET PUBLICATION p WITH (refresh = false)",
            "ALTER SUBSCRIPTION s SET (streaming = on)",
            "ALTER SUBSCRIPTION s ENABLE",
            "DISCARD PLANS",
            "DISCARD TEMP",
            "DISCARD SEQUENCES",
            "ALTER TABLE p DETACH PARTITION p1",
            "ALTER TYPE stock ADD ATTRIBUTE weight integer",
            "SELECT 'VACUUM'",
            "COMMENT ON TABLE t IS 'VACUUM daily'",
            "DO $$ BEGIN PERFORM 1; END $$",
            "COMMIT",
            "ROLLBACK",
            "SET CLUSTER SETTING sql.defaults.x = 1",
            "BACKUP INTO 'gs://bucket'"
        ]
    )
    func postgresAcceptances(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .postgres))
    }
}

struct AutocommitOnlyStatementWarehouseTests {
    @Test(
        "Redshift restricts its own statements as well as PostgreSQL's",
        arguments: [
            "CREATE EXTERNAL TABLE spectrum.sales (id int)",
            "DROP EXTERNAL TABLE spectrum.sales",
            "ALTER EXTERNAL TABLE spectrum.sales SET LOCATION 's3://bucket'",
            "ALTER TABLE target APPEND FROM staging",
            "CREATE LIBRARY f LANGUAGE plpythonu FROM 's3://bucket'",
            "CREATE OR REPLACE LIBRARY f LANGUAGE plpythonu FROM 's3://bucket'",
            "DROP LIBRARY f"
        ]
    )
    func redshiftRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .redshift))
        #expect(!AutocommitOnlyFixture.matches(statement, .postgres))
    }

    @Test(
        "CockroachDB refuses a cluster setting and an undetached bulk job",
        arguments: [
            "SET CLUSTER SETTING sql.defaults.distsql = 1",
            "BACKUP INTO 'gs://bucket'",
            "RESTORE FROM LATEST IN 'gs://bucket'",
            "IMPORT INTO t CSV DATA ('gs://bucket/t.csv')"
        ]
    )
    func cockroachRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .cockroach))
        #expect(!AutocommitOnlyFixture.matches(statement, .postgres))
    }

    @Test("A detached CockroachDB job runs inside the transaction")
    func detachedJobsKeepTheWrap() {
        #expect(!AutocommitOnlyFixture.matches("BACKUP INTO 'gs://bucket' WITH detached", .cockroach))
        #expect(!AutocommitOnlyFixture.matches("RESTORE FROM LATEST IN 'gs://b' WITH (detached)", .cockroach))
    }
}

struct AutocommitOnlyStatementMySQLTests {
    @Test(
        "MySQL 8.4 and MariaDB 11.4 refuse these inside a transaction",
        arguments: [
            "SET sql_log_bin = 0",
            "SET SESSION sql_log_bin = 0",
            "SET LOCAL sql_log_bin = 0",
            "SET @@SESSION.SQL_LOG_BIN= 0",
            "SET @@sql_log_bin = 0",
            "SET @@local.sql_log_bin = 0",
            "SET `sql_log_bin` = 0",
            "SET sql_log_bin := 0",
            "SET @@SESSION . sql_log_bin = 0",
            "/*!40101 SET @@SESSION.SQL_LOG_BIN= 0 */",
            "SET NAMES utf8mb4, sql_log_bin = 0",
            "SET @x = 1, @@session.sql_log_bin = 0",
            "SET binlog_format = ROW",
            "SET SESSION binlog_direct_non_transactional_updates = 0",
            "SET gtid_next = 'AUTOMATIC'",
            "SET @@SESSION.binlog_row_value_options = ''",
            "SET GLOBAL binlog_row_value_options = ''",
            "/*!50530 SET @@SESSION.PSEUDO_SLAVE_MODE=1*/",
            "SET @@GLOBAL.GTID_PURGED='ca7aa847-b2b6-11f1-88c3-d63f97f21d50:1-8'",
            "SET GLOBAL gtid_mode = ON",
            "SET PERSIST gtid_mode = ON",
            "SET GLOBAL enforce_gtid_consistency = ON",
            "SET GLOBAL read_only = 1",
            "SET @@GLOBAL.read_only = 1",
            "SET PERSIST read_only = 1",
            "SET GLOBAL gtid_slave_pos = '0-1-3'",
            "SET GLOBAL gtid_binlog_state = '0-1-3'",
            "SET gtid_domain_id = 3",
            "SET gtid_seq_no = 5",
            "SET skip_replication = 1",
            "SET STATEMENT gtid_domain_id = 3 FOR INSERT INTO t VALUES (1)",
            "SET STATEMENT sql_log_bin = 0 FOR INSERT INTO t VALUES (1)",
            "SET @@transaction_isolation = 'SERIALIZABLE'",
            "SET @@tx_isolation = 'SERIALIZABLE'",
            "SET @@transaction_read_only = 1",
            "SET @@tx_read_only = 1",
            "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE",
            "set transaction read only",
            "STOP SLAVE",
            "STOP REPLICA",
            "STOP ALL SLAVES",
            "SET binlog_transaction_compression = ON",
            "SET binlog_transaction_compression_level_zstd = 3",
            "SET session_track_gtids = ALL_GTIDS",
            "SET pseudo_replica_mode = 1",
            "SET explicit_defaults_for_timestamp = 1",
            "SET xa_detach_on_prepare = OFF",
            "SET group_replication_consistency = 'EVENTUAL'",
            "SET GLOBAL binlog_checksum = NONE",
            "SET wsrep_on = 0"
        ]
    )
    func mysqlRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .mysql))
    }

    @Test(
        "MySQL takes these inside a transaction, and the scope is what tells them apart",
        arguments: [
            "SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN",
            "SET GLOBAL binlog_format = ROW",
            "SET PERSIST_ONLY read_only = 1",
            "SET SESSION binlog_checksum = NONE",
            "SET transaction_isolation = 'SERIALIZABLE'",
            "SET SESSION transaction_isolation = 'SERIALIZABLE'",
            "SET @@SESSION.transaction_isolation = 'SERIALIZABLE'",
            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
            "SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED",
            "SET @s = 'SET sql_log_bin = 0'",
            "SET NAMES utf8mb4",
            "SET autocommit = 0",
            "SET binlog_row_image = FULL",
            "SET GLOBAL super_read_only = 1",
            "SET GLOBAL offline_mode = 1",
            "SET TIMESTAMP = 1700000000",
            "STOP GROUP_REPLICATION",
            "RESET SLAVE",
            "CHANGE MASTER TO MASTER_HOST = 'x'",
            "SELECT 'SET sql_log_bin = 0'",
            "INSERT INTO t VALUES (1)"
        ]
    )
    func mysqlAcceptances(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .mysql))
    }
}

struct AutocommitOnlyStatementEmbeddedTests {
    @Test(
        "SQLite refuses or silently ignores these inside a transaction",
        arguments: [
            "VACUUM",
            "vacuum main",
            "VACUUM INTO 'copy.db'",
            "DETACH other",
            "DETACH DATABASE other",
            "PRAGMA journal_mode = WAL",
            "PRAGMA main.journal_mode=wal",
            "PRAGMA journal_mode(WAL)",
            "PRAGMA synchronous = OFF",
            "PRAGMA main.synchronous = 1",
            "PRAGMA synchronous(0)",
            "PRAGMA foreign_keys = ON",
            "PRAGMA foreign_keys=1",
            "PRAGMA foreign_keys(ON)",
            "PRAGMA main.foreign_keys = ON",
            "PRAGMA wal_checkpoint",
            "PRAGMA wal_checkpoint(TRUNCATE)",
            "PRAGMA main.wal_checkpoint(FULL)"
        ]
    )
    func sqliteRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .sqlite))
    }

    @Test(
        "SQLite takes these inside a transaction",
        arguments: [
            "PRAGMA foreign_keys",
            "PRAGMA main.foreign_keys",
            "PRAGMA foreign_key_list(t)",
            "PRAGMA table_info(t)",
            "PRAGMA temp_store = MEMORY",
            "PRAGMA page_size = 4096",
            "PRAGMA optimize",
            "ATTACH 'other.db' AS other",
            "SELECT 'VACUUM'",
            "INSERT INTO t VALUES (1)"
        ]
    )
    func sqliteAcceptances(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .sqlite))
    }

    @Test(
        "DuckDB refuses a checkpoint and a detach",
        arguments: [
            "DETACH other",
            "CHECKPOINT",
            "CHECKPOINT other",
            "FORCE CHECKPOINT",
            "CALL checkpoint()",
            "CALL force_checkpoint()"
        ]
    )
    func duckdbRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .duckdb))
    }

    @Test(
        "DuckDB takes what SQLite refuses",
        arguments: [
            "VACUUM",
            "ATTACH 'other.db' AS other",
            "SET threads = 4",
            "PRAGMA foreign_keys = ON",
            "PRAGMA journal_mode = WAL",
            "PRAGMA force_checkpoint",
            "CALL pragma_version()"
        ]
    )
    func duckdbAcceptances(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .duckdb))
    }
}

struct AutocommitOnlyStatementSQLServerTests {
    @Test(
        "T-SQL cannot hold these in an explicit transaction",
        arguments: [
            "CREATE DATABASE Sales",
            "CREATE DATABASE [Sales Db]",
            "ALTER DATABASE CURRENT SET RECOVERY SIMPLE",
            "DROP DATABASE Sales",
            "CREATE FULLTEXT CATALOG ftCatalog",
            "ALTER FULLTEXT CATALOG ftCatalog REBUILD",
            "CREATE FULLTEXT INDEX ON t(c) KEY INDEX pk",
            "DROP FULLTEXT INDEX ON t",
            "BACKUP DATABASE Sales TO DISK = 'x.bak'",
            "BACKUP LOG Sales TO DISK = 'x.trn'",
            "RESTORE DATABASE Sales FROM DISK = 'x.bak'",
            "RESTORE HEADERONLY FROM DISK = 'x.bak'",
            "RECONFIGURE",
            "RECONFIGURE WITH OVERRIDE"
        ]
    )
    func sqlServerRefusals(statement: String) {
        #expect(AutocommitOnlyFixture.matches(statement, .sqlServer))
    }

    @Test(
        "A statement that only starts with DATABASE keeps the wrap",
        arguments: [
            "ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 1",
            "CREATE DATABASE SCOPED CREDENTIAL c WITH IDENTITY = 'x'",
            "CREATE DATABASE AUDIT SPECIFICATION a FOR SERVER AUDIT s",
            "CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256",
            "BACKUP CERTIFICATE c TO FILE = 'x.cer'",
            "RESTORE MASTER KEY FROM FILE = 'x.key' DECRYPTION BY PASSWORD = 'p'",
            "EXEC sp_configure 'show advanced options', 1",
            "SELECT 1"
        ]
    )
    func sqlServerAcceptances(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .sqlServer))
    }

    @Test(
        "An engine with no curated rules keeps the wrap it has today",
        arguments: ["VACUUM", "CHECKPOINT", "SET sql_log_bin = 0", "CREATE DATABASE app", "RECONFIGURE"]
    )
    func unknownEnginesKeepTheWrap(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .other))
    }

    /// Oracle has no statement it refuses inside a transaction: DDL commits the open one on its own
    /// instead of failing, so nothing forces an Oracle batch out of the wrap.
    @Test(
        "Oracle keeps the wrap for every statement",
        arguments: ["CREATE TABLE t (a NUMBER)", "ALTER SESSION SET CURRENT_SCHEMA = hr", "SET TRANSACTION READ ONLY"]
    )
    func oracleKeepsTheWrap(statement: String) {
        #expect(!AutocommitOnlyFixture.matches(statement, .oracle))
    }
}
