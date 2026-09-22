//
//  SessionSwitchOperationTrackingTests.swift
//  TableProTests
//
//  A container switch is a turn on the session driver like any other, so it has to be counted as
//  one. `queriesInFlight` is the only thing the health monitor consults before entering the same
//  driver alongside the user's work, and holding `sessionDriverGate` does not reach it: the ping
//  never asks for that gate. Found alongside #3053.
//

import Foundation
import Testing

@testable import TablePro

@MainActor
private final class Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Session switches count as in-flight work")
@MainActor
struct SessionSwitchOperationTrackingTests {
    @Test("A schema switch is in flight while the driver is running it")
    func schemaSwitchRegistersAsInFlight() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = MockDatabaseDriver(connection: connection)
        driver.currentSchema = "public"

        var session = ConnectionSession(connection: connection, driver: driver)
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.queriesInFlight[connection.id] == nil)

        let entered = Latch()
        let release = Latch()
        driver.onSwitchSchema = {
            await entered.open()
            await release.wait()
        }

        let switching = Task { @MainActor in
            try await DatabaseManager.shared.switchSchema(to: "reporting", for: connection.id)
        }
        await entered.wait()

        #expect(DatabaseManager.shared.queriesInFlight[connection.id] != nil)

        release.open()
        try await switching.value

        #expect(DatabaseManager.shared.queriesInFlight[connection.id] == nil)
        #expect(driver.currentSchema == "reporting")
    }
}
