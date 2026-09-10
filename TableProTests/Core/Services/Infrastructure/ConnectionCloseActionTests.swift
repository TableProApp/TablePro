//
//  ConnectionCloseActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection close decision")
@MainActor
struct ConnectionCloseActionTests {
    /// The case the old command failed on. A connection the window hosts but that has no session
    /// yet still has a rail row, and Close on it resolved no coordinator and returned in silence.
    /// There is nothing to lose there, so it closes without asking rather than doing nothing.
    @Test("A connection with no session closes without asking")
    func sessionlessClosesImmediately() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, hasUnsavedWork: false) == .closeImmediately
        )
    }

    /// Unsaved work reported for a connection that has no session cannot be acted on, so it must
    /// not gate the close behind an alert whose Save button has nothing to call.
    @Test("Unsaved work without a session still closes without asking")
    func sessionlessIgnoresUnsavedWork() {
        #expect(
            ConnectionCloseAction.decision(hasSession: false, hasUnsavedWork: true) == .closeImmediately
        )
    }

    @Test("A clean connection closes without asking")
    func cleanSessionClosesImmediately() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasUnsavedWork: false) == .closeImmediately
        )
    }

    @Test("A connection with unsaved work asks first")
    func unsavedWorkIsConfirmed() {
        #expect(
            ConnectionCloseAction.decision(hasSession: true, hasUnsavedWork: true) == .confirmUnsavedWork
        )
    }
}
