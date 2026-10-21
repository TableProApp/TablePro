import Foundation
@testable import TableProOracleCore
import Testing

/// Whether a statement commits as it runs is decided from its first words, so a misread one either leaves a write
/// uncommitted or commits away a savepoint or a lock the user meant to hold.
struct OracleTransactionRoleTests {
    @Test func testQueriesAreReadsWhateverLeadsThem() {
        for sql in [
            "SELECT * FROM emp",
            "select 1 from dual",
            "WITH t AS (SELECT 1 a FROM dual) SELECT a FROM t",
            "SELECT * FROM emp FOR UPDATE",
            "-- latest hires\nSELECT * FROM emp",
            "/* report */ SELECT 1 FROM dual",
        ] {
            #expect(OracleTransactionRole(of: sql) == .query, "\(sql)")
        }
    }

    @Test func testStatementsThatOnlyMeanSomethingInsideATransactionOpenOne() {
        for sql in [
            "SAVEPOINT before_raise",
            "savepoint a",
            "SET TRANSACTION READ ONLY",
            "set transaction isolation level serializable",
            "SET TRANSACTION NAME 'nightly'",
            "LOCK TABLE emp IN EXCLUSIVE MODE",
            "-- hold it\nLOCK TABLE emp IN SHARE MODE NOWAIT",
        ] {
            #expect(OracleTransactionRole(of: sql) == .opensTransaction, "\(sql)")
        }
    }

    @Test func testCommitAndAFullRollbackEndTheTransaction() {
        for sql in [
            "COMMIT",
            "commit work",
            "COMMIT COMMENT 'nightly load'",
            "COMMIT WRITE BATCH NOWAIT",
            "ROLLBACK",
            "rollback work",
            "/* undo */ ROLLBACK",
        ] {
            #expect(OracleTransactionRole(of: sql) == .endsTransaction, "\(sql)")
        }
    }

    @Test func testARollbackToASavepointKeepsTheTransactionOpen() {
        for sql in ["ROLLBACK TO before_raise", "ROLLBACK TO SAVEPOINT a", "rollback work to savepoint a"] {
            #expect(OracleTransactionRole(of: sql) == .other, "\(sql)")
        }
    }

    @Test func testSettlingAnInDoubtDistributedTransactionLeavesTheSessionsOwnAlone() {
        for sql in ["COMMIT FORCE '1.2.3'", "commit work force '1.2.3', 42", "ROLLBACK FORCE '1.2.3'", "ROLLBACK WORK FORCE '1.2.3'"] {
            #expect(OracleTransactionRole(of: sql) == .other, "\(sql)")
        }
    }

    @Test func testAVeryLongStatementIsReadFromItsHead() {
        let values = Array(repeating: "(1)", count: 500_000).joined(separator: ", ")
        #expect(OracleTransactionRole(of: "INSERT INTO t VALUES \(values)") == .other)
        #expect(OracleTransactionRole(of: "SELECT \(values) FROM dual") == .query)
    }

    @Test func testDataDefinitionIsReadAsTheCommitOracleRunsAroundIt() {
        for sql in [
            "CREATE TABLE t (a NUMBER)",
            "create or replace view v AS SELECT 1 a FROM dual",
            "-- keep\nCREATE INDEX t_a ON t (a)",
            "ALTER TABLE t ADD (b NUMBER)",
            "alter index t_a rebuild",
            "ALTER USER hr IDENTIFIED BY secret",
            "DROP TABLE t PURGE",
            "TRUNCATE TABLE logs",
            "RENAME t TO t2",
            "GRANT SELECT ON emp TO hr",
            "REVOKE SELECT ON emp FROM hr",
            "COMMENT ON TABLE emp IS 'staff'",
            "AUDIT SELECT ON emp",
            "NOAUDIT SELECT ON emp",
            "ANALYZE TABLE emp COMPUTE STATISTICS",
            "ASSOCIATE STATISTICS WITH PACKAGES emp_stats",
            "DISASSOCIATE STATISTICS FROM PACKAGES emp_stats",
            "PURGE RECYCLEBIN",
            "FLASHBACK TABLE emp TO BEFORE DROP",
        ] {
            #expect(OracleTransactionRole(of: sql) == .dataDefinition, "\(sql)")
        }
    }

    @Test func testBlocksAndCallsAreProcedural() {
        for sql in [
            "BEGIN NULL; END;",
            "begin execute immediate 'CREATE TABLE t (a NUMBER)'; end;",
            "DECLARE v NUMBER; BEGIN v := 1; END;",
            "declare v number; begin null; end;",
            "CALL p()",
            "call hr.p(1)",
            "-- rebuild\nBEGIN NULL; END;",
            "/* load */ DECLARE v NUMBER; BEGIN NULL; END;",
            "<<outer>> BEGIN NULL; END;",
            "/* labelled */ <<outer>>\nDECLARE v NUMBER; BEGIN NULL; END;",
        ] {
            #expect(OracleTransactionRole(of: sql) == .procedural, "\(sql)")
        }
    }

    @Test func testOnlyARefusalThatMayHaveEndedTheTransactionAsksTheServer() {
        #expect(OracleTransactionRole.procedural.mayEndTransactionWhenRefused)
        #expect(OracleTransactionRole.dataDefinition.mayEndTransactionWhenRefused)
        #expect(OracleTransactionRole.endsTransaction.mayEndTransactionWhenRefused)
        #expect(!OracleTransactionRole.other.mayEndTransactionWhenRefused)
        #expect(!OracleTransactionRole.query.mayEndTransactionWhenRefused)
        #expect(!OracleTransactionRole.opensTransaction.mayEndTransactionWhenRefused)
    }

    @Test func testSessionAndSystemControlCommitNothing() {
        for sql in [
            "ALTER SESSION SET CURRENT_SCHEMA = \"HR\"",
            "alter session set nls_date_format = 'YYYY-MM-DD'",
            "/* switch */ ALTER SESSION SET CURRENT_SCHEMA = hr",
            "ALTER SYSTEM FLUSH SHARED_POOL",
            "SET ROLE ALL",
        ] {
            #expect(OracleTransactionRole(of: sql) == .other, "\(sql)")
        }
    }

    @Test func testEverythingElseIsOrdinaryWork() {
        for sql in [
            "INSERT INTO emp VALUES (1)",
            "UPDATE emp SET sal = sal * 2",
            "DELETE FROM emp",
            "MERGE INTO emp USING dual ON (1 = 1) WHEN MATCHED THEN UPDATE SET sal = 1",
            "ALTER SESSION SET CURRENT_SCHEMA = hr",
            "SET ROLE ALL",
            "LOCK",
            "EXPLAIN PLAN FOR SELECT 1 FROM dual",
            "",
            "   ",
        ] {
            #expect(OracleTransactionRole(of: sql) == .other, "\(sql)")
        }
    }
}
