//
//  QuitTransactionPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QuitTransactionPromptTests {
    @Test("Quit names the connection holding a transaction and offers Quit Anyway")
    func quitNamesTheOpenTransaction() throws {
        let prompt = try #require(QuitApproval.transactionPrompt(action: .quit, connections: ["Prod"], hasUnsavedTabs: false))
        #expect(prompt.title == "Quit with an Open Transaction?")
        #expect(prompt.message == "Uncommitted changes on “Prod” are rolled back when TablePro quits.")
        #expect(prompt.confirmButton == "Quit Anyway")
    }

    @Test("Unsaved tabs ride along on the transaction question rather than asking again")
    func unsavedTabsRideAlong() throws {
        let prompt = try #require(QuitApproval.transactionPrompt(action: .quit, connections: ["Prod"], hasUnsavedTabs: true))
        #expect(prompt.message.hasSuffix("Some tabs have unsaved edits. Quitting will discard these changes."))
    }

    @Test("No open transaction asks nothing")
    func noTransactionAsksNothing() {
        #expect(QuitApproval.transactionPrompt(action: .quit, connections: [], hasUnsavedTabs: true) == nil)
    }

    @Test("Each connection holding a transaction is named once, whatever its lanes")
    func holdsAreNamedOncePerConnection() {
        let prod = UUID()
        let staging = UUID()
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: QuitStubDriver())
        let tracker = SessionTransactionTracker { _, _ in true }
        tracker.record(.inTransaction, on: driver, for: .init(connectionId: prod, lane: "sales"))
        tracker.record(.abortedTransaction, on: driver, for: .init(connectionId: prod, lane: "hr"))
        tracker.record(.inTransaction, on: driver, for: .init(connectionId: staging, lane: nil))
        let names = [prod: "Prod", staging: "Staging"]

        let named = QuitApproval.openTransactionNames(
            holds: Array(tracker.holds.values),
            connectionName: { names[$0] }
        )

        #expect(named == ["Prod", "Staging"])
    }
}

private final class QuitStubDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
}
