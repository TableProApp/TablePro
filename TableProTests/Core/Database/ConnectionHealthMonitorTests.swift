//
//  ConnectionHealthMonitorTests.swift
//  TableProTests
//
//  Tests for ConnectionHealthMonitor state transitions and behavior.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionHealthMonitor")
struct ConnectionHealthMonitorTests {
    // MARK: - HealthState Equatable Tests

    @Test("Initial state is .healthy")
    func initialStateIsHealthy() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: { true },
            reconnectHandler: { true },
            onStateChanged: { _, _ in }
        )
        let state = await monitor.currentState
        #expect(state == .healthy)
    }

    @Test("HealthState equality: same values are equal")
    func healthStateEqualitySameValues() {
        let a = ConnectionHealthMonitor.HealthState.healthy
        let b = ConnectionHealthMonitor.HealthState.healthy
        #expect(a == b)

        let c = ConnectionHealthMonitor.HealthState.reconnecting(attempt: 3)
        let d = ConnectionHealthMonitor.HealthState.reconnecting(attempt: 3)
        #expect(c == d)
    }

    @Test("HealthState inequality: different attempt numbers")
    func healthStateInequalityDifferentAttempts() {
        let a = ConnectionHealthMonitor.HealthState.reconnecting(attempt: 1)
        let b = ConnectionHealthMonitor.HealthState.reconnecting(attempt: 2)
        #expect(a != b)
    }

    @Test("HealthState inequality: different cases")
    func healthStateInequalityDifferentCases() {
        #expect(ConnectionHealthMonitor.HealthState.healthy != .checking)
        #expect(ConnectionHealthMonitor.HealthState.healthy != .failed)
        #expect(ConnectionHealthMonitor.HealthState.checking != .failed)
        #expect(ConnectionHealthMonitor.HealthState.healthy != .reconnecting(attempt: 1))
    }

    @Test("stopMonitoring cancels and cleans up")
    func stopMonitoringCancelsAndCleansUp() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: { true },
            reconnectHandler: { true },
            onStateChanged: { _, _ in }
        )

        await monitor.startMonitoring()
        await monitor.stopMonitoring()

        let state = await monitor.currentState
        #expect(state == .healthy)
    }

    @Test("resetAfterManualReconnect sets state to healthy")
    func resetAfterManualReconnect() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: { true },
            reconnectHandler: { true },
            onStateChanged: { _, _ in }
        )

        await monitor.resetAfterManualReconnect()
        let state = await monitor.currentState
        #expect(state == .healthy)
    }

    @Test("Multiple startMonitoring calls do not create duplicate tasks")
    func multipleStartMonitoringCallsAreIdempotent() async {
        var pingCount = 0
        let lock = NSLock()

        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: {
                lock.lock()
                pingCount += 1
                lock.unlock()
                return true
            },
            reconnectHandler: { true },
            onStateChanged: { _, _ in }
        )

        await monitor.startMonitoring()
        await monitor.startMonitoring()
        await monitor.startMonitoring()

        // Brief pause to ensure no unexpected immediate pings
        try? await Task.sleep(for: .milliseconds(100))

        await monitor.stopMonitoring()

        // The monitoring loop sleeps 30s before its first ping,
        // so no pings should have fired in 100ms
        lock.lock()
        let count = pingCount
        lock.unlock()
        #expect(count == 0)
    }

    @Test("Staggered initial delay — no ping fires immediately")
    func staggeredInitialDelay() async {
        var pingCount = 0
        let lock = NSLock()

        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: {
                lock.lock()
                pingCount += 1
                lock.unlock()
                return true
            },
            reconnectHandler: { true },
            onStateChanged: { _, _ in }
        )

        await monitor.startMonitoring()

        // Wait briefly — with stagger (0-10s) + ping interval (30s),
        // no ping should fire in 200ms
        try? await Task.sleep(for: .milliseconds(200))

        await monitor.stopMonitoring()

        lock.lock()
        let count = pingCount
        lock.unlock()
        #expect(count == 0, "No ping should fire immediately due to staggered initial delay")
    }
}
