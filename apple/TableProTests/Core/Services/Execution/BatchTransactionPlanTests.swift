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

    @Test("The app's own plan and a held one send BEGIN, and only the app's own sends COMMIT")
    func onlyTheAppPlanCommits() {
        #expect(BatchTransactionPlan.appTransaction.sendsBegin)
        #expect(BatchTransactionPlan.appTransaction.commitsAtEnd)
        #expect(BatchTransactionPlan.heldTransaction.sendsBegin)
        #expect(BatchTransactionPlan.heldTransaction.commitsAtEnd == false)
        for plan in [BatchTransactionPlan.scriptTransaction, .autocommit, .sessionTransaction] {
            #expect(plan.sendsBegin == false)
            #expect(plan.commitsAtEnd == false)
        }
    }

    @Test("A joined run rolls nothing back and keeps what ran, exactly as autocommit does")
    func joinedRunTakesNothingBack() {
        #expect(BatchTransactionPlan.sessionTransaction.rollsBackAfterStop == false)
        #expect(BatchTransactionPlan.sessionTransaction.keepsExecutedStatements)
    }

    @Test("A held run rolls back on a failure or a Stop and reads what it left open")
    func heldRunRollsBackAndReadsItsEnd() {
        #expect(BatchTransactionPlan.heldTransaction.rollsBackAfterStop)
        #expect(BatchTransactionPlan.heldTransaction.keepsExecutedStatements == false)
        #expect(BatchTransactionPlan.heldTransaction.readsSessionEndState)
        #expect(BatchTransactionPlan.appTransaction.readsSessionEndState == false)
    }

    @Test(
        "A session holding a transaction or a lock takes the plan over, whatever the text said",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks]
    )
    func heldSessionTakesOver(state: PluginSessionTransactionState) {
        for plan in Self.textPlans {
            #expect(plan.joining(state, commitMode: .automatic) == .sessionTransaction)
            #expect(plan.joining(state, commitMode: .manual) == .sessionTransaction)
        }
    }

    @Test("A session with nothing open leaves the plan the text decided")
    func idleSessionChangesNothing() {
        for plan in Self.textPlans {
            #expect(plan.joining(.idle, commitMode: .automatic) == plan)
        }
    }

    @Test("Manual Commit holds a wrapped batch on an idle session, and nothing else")
    func manualCommitHoldsOnlyAWrappedBatchOnAnIdleSession() {
        #expect(BatchTransactionPlan.appTransaction.joining(.idle, commitMode: .manual) == .heldTransaction)
        #expect(BatchTransactionPlan.appTransaction.joining(.unknown, commitMode: .manual) == .appTransaction)
        #expect(BatchTransactionPlan.scriptTransaction.joining(.idle, commitMode: .manual) == .scriptTransaction)
        #expect(BatchTransactionPlan.autocommit.joining(.idle, commitMode: .manual) == .autocommit)
    }

    /// The wrap stays for a plain batch, because its atomicity is worth more than a transaction that
    /// may not be there. A self-managed script stops being rolled back, because the transaction its
    /// text left open may predate the run.
    @Test("A session that cannot say keeps the wrap but stops the rollback of a self-managed script")
    func unknownSessionKeepsTheWrapButNotTheRollback() {
        #expect(BatchTransactionPlan.appTransaction.joining(.unknown, commitMode: .automatic) == .appTransaction)
        #expect(BatchTransactionPlan.autocommit.joining(.unknown, commitMode: .automatic) == .autocommit)
        #expect(BatchTransactionPlan.scriptTransaction.joining(.unknown, commitMode: .automatic) == .sessionTransaction)
    }

    @Test("Joining is settled once: a joined plan stays joined")
    func joinedPlanStaysJoined() {
        for state in [
            PluginSessionTransactionState.idle, .inTransaction, .abortedTransaction, .holdsSessionLocks, .unknown,
        ] {
            #expect(BatchTransactionPlan.sessionTransaction.joining(state, commitMode: .manual) == .sessionTransaction)
        }
    }

    @Test("A held run is never recorded as committed")
    func heldRunIsNotCommitted() {
        let completed = StatementCommitEvidence.run(
            startedIn: .idle, endedIn: .inTransaction, plan: .heldTransaction, completed: true
        )
        let failed = StatementCommitEvidence.run(
            startedIn: .idle, endedIn: .idle, plan: .heldTransaction, completed: false
        )
        #expect(completed == .runStartedIn(.idle, endedIn: .inTransaction, appTransaction: .none))
        #expect(failed == .runStartedIn(.idle, endedIn: .idle, appTransaction: .rolledBack))
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
