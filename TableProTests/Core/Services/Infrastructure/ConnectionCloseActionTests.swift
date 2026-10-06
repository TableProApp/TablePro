//
//  ConnectionCloseActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionCloseActionTests {
    /// The case the old command failed on. A connection the window hosts but that has no session
    /// yet still has a rail row, and Close on it resolved no coordinator and returned in silence.
    /// There is nothing to lose there, so it closes without asking rather than doing nothing.
    @Test("A connection with no session closes without asking")
    func sessionlessClosesImmediately() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, holdsTransaction: false, hasUnsavedWork: false) == .closeImmediately
        )
    }

    /// Unsaved work reported for a connection that has no session cannot be acted on, so it must
    /// not gate the close behind an alert whose Save button has nothing to call.
    @Test("Unsaved work without a session still closes without asking")
    func sessionlessIgnoresUnsavedWork() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, holdsTransaction: false, hasUnsavedWork: true) == .closeImmediately
        )
    }

    @Test("A clean connection closes without asking")
    func cleanSessionClosesImmediately() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, holdsTransaction: false, hasUnsavedWork: false) == .closeImmediately
        )
    }

    @Test("A connection with unsaved work asks first")
    func unsavedWorkIsConfirmed() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, holdsTransaction: false, hasUnsavedWork: true) == .confirmUnsavedWork
        )
    }

    /// Closing ends the session connection, and the server rolls back what it was holding.
    @Test("A connection holding an open transaction asks first")
    func openTransactionIsConfirmed() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, holdsTransaction: true, hasUnsavedWork: false)
                == .confirmEndingTransaction
        )
    }

    /// Save on the unsaved-work alert writes at once, so the transaction has to be asked about
    /// while a Cancel can still leave everything as it was.
    @Test("An open transaction is asked about before unsaved work")
    func openTransactionComesBeforeUnsavedWork() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, holdsTransaction: true, hasUnsavedWork: true)
                == .confirmEndingTransaction
        )
    }

    @Test("A transaction reported without a session still closes without asking")
    func sessionlessIgnoresTransaction() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, holdsTransaction: true, hasUnsavedWork: true)
                == .closeImmediately
        )
    }

    @Test("No open transaction adds nothing to the close prompt")
    func noTransactionNoMessage() {
        #expect(ConnectionCloseAction.transactionMessage(for: []) == nil)
    }

    @Test("One open transaction names its database")
    func oneTransactionNamesTheDatabase() throws {
        let message = try #require(ConnectionCloseAction.transactionMessage(for: ["app"]))
        #expect(message.contains("“app”"))
        #expect(message.contains("Closing rolls it back"))
    }

    @Test("Several open transactions list every database")
    func severalTransactionsListEveryDatabase() throws {
        let message = try #require(ConnectionCloseAction.transactionMessage(for: ["app", "logs"]))
        #expect(message.contains("“app”"))
        #expect(message.contains("“logs”"))
        #expect(message.contains("Closing rolls them back"))
    }
}
