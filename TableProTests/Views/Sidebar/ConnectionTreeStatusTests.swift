//
//  ConnectionTreeStatusTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionTreeStatus")
struct ConnectionTreeStatusTests {
    private let info = ConnectionFailureInfo(message: "boom")

    @Test("A connection no window hosts is simply not connected")
    func noPhaseIsNotConnected() {
        #expect(ConnectionTreeStatus(phase: nil) == .notConnected)
    }

    @Test("The phases map one to one")
    func mapsPhases() {
        #expect(ConnectionTreeStatus(phase: .idle) == .notConnected)
        #expect(ConnectionTreeStatus(phase: .connecting) == .connecting)
        #expect(ConnectionTreeStatus(phase: .connected) == .connected)
        #expect(ConnectionTreeStatus(phase: .closing) == .notConnected)
    }

    @Test("A connect the user called off leaves the row unmarked")
    func cancelledIsNotAFailure() {
        #expect(ConnectionTreeStatus(phase: .unavailable(.cancelled)) == .notConnected)
        #expect(ConnectionTreeStatus(phase: .unavailable(.disconnectedByUser)) == .notConnected)
        #expect(ConnectionTreeStatus(phase: .unavailable(.notConnected)) == .notConnected)
    }

    @Test("A failure the user did not ask for marks the row")
    func failuresShow() {
        #expect(ConnectionTreeStatus(phase: .unavailable(.failed(info))) == .failed)
        #expect(ConnectionTreeStatus(phase: .unavailable(.disconnected(info))) == .failed)
        #expect(ConnectionTreeStatus(phase: .unavailable(.actionRequired(info, .installPlugin))) == .failed)
    }

    @Test("Only a live session has objects under it")
    func onlyConnectedHasObjects() {
        #expect(ConnectionTreeStatus.connected.hasObjects)
        #expect(!ConnectionTreeStatus.notConnected.hasObjects)
        #expect(!ConnectionTreeStatus.connecting.hasObjects)
        #expect(!ConnectionTreeStatus.failed.hasObjects)
    }

    @Test("Connecting again is offered exactly where it makes sense")
    func allowsConnect() {
        #expect(ConnectionTreeStatus.notConnected.allowsConnect)
        #expect(ConnectionTreeStatus.failed.allowsConnect)
        #expect(!ConnectionTreeStatus.connecting.allowsConnect)
        #expect(!ConnectionTreeStatus.connected.allowsConnect)
    }
}
