//
//  BatchTransactionPolicyTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct BatchTransactionPolicyTests {
    private static func plan(_ statements: [String], _ type: DatabaseType) -> BatchTransactionPlan {
        BatchTransactionPolicy.plan(
            for: statements,
            databaseType: type,
            grammar: type.lexicalGrammar
        )
    }

    @Test("A batch with no transaction statements runs inside one transaction")
    func plainBatchIsWrapped() {
        #expect(Self.plan([
            "INSERT INTO t VALUES (1)",
            "UPDATE t SET a = 2",
            "SELECT * FROM t",
        ], .postgresql) == .appTransaction)
    }

    @Test("An empty batch is wrapped")
    func emptyBatchIsWrapped() {
        #expect(Self.plan([], .mysql) == .appTransaction)
    }

    @Test(
        "A statement that opens a transaction makes the script run as written",
        arguments: [
            "BEGIN",
            "begin",
            "BEGIN TRANSACTION",
            "BEGIN WORK",
            "BEGIN TRAN",
            "BEGIN TRAN transfer",
            "BEGIN DISTRIBUTED TRANSACTION",
            "BEGIN IMMEDIATE",
            "BEGIN DEFERRED TRANSACTION",
            "BEGIN EXCLUSIVE",
            "BEGIN ISOLATION LEVEL SERIALIZABLE",
            "BEGIN READ ONLY",
            "BEGIN NOT DEFERRABLE",
            "START TRANSACTION",
            "start transaction read write",
            "START TRANSACTION WITH CONSISTENT SNAPSHOT",
            "XA START 'xid'",
            "XA BEGIN 'xid'",
            "  \n\tBEGIN",
            "-- open the transfer\nBEGIN",
            "/* migration 42 */ START TRANSACTION",
        ]
    )
    func transactionOpenerIsNotWrapped(statement: String) {
        #expect(Self.plan(["INSERT INTO t VALUES (1)", statement], .mysql) == .scriptTransaction)
    }

    @Test(
        "A conditional comment carries transaction control on MySQL alone",
        arguments: ["/*!40101 BEGIN */", "/*M!100100 START TRANSACTION */"]
    )
    func conditionalCommentOpenerIsRead(statement: String) {
        #expect(Self.plan(["INSERT INTO t VALUES (1)", statement], .mysql) == .scriptTransaction)
        #expect(Self.plan(["INSERT INTO t VALUES (1)", statement], .postgresql) == .appTransaction)
    }

    /// Oracle has no `BEGIN` for a transaction: `BEGIN` opens a PL/SQL block. `SET TRANSACTION` is
    /// the statement that opens one, so a script holding it manages its own.
    @Test(
        "An Oracle script that opens its own transaction runs as written",
        arguments: [
            "SET TRANSACTION READ ONLY",
            "set transaction isolation level serializable",
            "SET TRANSACTION NAME 'nightly'",
            "-- hold the rows\nSET TRANSACTION READ WRITE",
        ]
    )
    func oracleSetTransactionIsNotWrapped(statement: String) {
        #expect(Self.plan([statement, "UPDATE t SET a = 1"], .oracle) == .scriptTransaction)
    }

    @Test(
        "An Oracle script without SET TRANSACTION is wrapped",
        arguments: [
            ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 2"],
            ["SAVEPOINT a", "INSERT INTO t VALUES (1)", "ROLLBACK TO a"],
            ["LOCK TABLE t IN EXCLUSIVE MODE", "UPDATE t SET a = 1"],
            ["SET ROLE ALL", "UPDATE t SET a = 1"],
            ["BEGIN NULL; END;", "COMMIT"],
        ]
    )
    func oracleBatchIsWrapped(statements: [String]) {
        #expect(Self.plan(statements, .oracle) == .appTransaction)
    }

    @Test(
        "MySQL refuses SET TRANSACTION inside a transaction, so a script that sets one runs as written",
        arguments: ["SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "set transaction read only"]
    )
    func mysqlTransactionCharacteristicsAreNotWrapped(statement: String) {
        #expect(Self.plan([statement, "UPDATE t SET a = 1"], .mysql) == .autocommit)
    }

    @Test(
        "PostgreSQL, SQL Server and SQLite apply SET TRANSACTION inside the wrap, so it keeps the wrap",
        arguments: [DatabaseType.postgresql, .sqlite, .mssql]
    )
    func transactionCharacteristicsKeepTheWrapElsewhere(type: DatabaseType) {
        #expect(Self.plan(
            ["SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "UPDATE t SET a = 1"],
            type
        ) == .appTransaction)
    }

    @Test(
        "A statement that sets the commit mode makes the script run as written",
        arguments: [
            "SET autocommit = 0",
            "SET autocommit=1",
            "SET @@autocommit = 0",
            "SET @@SESSION.autocommit = 0",
            "SET SESSION autocommit = 0",
            "SET LOCAL autocommit = 0",
            "/*!40101 SET autocommit = 0 */",
            "SET NAMES utf8mb4, @@session.autocommit=1",
        ]
    )
    func commitModeSettingIsNotWrapped(statement: String) {
        #expect(Self.plan([statement, "UPDATE t SET a = 1"], .mysql) == .scriptTransaction)
    }

    @Test(
        "T-SQL turns the commit mode on with no equals sign at all",
        arguments: [
            "SET IMPLICIT_TRANSACTIONS ON",
            "SET ANSI_NULLS, IMPLICIT_TRANSACTIONS ON",
            "SET ANSI_DEFAULTS ON",
            "set implicit_transactions on",
        ]
    )
    func implicitTransactionsIsNotWrapped(statement: String) {
        #expect(Self.plan([statement, "UPDATE t SET a = 1"], .mssql) == .scriptTransaction)
    }

    @Test(
        "T-SQL options that leave the commit mode alone keep the wrap",
        arguments: [
            "SET IMPLICIT_TRANSACTIONS OFF",
            "SET ANSI_DEFAULTS OFF",
            "SET NOCOUNT ON",
            "SET ANSI_NULLS, ANSI_PADDING ON",
            "SET @total = 1",
        ]
    )
    func otherSessionOptionsKeepTheWrap(statement: String) {
        #expect(Self.plan([statement, "UPDATE t SET a = 1"], .mssql) == .appTransaction)
    }

    @Test(
        "Statements that only look like transaction control keep the wrap",
        arguments: [
            "BEGIN TRY SELECT 1 END TRY",
            "BEGIN\n    INSERT INTO t VALUES (1)",
            "BEGIN ATOMIC",
            "START SLAVE",
            "START REPLICA",
            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
            "SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED",
            "SET GLOBAL autocommit = 0",
            "SET @@GLOBAL.autocommit = 0",
            "SET @autocommit = 0",
            "SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL SERIALIZABLE",
            "SET NAMES utf8mb4",
            "SAVEPOINT before_update",
            "ROLLBACK TO SAVEPOINT before_update",
            "COMMIT",
            "ROLLBACK",
            "XA RECOVER",
            "SELECT 'BEGIN TRANSACTION'",
            "-- BEGIN\nSELECT 1",
            "LOCK TABLES t WRITE",
            "DO $$ BEGIN PERFORM 1; END $$",
            "/*!40101 SET NAMES utf8mb4 */",
            "/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */",
        ]
    )
    func lookalikeKeepsTheWrap(statement: String) {
        #expect(Self.plan(["INSERT INTO t VALUES (1)", statement], .mysql) == .appTransaction)
    }

    @Test("A routine whose body manages a transaction is not the script managing one")
    func routineBodyKeepsTheWrap() {
        let script = """
            CREATE PROCEDURE transfer()
            BEGIN
                START TRANSACTION;
                UPDATE accounts SET balance = balance - 1 WHERE id = 1;
                COMMIT;
            END;
            CALL transfer();
            """
        let statements = SQLStatementScanner.executableStatements(in: script).map(\.sql)
        #expect(statements.count == 2)
        #expect(Self.plan(statements, .mysql) == .appTransaction)
    }

    @Test("A SQLite dump that opens its own transaction runs as written")
    func sqliteDumpIsNotWrapped() {
        let script = """
            PRAGMA foreign_keys=OFF;
            BEGIN TRANSACTION;
            CREATE TABLE t (id INTEGER PRIMARY KEY);
            INSERT INTO t VALUES (1);
            COMMIT;
            """
        let statements = SQLStatementScanner.executableStatements(in: script).map(\.sql)
        #expect(statements.count == 5)
        #expect(Self.plan(statements, .sqlite) == .scriptTransaction)
    }

    @Test("A statement the engine refuses inside a transaction makes the batch run in autocommit")
    func autocommitOnlyStatementUnwrapsTheBatch() {
        #expect(Self.plan(["CREATE TABLE t (id int)", "VACUUM"], .postgresql) == .autocommit)
        #expect(Self.plan(["INSERT INTO t VALUES (1)", "PRAGMA foreign_keys = ON"], .sqlite) == .autocommit)
        #expect(Self.plan(["INSERT INTO t VALUES (1)", "CHECKPOINT"], .duckdb) == .autocommit)
    }

    @Test("The same statement can be perfectly safe on another engine")
    func theEngineDecides() {
        #expect(Self.plan(["INSERT INTO t VALUES (1)", "VACUUM"], .duckdb) == .appTransaction)
        #expect(Self.plan(["CREATE DATABASE app", "USE app"], .mysql) == .appTransaction)
        #expect(Self.plan(["INSERT INTO t VALUES (1)", "CHECKPOINT"], .postgresql) == .appTransaction)
    }

    @Test("A SQLite savepoint opens a transaction, so the script owns it after all")
    func savepointAfterAnUnwrappingStatement() {
        #expect(Self.plan(["VACUUM", "SAVEPOINT a", "INSERT INTO t VALUES (1)"], .sqlite) == .scriptTransaction)
        #expect(Self.plan(["VACUUM", "SAVEPOINT a", "INSERT INTO t VALUES (1)"], .postgresql) == .autocommit)
    }

    @Test("The preamble of a GTID mysqldump runs in autocommit")
    func gtidDumpPreambleIsNotWrapped() {
        let statements = [
            "SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN",
            "SET @@SESSION.SQL_LOG_BIN= 0",
            "SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ 'ca7aa847-b2b6-11f1-88c3-d63f97f21d50:1-8'",
            "INSERT INTO t VALUES (1)",
            "SET @@SESSION.SQL_LOG_BIN = @MYSQLDUMP_TEMP_LOG_BIN"
        ]
        #expect(Self.plan(statements, .mysql) == .autocommit)
    }

    @Test("A mysqlbinlog dump manages its own commit mode, which wins over the autocommit rule")
    func binlogDumpManagesItsOwnTransaction() {
        let statements = [
            "/*!50530 SET @@SESSION.PSEUDO_SLAVE_MODE=1*/",
            "/*!50003 SET @OLD_COMPLETION_TYPE=@@COMPLETION_TYPE, COMPLETION_TYPE=0*/",
            "SET @@session.foreign_key_checks=1, @@session.sql_mode='', @@session.unique_checks=1, @@session.autocommit=1",
            "INSERT INTO t VALUES (1)"
        ]
        #expect(Self.plan(statements, .mysql) == .scriptTransaction)
    }

    /// PostgreSQL's transaction-only statements are left alone on purpose. Unwrapping a batch that
    /// holds one makes it behave the way `psql` does: `LOCK TABLE`, `SAVEPOINT` and `DECLARE
    /// CURSOR` error, and `SET LOCAL`, `SET CONSTRAINTS` and `SET TRANSACTION` warn and do nothing.
    /// None of them open a transaction, so none of them can make the script the owner of one, and
    /// letting one force the wrap back on would put `VACUUM` back inside it.
    @Test(
        "A PostgreSQL statement that only works inside a transaction does not change the plan",
        arguments: [
            "LOCK TABLE t IN ACCESS EXCLUSIVE MODE",
            "SAVEPOINT a",
            "DECLARE c CURSOR FOR SELECT 1",
            "SET LOCAL statement_timeout = '1s'",
            "SET CONSTRAINTS ALL DEFERRED",
            "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
        ]
    )
    func postgresTransactionOnlyStatements(statement: String) {
        #expect(Self.plan([statement, "INSERT INTO t VALUES (1)"], .postgresql) == .appTransaction)
        #expect(Self.plan([statement, "VACUUM"], .postgresql) == .autocommit)
    }

    /// Redis `MULTI` queues every command after it and answers `+QUEUED` in place of each reply, so
    /// a wrapped batch reports `QUEUED` for every command it ran and hides every error `EXEC`
    /// returns. The app opens nothing and each command answers as sent.
    @Test(
        "A Redis batch runs as sent",
        arguments: [
            ["GET s"],
            ["GET s", "DEL nokey", "LPUSH l x"],
            ["SET k v", "EXPIRE k 10"],
            []
        ]
    )
    func redisBatchIsNotWrapped(statements: [String]) {
        #expect(Self.plan(statements, .redis) == .autocommit)
    }

    /// `SET` on Redis writes a key. The SQL commit-mode rules never reach it, so a script writing a
    /// key called `autocommit` is a plain batch rather than a script taking transaction control.
    @Test(
        "A Redis key write is not read as SQL transaction control",
        arguments: [
            "SET autocommit 1",
            "SET SESSION autocommit",
            "SET @@session.autocommit 0",
            "GET begin",
            "DEL start transaction",
            "SET IMPLICIT_TRANSACTIONS ON"
        ]
    )
    func redisKeyWritesAreNotTransactionControl(statement: String) {
        #expect(Self.plan([statement, "GET s"], .redis) == .autocommit)
    }

    /// A batch that opens its own block has to end it when it fails or is stopped: nothing in the
    /// block has run, and the next command on that session would be queued into it rather than
    /// answered. `.scriptTransaction` is what sends the `DISCARD`.
    @Test(
        "A Redis batch that opens a MULTI block owns the transaction",
        arguments: ["MULTI", "multi", "  \n\tMULTI", "Multi"]
    )
    func redisMultiTakesTransactionControl(statement: String) {
        #expect(Self.plan([statement, "SET a 1", "EXEC"], .redis) == .scriptTransaction)
    }

    @Test(
        "Ending or watching a block does not open one",
        arguments: ["EXEC", "DISCARD", "WATCH k", "UNWATCH", "GET multi", "SET multi 1", "RESET"]
    )
    func redisBlockEndersDoNotOpenOne(statement: String) {
        #expect(Self.plan([statement], .redis) == .autocommit)
    }
}
