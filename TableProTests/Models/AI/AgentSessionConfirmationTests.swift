//
//  AgentSessionConfirmationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AgentSessionConfirmationTests {
    /// Closing keeps the conversation, so an idle session is closed without a question. A busy one
    /// loses the reply or the statement it is holding, which is the part worth asking about.
    @Test("Closing asks about a busy session and about no other")
    func closingAsksOnlyWhenBusy() {
        for status in AgentSessionStatus.allCases {
            let confirmation = AgentSessionConfirmation.close("Late orders", status: status)
            #expect((confirmation != nil) == status.isBusy, "\(status)")
        }
    }

    @Test("A busy session's question names what it is doing")
    func closingNamesTheActivity() throws {
        let working = try #require(AgentSessionConfirmation.close("Late orders", status: .working))
        let waiting = try #require(AgentSessionConfirmation.close("Late orders", status: .waitingOnYou))

        #expect(working.title.contains("Late orders"))
        #expect(working.message != waiting.message)
        #expect(!working.isDestructive, "Closing keeps the conversation, so it is not the destructive shape")
        #expect(waiting.confirmButton == working.confirmButton, "One command, one button")
    }

    @Test("Deleting always asks, and says the conversation goes with it")
    func deletingAlwaysAsks() {
        let statuses = AgentSessionStatus.allCases
        let messages = Set(statuses.map { AgentSessionConfirmation.delete("Late orders", status: $0).message })

        for status in statuses {
            let confirmation = AgentSessionConfirmation.delete("Late orders", status: status)
            #expect(confirmation.title.contains("Late orders"), "\(status)")
            #expect(confirmation.isDestructive, "\(status)")
            #expect(!confirmation.message.isEmpty, "\(status)")
        }
        #expect(messages.count == 3, "Working, waiting on you and idle are three different questions")
    }

    /// The busy wording says the reply or the statement is stopped, which is the only warning a
    /// person gets before a session mid-reply is deleted.
    @Test("Deleting a busy session says what it stops")
    func deletingNamesWhatItStops() {
        let working = AgentSessionConfirmation.delete("Late orders", status: .working)
        let waiting = AgentSessionConfirmation.delete("Late orders", status: .waitingOnYou)
        let ready = AgentSessionConfirmation.delete("Late orders", status: .ready)

        #expect(working.message != ready.message)
        #expect(waiting.message != ready.message)
        #expect(working.message != waiting.message)
    }
}
