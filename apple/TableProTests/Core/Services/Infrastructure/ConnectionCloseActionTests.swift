//
//  ConnectionCloseActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionCloseActionTests {
    // A connection the window hosts with no session yet still has a rail row; Close on it once did nothing.
    @Test("A connection with no session closes without asking")
    func sessionlessClosesImmediately() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, hasRunningWork: false, hasUnsavedWork: false) == .closeImmediately
        )
    }

    @Test("Unsaved work without a session still closes without asking")
    func sessionlessIgnoresUnsavedWork() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, hasRunningWork: false, hasUnsavedWork: true) == .closeImmediately
        )
    }

    @Test("Running work is asked about even without a session")
    func sessionlessStillAsksAboutRunningWork() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, hasRunningWork: true, hasUnsavedWork: false) == .confirmRunningWork
        )
    }

    // The transaction is read after the answers, so with nothing else to ask it is the next step.
    @Test("A clean connection goes straight to the transaction step")
    func cleanSessionReadsTheTransaction() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasRunningWork: false, hasUnsavedWork: false)
                == .confirmEndingTransaction
        )
    }

    @Test("Running work with nothing unsaved gets its own alert")
    func runningWorkIsConfirmed() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasRunningWork: true, hasUnsavedWork: false) == .confirmRunningWork
        )
    }

    // A Save under Manual Commit writes into a held transaction, which the close must still ask about after it.
    @Test("Unsaved work is asked before the transaction, and names the running work on the same alert")
    func unsavedWorkComesFirst() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasRunningWork: false, hasUnsavedWork: true) == .confirmUnsavedWork
        )
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasRunningWork: true, hasUnsavedWork: true) == .confirmUnsavedWork
        )
    }
}
