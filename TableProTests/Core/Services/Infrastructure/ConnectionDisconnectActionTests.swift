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
}
