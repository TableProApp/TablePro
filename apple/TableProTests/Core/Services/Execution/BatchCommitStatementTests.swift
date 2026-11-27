//
//  BatchCommitStatementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct BatchCommitStatementTests {
    private static func matches(_ sql: String, type: DatabaseType = .postgresql) -> Bool {
        BatchCommitStatement.matches(sql, grammar: type.lexicalGrammar)
    }

    @Test(
        "Every spelling of a commit is a commit point",
        arguments: [
            "COMMIT",
            "commit",
            "COMMIT;",
            "COMMIT WORK",
            "COMMIT TRANSACTION",
            "COMMIT TRAN",
            "COMMIT AND CHAIN",
            "COMMIT PREPARED 'tx1'",
            "  \n COMMIT ",
            "-- save it\nCOMMIT",
            "/* save it */ COMMIT",
        ]
    )
    func commitSpellingsAreCommitPoints(sql: String) {
        #expect(Self.matches(sql))
    }

    /// `END` commits on PostgreSQL and SQLite, so it counts.
    @Test("END on its own ends the transaction", arguments: ["END", "END;", "END WORK", "END TRANSACTION"])
    func endIsACommitPoint(sql: String) {
        #expect(Self.matches(sql))
    }

    @Test("Teradata's ET is a commit point", arguments: ["ET", "et", "ET;", "-- done\nET"])
    func teradataETIsACommitPoint(sql: String) {
        #expect(Self.matches(sql, type: .teradata))
    }

    @Test("ET followed by anything is not ET, and ET is only Teradata's")
    func etWithAFollowerIsNotACommitPoint() {
        #expect(Self.matches("ET AL", type: .teradata) == false)
        #expect(Self.matches("ET") == false)
        #expect(Self.matches("ET", type: .mysql) == false)
    }

    /// A block terminator is never a transaction's end, whichever engine wrote it.
    @Test(
        "END that closes a block is not a commit point",
        arguments: ["END IF", "END LOOP", "END CASE", "END WHILE", "END REPEAT"]
    )
    func endOfABlockIsNotACommitPoint(sql: String) {
        #expect(Self.matches(sql) == false)
    }

    @Test(
        "Ordinary statements are not commit points",
        arguments: [
            "INSERT INTO t VALUES (1)",
            "SELECT 1",
            "ROLLBACK",
            "ROLLBACK TO SAVEPOINT s",
            "BEGIN",
            "START TRANSACTION",
            "RELEASE SAVEPOINT s",
            "",
        ]
    )
    func ordinaryStatementsAreNotCommitPoints(sql: String) {
        #expect(Self.matches(sql) == false)
    }

    /// The word has to open the statement. A commit named inside one is data, not control.
    @Test(
        "A commit named inside another statement is not a commit point",
        arguments: [
            "SELECT 'COMMIT'",
            "INSERT INTO log (action) VALUES ('COMMIT')",
            "SELECT commit_ts FROM t",
        ]
    )
    func committedTextIsNotACommitPoint(sql: String) {
        #expect(Self.matches(sql) == false)
    }

    /// MySQL runs the body of a conditional comment, so a commit written in one is a real commit.
    @Test("A commit inside a MySQL conditional comment is a commit point")
    func conditionalCommentCommitIsACommitPoint() {
        #expect(Self.matches("/*!40101 COMMIT */", type: .mysql))
    }
}

struct TransactionEndStatementTests {
    private static func matches(_ sql: String) -> Bool {
        TransactionEndStatement.matches(sql, grammar: DatabaseType.teradata.lexicalGrammar)
    }

    @Test(
        "A commit or a rollback ends the transaction",
        arguments: [
            "COMMIT", "COMMIT WORK", "ET", "END TRANSACTION", "ROLLBACK", "ROLLBACK WORK", "rollback;", "ABORT",
            "ABORT 'bad load' WHERE 1 = 1",
        ]
    )
    func endsTheTransaction(sql: String) {
        #expect(Self.matches(sql))
    }

    @Test(
        "Anything else leaves it open",
        arguments: [
            "ROLLBACK TO SAVEPOINT s", "BT", "BEGIN TRANSACTION", "INSERT INTO t VALUES (1)", "SELECT 'ROLLBACK'",
            "CREATE TABLE t (a INTEGER)", "",
        ]
    )
    func leavesTheTransactionOpen(sql: String) {
        #expect(Self.matches(sql) == false)
    }
}
