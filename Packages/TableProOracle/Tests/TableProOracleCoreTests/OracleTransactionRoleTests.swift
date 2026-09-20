@testable import TableProOracleCore
import XCTest

/// Whether a statement commits as it runs is decided from its first words, so a misread one either leaves a write
/// uncommitted or commits away a savepoint or a lock the user meant to hold.
final class OracleTransactionRoleTests: XCTestCase {
    func testQueriesAreReadsWhateverLeadsThem() {
        for sql in [
            "SELECT * FROM emp",
            "select 1 from dual",
            "WITH t AS (SELECT 1 a FROM dual) SELECT a FROM t",
            "SELECT * FROM emp FOR UPDATE",
            "-- latest hires\nSELECT * FROM emp",
            "/* report */ SELECT 1 FROM dual",
        ] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .query, sql)
        }
    }

    func testStatementsThatOnlyMeanSomethingInsideATransactionOpenOne() {
        for sql in [
            "SAVEPOINT before_raise",
            "savepoint a",
            "SET TRANSACTION READ ONLY",
            "set transaction isolation level serializable",
            "SET TRANSACTION NAME 'nightly'",
            "LOCK TABLE emp IN EXCLUSIVE MODE",
            "-- hold it\nLOCK TABLE emp IN SHARE MODE NOWAIT",
        ] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .opensTransaction, sql)
        }
    }

    func testCommitAndAFullRollbackEndTheTransaction() {
        for sql in [
            "COMMIT",
            "commit work",
            "COMMIT COMMENT 'nightly load'",
            "COMMIT WRITE BATCH NOWAIT",
            "ROLLBACK",
            "rollback work",
            "/* undo */ ROLLBACK",
        ] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .endsTransaction, sql)
        }
    }

    func testARollbackToASavepointKeepsTheTransactionOpen() {
        for sql in ["ROLLBACK TO before_raise", "ROLLBACK TO SAVEPOINT a", "rollback work to savepoint a"] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .other, sql)
        }
    }

    func testSettlingAnInDoubtDistributedTransactionLeavesTheSessionsOwnAlone() {
        for sql in ["COMMIT FORCE '1.2.3'", "commit work force '1.2.3', 42", "ROLLBACK FORCE '1.2.3'", "ROLLBACK WORK FORCE '1.2.3'"] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .other, sql)
        }
    }

    func testAVeryLongStatementIsReadFromItsHead() {
        let values = Array(repeating: "(1)", count: 500_000).joined(separator: ", ")
        XCTAssertEqual(OracleTransactionRole(of: "INSERT INTO t VALUES \(values)"), .other)
        XCTAssertEqual(OracleTransactionRole(of: "SELECT \(values) FROM dual"), .query)
    }

    func testEverythingElseIsOrdinaryWork() {
        for sql in [
            "INSERT INTO emp VALUES (1)",
            "UPDATE emp SET sal = sal * 2",
            "DELETE FROM emp",
            "MERGE INTO emp USING dual ON (1 = 1) WHEN MATCHED THEN UPDATE SET sal = 1",
            "CREATE TABLE t (a NUMBER)",
            "BEGIN NULL; END;",
            "DECLARE v NUMBER; BEGIN v := 1; END;",
            "CALL p()",
            "ALTER SESSION SET CURRENT_SCHEMA = hr",
            "SET ROLE ALL",
            "LOCK",
            "EXPLAIN PLAN FOR SELECT 1 FROM dual",
            "",
            "   ",
        ] {
            XCTAssertEqual(OracleTransactionRole(of: sql), .other, sql)
        }
    }
}
