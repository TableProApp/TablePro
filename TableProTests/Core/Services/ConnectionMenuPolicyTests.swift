//
//  ConnectionMenuPolicyTests.swift
//  TableProTests
//
//  A context menu shows only what applies to the row it was opened on, so Disconnect is absent on a
//  workspace with no live session rather than present and dimmed.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection menu policy")
struct ConnectionMenuPolicyTests {
    @Test("Disconnect is offered for a live session")
    func offeredWhenConnected() {
        #expect(ConnectionMenuPolicy.showsDisconnect(status: .connected))
    }

    @Test("Disconnect is hidden for every state without a live session")
    func hiddenWithoutLiveSession() {
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .disconnected))
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .connecting))
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .error("refused")))
    }
}
