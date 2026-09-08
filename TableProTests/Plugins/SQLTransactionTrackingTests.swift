//
//  SQLTransactionTrackingTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit

@Suite("SQL transaction tracking")
struct SQLTransactionTrackingTests {
    @Test("Every spelling that opens a transaction is recognised")
    func recognisesOpeningStatements() {
        for sql in ["BEGIN", "BEGIN TRANSACTION", "START TRANSACTION", "begin transaction", "  BEGIN  "] {
            #expect(SQLTransactionTracking.effect(of: sql) == .opens, "\(sql)")
        }
    }

    @Test("Every spelling that ends a transaction is recognised")
    func recognisesClosingStatements() {
        for sql in ["COMMIT", "ROLLBACK", "ABORT", "END", "end transaction", "commit;"] {
            #expect(SQLTransactionTracking.effect(of: sql) == .closes, "\(sql)")
        }
    }

    @Test("An ordinary statement changes nothing")
    func ordinaryStatementsAreUnchanged() {
        for sql in ["SELECT 1", "INSERT INTO t VALUES (1)", "CREATE TABLE t(a INT)", "", "   "] {
            #expect(SQLTransactionTracking.effect(of: sql) == .unchanged, "\(sql)")
        }
    }

    /// Measured on the shipped DuckDB: a multi-statement batch reports the type of its LAST
    /// statement, so `BEGIN; INSERT INTO z VALUES (2);` comes back typed as INSERT while a
    /// transaction is genuinely left open. The engine's own classification cannot be trusted for
    /// this, which is why the text is walked instead.
    @Test("A batch is judged by the last transaction statement in it, not by the engine's type")
    func batchesAreWalkedInOrder() {
        #expect(SQLTransactionTracking.effect(of: "BEGIN; INSERT INTO z VALUES (1); COMMIT;") == .closes)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; INSERT INTO z VALUES (2);") == .opens)
        #expect(SQLTransactionTracking.effect(of: "COMMIT; BEGIN;") == .opens)
        #expect(SQLTransactionTracking.effect(of: "INSERT INTO z VALUES (1); SELECT 1;") == .unchanged)
    }

    /// `END` closes a transaction as a statement head and means nothing of the kind inside a
    /// `CASE`. A `CASE ... END` in a select must not read as a commit, or a release would follow
    /// it and roll the real transaction back.
    @Test("END inside an expression is not a statement head")
    func caseExpressionsAreNotTransactionEnds() {
        let sql = "SELECT CASE WHEN a > 1 THEN 'x' ELSE 'y' END FROM t"
        #expect(SQLTransactionTracking.effect(of: sql) == .unchanged)
    }

    /// Splitting on `;` cuts a string literal in half, so a fragment can start with a transaction
    /// keyword without being one. Reading that as a close is the dangerous direction: it clears the
    /// flag protecting a real transaction, and the release that follows rolls the transaction back.
    /// So closing requires the whole statement to be a transaction statement, while opening needs
    /// only the first word.
    @Test("A transaction keyword inside a literal never reads as a commit")
    func aLiteralNeverClosesATransaction() {
        #expect(SQLTransactionTracking.effect(of: "SELECT 'a; COMMIT '") == .unchanged)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; SELECT 'x; ROLLBACK '") == .opens)
        #expect(SQLTransactionTracking.effect(of: "INSERT INTO t VALUES ('a; END ')") == .unchanged)
    }

    /// The other direction, which must not be lost: a real transaction statement after a literal
    /// carrying a semicolon is still seen.
    @Test("A real transaction statement after a literal is still seen")
    func aRealStatementAfterALiteralIsSeen() {
        #expect(SQLTransactionTracking.effect(of: "SELECT 'a;b'; BEGIN") == .opens)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; INSERT INTO t VALUES ('a;b'); COMMIT") == .closes)
    }

    /// The finding that made the splitter literal-aware. A raw `;` split turns `SELECT ';COMMIT;'`
    /// into `SELECT '`, `COMMIT` and `'`, and that middle fragment is an exact `COMMIT`: reading it
    /// as one clears the flag protecting a real transaction, and the release that follows rolls the
    /// transaction back.
    @Test("A semicolon inside a literal does not end a statement")
    func semicolonsInsideLiteralsAreNotSeparators() {
        #expect(SQLTransactionTracking.effect(of: "SELECT ';COMMIT;'") == .unchanged)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; SELECT ';COMMIT;'") == .opens)
        #expect(SQLTransactionTracking.effect(of: "SELECT \";COMMIT;\"") == .unchanged)
        #expect(SQLTransactionTracking.effect(of: "SELECT `a;COMMIT;b`") == .unchanged)
    }

    @Test("A comment in front of a statement does not hide its keyword")
    func leadingCommentsDoNotHideTheKeyword() {
        #expect(SQLTransactionTracking.effect(of: "-- start work\nBEGIN") == .opens)
        #expect(SQLTransactionTracking.effect(of: "/* wrap up */ COMMIT") == .closes)
        #expect(SQLTransactionTracking.effect(of: "BEGIN; -- note; with a semicolon\nSELECT 1") == .opens)
    }

    @Test("A close is recognised with its optional TRANSACTION or WORK suffix")
    func closingSuffixesAreRecognised() {
        for sql in ["COMMIT TRANSACTION", "COMMIT WORK", "ROLLBACK WORK", "END TRANSACTION", "abort transaction"] {
            #expect(SQLTransactionTracking.effect(of: sql) == .closes, "\(sql)")
        }
    }
}
