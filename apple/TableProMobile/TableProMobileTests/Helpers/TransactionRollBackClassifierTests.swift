import Foundation
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
            "ROLLBACK AND CHAIN",
            "rollback work and no chain",
            "ROLLBACK RELEASE",
            "ABORT",
        ]
    )
    func wholeTransactionRollBacks(_ sql: String) {
        #expect(TransactionRollBackClassifier.rollsBackTransaction(sql))
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
        #expect(!TransactionRollBackClassifier.rollsBackTransaction(sql))
    }

    @Test("A PostgreSQL COMMIT the server answered by rolling back counts as a Roll Back")
    func commitRolledBackByPostgreSQL() {
        #expect(TransactionRollBackClassifier.rollsBackTransaction(
            "COMMIT",
            statusMessage: PostgreSQLSessionTransaction.failedTransactionRolledBackMessage
        ))
        #expect(!TransactionRollBackClassifier.rollsBackTransaction("COMMIT", statusMessage: "COMMIT"))
    }
}
