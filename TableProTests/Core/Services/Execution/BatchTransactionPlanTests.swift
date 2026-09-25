//
//  BatchTransactionPlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct BatchTransactionPlanTests {
    private static let textPlans: [BatchTransactionPlan] = [.appTransaction, .scriptTransaction, .autocommit]

    @Test("Only the app's own plan opens a transaction")
    func onlyTheAppPlanOpensOne() {
        #expect(BatchTransactionPlan.appTransaction.opensTransaction)
        #expect(BatchTransactionPlan.scriptTransaction.opensTransaction == false)
        #expect(BatchTransactionPlan.autocommit.opensTransaction == false)
        #expect(BatchTransactionPlan.sessionTransaction.opensTransaction == false)
    }

    @Test("A joined run rolls nothing back and keeps what ran, exactly as autocommit does")
    func joinedRunTakesNothingBack() {
        #expect(BatchTransactionPlan.sessionTransaction.rollsBackAfterStop == false)
        #expect(BatchTransactionPlan.sessionTransaction.keepsExecutedStatements)
    }

    @Test(
        "A session holding a transaction or a lock takes the plan over, whatever the text said",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func heldSessionTakesOver(state: PluginSessionTransactionState) {
        for plan in Self.textPlans {
            #expect(plan.joining(state) == .sessionTransaction)
        }
    }

    @Test("A session with nothing open leaves the plan the text decided")
    func idleSessionChangesNothing() {
        for plan in Self.textPlans {
            #expect(plan.joining(.idle) == plan)
        }
    }

    /// The wrap stays for a plain batch, because its atomicity is worth more than a transaction that
    /// may not be there. A self-managed script stops being rolled back, because the transaction its
    /// text left open may predate the run.
    @Test("A session that cannot say keeps the wrap but stops the rollback of a self-managed script")
    func unknownSessionKeepsTheWrapButNotTheRollback() {
        #expect(BatchTransactionPlan.appTransaction.joining(.unknown) == .appTransaction)
        #expect(BatchTransactionPlan.autocommit.joining(.unknown) == .autocommit)
        #expect(BatchTransactionPlan.scriptTransaction.joining(.unknown) == .sessionTransaction)
    }

    @Test("Joining is settled once: a joined plan stays joined")
    func joinedPlanStaysJoined() {
        for state in [
            PluginSessionTransactionState.idle, .inTransaction, .abortedTransaction, .holdsSessionLocks, .unknown,
        ] {
            #expect(BatchTransactionPlan.sessionTransaction.joining(state) == .sessionTransaction)
        }
    }
}

struct SessionTransactionStateTests {
    @Test(
        "Nothing the app owns opens a transaction over one the session is holding",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func heldSessionPermitsNothing(state: PluginSessionTransactionState) {
        #expect(state.permitsAppTransaction == false)
    }

    @Test("An idle session, and one that cannot say, both permit the app's own transaction")
    func idleAndUnknownPermitOne() {
        #expect(PluginSessionTransactionState.idle.permitsAppTransaction)
        #expect(PluginSessionTransactionState.unknown.permitsAppTransaction)
    }

    @Test("An aborted transaction is never told to commit, because a commit there discards the work")
    func abortedTransactionSaysRollBackOnly() {
        let aborted = PluginSessionTransactionState.abortedTransaction.openTransactionNotice
        #expect(aborted == "The transaction on this connection can no longer be committed. Roll it back.")

        let open = PluginSessionTransactionState.inTransaction.openTransactionNotice
        #expect(open == "The transaction on this connection is still open. Commit or roll it back.")
    }

    @Test("A session holding no transaction says nothing about one")
    func nothingIsSaidWithoutATransaction() {
        #expect(PluginSessionTransactionState.idle.openTransactionNotice == nil)
        #expect(PluginSessionTransactionState.holdsSessionLocks.openTransactionNotice == nil)
        #expect(PluginSessionTransactionState.unknown.openTransactionNotice == nil)
    }
}
