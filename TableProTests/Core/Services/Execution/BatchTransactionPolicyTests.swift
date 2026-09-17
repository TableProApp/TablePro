//
//  BatchTransactionPolicyTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Batch transaction policy")
struct BatchTransactionPolicyTests {
    @Test("A batch with no transaction statements runs inside one transaction")
    func plainBatchIsWrapped() {
        #expect(BatchTransactionPolicy.wrapsInTransaction([
            "INSERT INTO t VALUES (1)",
            "UPDATE t SET a = 2",
            "SELECT * FROM t",
        ], dialect: .postgres))
    }

    @Test("An empty batch is wrapped")
    func emptyBatchIsWrapped() {
        #expect(BatchTransactionPolicy.wrapsInTransaction([], dialect: .generic))
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
            "/*!40101 BEGIN */",
            "/*M!100100 START TRANSACTION */",
        ]
    )
    func transactionOpenerIsNotWrapped(statement: String) {
        #expect(!BatchTransactionPolicy.wrapsInTransaction(["INSERT INTO t VALUES (1)", statement], dialect: .generic))
    }

    @Test(
        "MySQL refuses SET TRANSACTION inside a transaction, so a script that sets one runs as written",
        arguments: ["SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "set transaction read only"]
    )
    func mysqlTransactionCharacteristicsAreNotWrapped(statement: String) {
        #expect(!BatchTransactionPolicy.wrapsInTransaction([statement, "UPDATE t SET a = 1"], dialect: .mysql))
    }

    @Test(
        "PostgreSQL, SQL Server and SQLite apply SET TRANSACTION inside the wrap, so it keeps the wrap",
        arguments: [SqlDialect.postgres, .sqlite, .generic]
    )
    func transactionCharacteristicsKeepTheWrapElsewhere(dialect: SqlDialect) {
        #expect(BatchTransactionPolicy.wrapsInTransaction(
            ["SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "UPDATE t SET a = 1"],
            dialect: dialect
        ))
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
            "SET IMPLICIT_TRANSACTIONS ON",
            "/*!40101 SET autocommit = 0 */",
        ]
    )
    func commitModeSettingIsNotWrapped(statement: String) {
        #expect(!BatchTransactionPolicy.wrapsInTransaction([statement, "UPDATE t SET a = 1"], dialect: .mysql))
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
        #expect(BatchTransactionPolicy.wrapsInTransaction(["INSERT INTO t VALUES (1)", statement], dialect: .mysql))
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
        #expect(BatchTransactionPolicy.wrapsInTransaction(statements, dialect: .mysql))
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
        #expect(!BatchTransactionPolicy.wrapsInTransaction(statements, dialect: .sqlite))
    }
}
