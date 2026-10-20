//
//  SSHChannelFreePumpTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHChannelFreePumpTests {
    @Test("A free that finishes at once does not wait")
    func freesWithoutWaiting() {
        let free = ScriptedFree([.finished])
        let waits = WaitLog()

        let outcome = SSHChannelFreePump(
            attemptFree: free.next,
            isActive: { true },
            deadline: Date().addingTimeInterval(60),
            waitForTransport: waits.record
        ).run()

        #expect(outcome == .freed)
        #expect(free.attempts == 1)
        #expect(waits.directions.isEmpty)
    }

    @Test("A free that would block runs again after each wait, past any fixed number of tries")
    func retriesUntilFreed() {
        let free = ScriptedFree(Array(repeating: .wouldBlock(.outbound), count: 25) + [.wouldBlock(.inbound), .finished])
        let waits = WaitLog()

        let outcome = SSHChannelFreePump(
            attemptFree: free.next,
            isActive: { true },
            deadline: Date().addingTimeInterval(60),
            waitForTransport: waits.record
        ).run()

        #expect(outcome == .freed)
        #expect(free.attempts == 27)
        #expect(waits.directions.count == 26)
        #expect(waits.directions.last == .inbound)
    }

    @Test("A tunnel that stops ends the free, which the session free then finishes")
    func stopsWithTheTunnel() {
        let free = ScriptedFree([.wouldBlock(.outbound), .wouldBlock(.outbound)])
        var active = true

        let outcome = SSHChannelFreePump(
            attemptFree: free.next,
            isActive: { active },
            deadline: Date().addingTimeInterval(60),
            waitForTransport: { _ in active = false }
        ).run()

        #expect(outcome == .stopped)
        #expect(free.attempts == 2)
    }

    @Test("A free still blocked at the deadline times out")
    func timesOutAtTheDeadline() {
        let free = ScriptedFree([])
        let start = Date(timeIntervalSince1970: 0)
        var reads = 0

        let outcome = SSHChannelFreePump(
            attemptFree: free.next,
            isActive: { true },
            deadline: start.addingTimeInterval(5),
            waitForTransport: { _ in },
            now: {
                defer { reads += 1 }
                return start.addingTimeInterval(Double(reads))
            }
        ).run()

        #expect(outcome == .timedOut)
        #expect(free.attempts == 6)
    }
}

private final class ScriptedFree {
    private var script: [SSHChannelFreeAttempt]
    private(set) var attempts = 0

    // Once the script runs out, every attempt would block.
    init(_ script: [SSHChannelFreeAttempt]) {
        self.script = script
    }

    func next() -> SSHChannelFreeAttempt {
        attempts += 1
        return script.isEmpty ? .wouldBlock(.inbound) : script.removeFirst()
    }
}

private final class WaitLog {
    private(set) var directions: [RelayDirections] = []

    func record(_ directions: RelayDirections) {
        self.directions.append(directions)
    }
}
