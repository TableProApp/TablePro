//
//  ConnectionMenuPolicyTests.swift
//  TableProTests
//
//  A context menu shows only what applies to the row it was opened on, so Disconnect is absent on a
//  workspace with nothing to end rather than present and dimmed.
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

struct ConnectionMenuPolicyTests {
    @Test("Disconnect is offered while a session holds its driver", arguments: [
        ConnectionDisplayStatus.connected,
        .reconnecting(attempt: 2, of: 10),
        .lost(cause: "Server closed the connection."),
    ])
    func offeredWhileTheDriverIsHeld(_ status: ConnectionDisplayStatus) {
        #expect(ConnectionMenuPolicy.showsDisconnect(status: status, holdsSession: true))
    }

    @Test("Disconnect is hidden for every state with nothing to end", arguments: [
        ConnectionDisplayStatus.notConnected,
        .connecting,
        .failed(cause: "refused"),
    ])
    func hiddenWithoutADriver(_ status: ConnectionDisplayStatus) {
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: status, holdsSession: true))
    }

    @Test("A lost connection whose session entry is gone offers no Disconnect")
    func lostWithoutASessionHidesDisconnect() {
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .lost(cause: nil), holdsSession: false))
    }

    @Test("The row's primary command follows its state", arguments: [
        (ConnectionDisplayStatus.notConnected, ConnectionStatusAction?.some(.connect)),
        (.failed(cause: nil), .connect),
        (.lost(cause: nil), .reconnect),
        (.connecting, .cancel),
        (.reconnecting(attempt: 1, of: 10), .cancel),
        (.connected, nil),
    ])
    func primaryActionFollowsTheState(_ status: ConnectionDisplayStatus, _ action: ConnectionStatusAction?) {
        #expect(ConnectionMenuPolicy.primaryAction(status: status) == action)
    }

    @Test("Each command is titled for what it does")
    func primaryActionTitles() {
        #expect(ConnectionStatusPresentation(.notConnected).primaryActionTitle == "Connect")
        #expect(ConnectionStatusPresentation(.lost(cause: nil)).primaryActionTitle == "Reconnect")
        #expect(ConnectionStatusPresentation(.connecting).primaryActionTitle == "Stop Connecting")
        #expect(ConnectionStatusPresentation(.reconnecting(attempt: 1, of: 10)).primaryActionTitle == "Stop Reconnecting")
        #expect(ConnectionStatusPresentation(.connected).primaryActionTitle == nil)
    }
}
