//
//  LocalNetworkConnectFailureTests.swift
//  TableProTests
//
//  A driver refused by the Local Network permission only reports an unreachable host. The connect
//  path probes the host it dialed and, on a refusal, records the fix that opens System Settings.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct LocalNetworkConnectFailureTests {
    private struct StubProbe: LocalNetworkAccessProbing {
        let answer: LocalNetworkAccess

        func access(to host: String) async -> LocalNetworkAccess { answer }
    }

    private struct HeldProbe: LocalNetworkAccessProbing {
        let gate: AsyncGate

        func access(to host: String) async -> LocalNetworkAccess {
            await gate.wait()
            return .denied
        }
    }

    private struct RouteRefusal: LocalizedError {
        var errorDescription: String? { "No route to host" }
    }

    private struct Fixture {
        let manager: DatabaseManager
        let connection: DatabaseConnection
        let cleanUp: () -> Void
    }

    private func makeFixture(probe: any LocalNetworkAccessProbing) throws -> Fixture {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-local-network-\(UUID().uuidString).json")
        let suite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
        let manager = DatabaseManager(connectionStorage: storage, localNetworkProbe: probe)

        var connection = TestFixtures.makeConnection(name: "LAN Server", type: .mssql)
        connection.host = "192.168.77.20"
        storage.addConnection(connection)
        FakeMSSQLPlugin.failConnect(for: connection.id, with: RouteRefusal())

        let connectionId = connection.id
        return Fixture(
            manager: manager,
            connection: connection,
            cleanUp: {
                manager.removeSession(for: connectionId)
                FakeMSSQLPlugin.clearConnectFailure(for: connectionId)
                suite.defaults.removePersistentDomain(forName: suite.suiteName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        )
    }

    @Test("A connect the permission refused names it and records the fix that opens System Settings")
    func refusedConnectOffersSystemSettings() async throws {
        let fixture = try makeFixture(probe: StubProbe(answer: .denied))
        defer { fixture.cleanUp() }

        await #expect(throws: LocalNetworkAccessError.self) {
            try await fixture.manager.ensureConnected(fixture.connection)
        }

        guard case .connectFailed(let info, let action)? = fixture.manager.disconnectReason(for: fixture.connection.id) else {
            Issue.record("Expected a failed connect to be recorded")
            return
        }
        #expect(action == .openLocalNetworkSettings)
        #expect(info.message.contains("192.168.77.20"))
        #expect(info.details == "No route to host")
    }

    @Test("A host the permission allows keeps the driver's own error")
    func allowedHostKeepsTheDriverError() async throws {
        let fixture = try makeFixture(probe: StubProbe(answer: .granted))
        defer { fixture.cleanUp() }

        await #expect(throws: RouteRefusal.self) {
            try await fixture.manager.ensureConnected(fixture.connection)
        }

        guard case .connectFailed(let info, .none)? = fixture.manager.disconnectReason(for: fixture.connection.id) else {
            Issue.record("Expected a failed connect with no fix")
            return
        }
        #expect(info.message == "No route to host")
    }

    @Test("A proxy setting rejected before any dial keeps its own error under a refusing probe")
    func preflightErrorSurvivesARefusal() async throws {
        let fixture = try makeFixture(probe: StubProbe(answer: .denied))
        defer { fixture.cleanUp() }
        var connection = fixture.connection
        connection.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "192.168.1.30", port: 0))

        await #expect(throws: SOCKSProxyError.invalidConfiguration) {
            try await fixture.manager.ensureConnected(connection)
        }
    }

    @Test("A connect cancelled while the probe runs records nothing")
    func cancelDuringProbeRecordsNothing() async throws {
        let gate = AsyncGate()
        let fixture = try makeFixture(probe: HeldProbe(gate: gate))
        defer { fixture.cleanUp() }

        let manager = fixture.manager
        let connection = fixture.connection
        let attempt = Task { try await manager.ensureConnected(connection) }
        await gate.arrived(1)
        manager.invalidateConnectionAttempt(connection.id)
        await gate.open()
        _ = await attempt.result

        #expect(manager.disconnectReason(for: connection.id) == nil)
    }
}
