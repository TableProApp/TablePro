//
//  SessionRecoveryNetworkTests.swift
//  TableProTests
//
//  After a Wi-Fi drop a session waited out its backoff, up to 120 s, after the network was back, and
//  attempts made while the network was down spent the 10-attempt budget, so an outage of about eight
//  minutes left the session unreachable with nothing wrong on the server (#4546).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct SessionRecoveryNetworkTests {
    private struct Fixture {
        let manager: DatabaseManager
        let clock: ManualClock
        let connection: DatabaseConnection
        let driver: MockDatabaseDriver

        var id: UUID { connection.id }
    }

    private static let down = NetworkPathSnapshot(isSatisfied: false, interfaces: [])
    private static let wifi = NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0"])
    private static let refused = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ECONNREFUSED),
        userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
    )

    private func makeFixture(host: String = "203.0.113.10") -> Fixture {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let clock = ManualClock()
        let manager = DatabaseManager(recoveryClock: clock)
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        connection.host = host
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "app"
        manager.injectSession(session, for: connection.id)
        FakeMSSQLPlugin.recordConfigurations(for: connection.id)
        return Fixture(manager: manager, clock: clock, connection: connection, driver: driver)
    }

    private func cleanUp(_ fixture: Fixture) async {
        fixture.manager.endRecoveryLoop(for: fixture.id)
        await fixture.manager.stopHealthMonitor(for: fixture.id)
        fixture.manager.removeSession(for: fixture.id)
        FakeMSSQLPlugin.clearConnectFailure(for: fixture.id)
        FakeMSSQLPlugin.clearConfigurations(for: fixture.id)
        await SchemaService.shared.invalidate(connectionId: fixture.id)
    }

    @Test("A loop with no network waits for the path and spends no attempt")
    func noAttemptWhileThePathIsDown() async throws {
        let fixture = makeFixture()
        fixture.manager.networkPathChanged(to: Self.wifi)
        fixture.manager.networkPathChanged(to: Self.down)
        FakeMSSQLPlugin.failConnect(for: fixture.id, with: Self.refused)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        for _ in 1...ConnectionRecoveryProgress.maxAttempts + 2 {
            await fixture.clock.waitUntilSleeping()
            fixture.clock.advance(by: .seconds(DatabaseManager.maxRecoveryDelay))
            try await waitUntil { fixture.manager.networkChangeWaiters.count == 1 }
            if fixture.clock.pendingSleeperCount == 0 { break }
        }

        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)
        #expect(fixture.manager.session(for: fixture.id)?.liveness == .recovering)
        #expect(fixture.manager.recoveryLoops[fixture.id] != nil)
        await cleanUp(fixture)
    }

    @Test("A server on this Mac keeps redialing with no network path")
    func loopbackIgnoresThePath() async throws {
        let fixture = makeFixture(host: "127.0.0.1")
        fixture.manager.networkPathChanged(to: Self.wifi)
        fixture.manager.networkPathChanged(to: Self.down)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: .seconds(DatabaseManager.maxRecoveryDelay))
        try await waitUntil { FakeMSSQLPlugin.configurations(for: fixture.id).count == 1 }

        await cleanUp(fixture)
    }

    @Test("The path coming back cuts the backoff short, so the loop redials at once")
    func pathReturnRetriesAtOnce() async throws {
        let fixture = makeFixture()
        fixture.manager.networkPathChanged(to: Self.wifi)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        await fixture.clock.waitUntilSleeping()
        #expect(FakeMSSQLPlugin.configurations(for: fixture.id).isEmpty)

        fixture.manager.networkPathChanged(to: Self.down)
        fixture.manager.networkPathChanged(to: Self.wifi)
        try await waitUntil { FakeMSSQLPlugin.configurations(for: fixture.id).count == 1 }

        await cleanUp(fixture)
    }

    @Test("A new interface on a path that stayed up also cuts the backoff short")
    func interfaceChangeRetriesAtOnce() async throws {
        let fixture = makeFixture()
        fixture.manager.networkPathChanged(to: Self.wifi)

        fixture.manager.beginRecovery(for: fixture.id, cause: .stoppedResponding)
        await fixture.clock.waitUntilSleeping()
        fixture.manager.networkPathChanged(to: NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0", "utun4"]))
        try await waitUntil { FakeMSSQLPlugin.configurations(for: fixture.id).count == 1 }

        await cleanUp(fixture)
    }

    @Test("While the app is inactive a health check waits at least as long as an answer stays fresh")
    func inactiveIntervalStretchesToFreshness() {
        #expect(DatabaseManager.healthCheckInterval(setting: .every30Seconds, appIsActive: true) == .seconds(30))
        #expect(DatabaseManager.healthCheckInterval(setting: .every30Seconds, appIsActive: false) == .seconds(300))
        #expect(DatabaseManager.healthCheckInterval(setting: .every15Minutes, appIsActive: false) == .seconds(900))
        #expect(DatabaseManager.healthCheckInterval(setting: .onDemand, appIsActive: false) == nil)
    }

    @Test("A ping is skipped while a turn holds the session driver, and runs as a turn otherwise")
    func pingTakesAGateTurn() async throws {
        let fixture = makeFixture()
        let manager = fixture.manager
        let release = AsyncGate()
        let acquired = AsyncGate()
        let holder = Task { @MainActor in
            try await manager.sessionDriverGate.withExclusiveAccess(manager.browsedGateKey(for: fixture.id)) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        #expect(await manager.pingSessionDriver(fixture.id))
        #expect(fixture.driver.pingCallCount == 0)

        await release.open()
        try await holder.value
        #expect(await manager.pingSessionDriver(fixture.id))
        #expect(fixture.driver.pingCallCount == 1)
        await cleanUp(fixture)
    }
}
