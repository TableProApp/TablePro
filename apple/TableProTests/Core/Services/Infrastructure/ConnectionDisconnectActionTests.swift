//
//  ConnectionDisconnectActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionDisconnectActionTests {
    @Test("A clean connection disconnects without asking")
    func cleanConnectionAsksNothing() {
        #expect(ConnectionDisconnectAction.confirmationMessage(hasUnsavedWork: false) == nil)
        #expect(ConnectionDisconnectAction.otherLosses(hasUnsavedWork: false).isEmpty)
    }

    // The transaction gets its own alert after this one, with Commit, so it never rides along here.
    @Test("With running work, only the unsaved changes join the running-work alert")
    func unsavedChangesJoinTheRunningWorkAlert() {
        #expect(ConnectionDisconnectAction.otherLosses(hasUnsavedWork: true) == ["Unsaved changes"])
    }

    @Test("Unsaved changes alone are asked about")
    func unsavedChangesAreConfirmed() {
        #expect(ConnectionDisconnectAction.confirmationMessage(hasUnsavedWork: true) == "Unsaved changes will be lost.")
    }
}
