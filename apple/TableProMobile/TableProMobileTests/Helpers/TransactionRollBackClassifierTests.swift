import Foundation
import TableProSQLGrammar
@testable import TableProMobile
import Testing

struct TransactionRollBackClassifierTests {
    @Test(
        "A statement that rolls back the whole transaction is a Roll Back",
        arguments: [
            "ROLLBACK",
            "rollback work",
            "ROLLBACK TRANSACTION",
            "Rollback Tran;",
            "-- note\nROLLBACK",
            "/* undo */ ROLLBACK;",
            "/*/ COMMIT */ ROLLBACK",
            "ROLLBACK AND CHAIN",
            "rollback work and no chain",
            "ROLLBACK RELEASE",
            "ABORT",
        ]
    )
    func wholeTransactionRollBacks(_ sql: String) {
        #expect(TransactionRollBackClassifier.rollsBackTransaction(sql, grammar: .ansi))
    }

    @Test(
        "A savepoint rollback, another transaction, or any other statement is not",
        arguments: [
            "ROLLBACK TO SAVEPOINT a",
            "rollback work to a",
            "ROLLBACK PREPARED 'tx1'",
            "ROLLBACK TRAN sp1",
            "ROLLBACK TRANSACTION @savepoint",
            "COMMIT",
            "SELECT 'ROLLBACK'",
            "-- ROLLBACK\nSELECT 1",
            "ROLLBACK2",
            "",
        ]
    )
    func otherStatements(_ sql: String) {
        #expect(!TransactionRollBackClassifier.rollsBackTransaction(sql, grammar: .ansi))
    }

    @Test("A PostgreSQL COMMIT the server answered by rolling back counts as a Roll Back")
    func commitRolledBackByPostgreSQL() {
        #expect(TransactionRollBackClassifier.rollsBackTransaction(
            "COMMIT",
            grammar: .ansi,
            statusMessage: PostgreSQLSessionTransaction.failedTransactionRolledBackMessage
        ))
        #expect(!TransactionRollBackClassifier.rollsBackTransaction("COMMIT", grammar: .ansi, statusMessage: "COMMIT"))
    }

    @Test("A comment ends where the engine ends it before the ROLLBACK")
    func commentsFollowTheGrammar() throws {
        let mysql = try #require(SQLLexicalProfile.curated(forDatabaseTypeId: "MySQL")).grammar
        let postgreSQL = try #require(SQLLexicalProfile.curated(forDatabaseTypeId: "PostgreSQL")).grammar
        #expect(TransactionRollBackClassifier.rollsBackTransaction("# undo\nROLLBACK", grammar: mysql))
        #expect(TransactionRollBackClassifier.rollsBackTransaction("/* a /* b */ c */ ROLLBACK", grammar: postgreSQL))
        #expect(!TransactionRollBackClassifier.rollsBackTransaction("--x\nROLLBACK", grammar: mysql))
    }
}
