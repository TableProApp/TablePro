//
//  ConnectionDisconnectActionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ConnectionDisconnectActionTests {
    @Test("No open transaction adds nothing to the disconnect prompt")
    func noTransactionNoMessage() {
        #expect(ConnectionDisconnectAction.transactionMessage(for: []) == nil)
    }

    @Test("One open transaction names its database")
    func oneTransactionNamesTheDatabase() throws {
        let message = try #require(ConnectionDisconnectAction.transactionMessage(for: ["app"]))
        #expect(message.contains("“app”"))
        #expect(message.contains("Disconnecting rolls it back"))
    }

    @Test("Several open transactions list every database")
    func severalTransactionsListEveryDatabase() throws {
        let message = try #require(ConnectionDisconnectAction.transactionMessage(for: ["app", "logs"]))
        #expect(message.contains("“app”"))
        #expect(message.contains("“logs”"))
        #expect(message.contains("Disconnecting rolls them back"))
    }

    @Test("A clean connection disconnects without asking")
    func cleanConnectionAsksNothing() {
        #expect(ConnectionDisconnectAction.confirmationMessage(holdingTransaction: [], hasUnsavedWork: false) == nil)
        #expect(ConnectionDisconnectAction.otherLosses(holdingTransaction: [], hasUnsavedWork: false).isEmpty)
    }

    @Test("With running work, the transaction and the unsaved changes join the same alert")
    func lossesJoinTheRunningWorkAlert() {
        let losses = ConnectionDisconnectAction.otherLosses(holdingTransaction: ["app"], hasUnsavedWork: true)

        #expect(losses == ["Open transaction in “app”", "Unsaved changes"])
    }

    @Test("Without running work, an open transaction is asked about before unsaved changes")
    func transactionOutranksUnsavedWork() throws {
        let message = try #require(
            ConnectionDisconnectAction.confirmationMessage(holdingTransaction: ["app"], hasUnsavedWork: true)
        )
        #expect(message.contains("open transaction"))
    }
}
