//
//  DisconnectWhileConnectingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class HeldScriptQuestion: PreConnectScriptAsking {
    let gate = AsyncGate()

    func ask(connectionName: String, script: String, postDisconnectScript: String?) async -> ConsentAnswer {
        await gate.wait()
        return .approved
    }
}

private final class RanPostDisconnectScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PendingPostDisconnectScript] = []

    var scripts: [PendingPostDisconnectScript] { lock.withLock { recorded } }

    func record(_ script: PendingPostDisconnectScript) {
        lock.withLock { recorded.append(script) }
    }
}

// Closing a connection that is still connecting must end the connect too, or it finishes with nothing that owns its
// driver, its tunnel or its post-disconnect script.
@MainActor
struct DisconnectWhileConnectingTests {
    private struct Fixture {
        let manager: DatabaseManager
        let question: HeldScriptQuestion
        let ran: RanPostDisconnectScripts
        let connection: DatabaseConnection
        let marker: URL
        let cleanUp: () async -> Void

        var scriptRan: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    private func makeFixture(preConnectScript: Bool) throws -> Fixture {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-disconnect-connecting-\(unique)", isDirectory: true)
            .appendingPathComponent("connections.json")
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-disconnect-connecting-ran-\(unique)")
        let suite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
        let question = HeldScriptQuestion()
        let ran = RanPostDisconnectScripts()
        let manager = DatabaseManager(
            connectionStorage: storage,
            preConnectScriptConsent: PreConnectScriptConsent(asker: question),
            postDisconnectScripts: PostDisconnectScripts(run: { ran.record($0) }),
            recoveryClock: ManualClock()
        )

        var connection = TestFixtures.makeConnection(name: "Closing", type: .mssql)
        connection.username = "reporting"
        if preConnectScript {
            connection.preConnectScript = "touch '\(marker.path)'"
            connection.postDisconnectScript = "vpn down"
        }
        storage.addConnection(connection)
        FakeMSSQLPlugin.recordConfigurations(for: connection.id)

        let connectionId = connection.id
        return Fixture(
            manager: manager,
            question: question,
            ran: ran,
            connection: connection,
            marker: marker,
            cleanUp: {
                await manager.stopHealthMonitor(for: connectionId)
                manager.driver(for: connectionId)?.disconnect()
                manager.removeSession(for: connectionId)
                FakeMSSQLPlugin.clearConnectHold(for: connectionId)
                FakeMSSQLPlugin.clearConfigurations(for: connectionId)
                suite.defaults.removePersistentDomain(forName: suite.suiteName)
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: marker)
            }
        )
    }

    @Test("Closing while the pre-connect script waits for consent runs no script, opens no driver and arms nothing")
    func closeDuringConsentStopsTheConnect() async throws {
        let fixture = try makeFixture(preConnectScript: true)
        let id = fixture.connection.id
        let manager = fixture.manager
        let connection = fixture.connection

        let connect = Task { try await manager.ensureConnected(connection) }
        await fixture.question.gate.arrived(1)
        #expect(manager.session(for: id) != nil)

        await manager.disconnectSession(id, origin: .userRequested)
        await fixture.question.gate.open()
        let outcome = await connect.result

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(!fixture.scriptRan)
        #expect(FakeMSSQLPlugin.configurations(for: id).isEmpty)
        #expect(!manager.postDisconnectScripts.isArmed(for: id))
        #expect(fixture.ran.scripts.isEmpty)
        #expect(manager.session(for: id) == nil)
        #expect(manager.healthMonitors[id] == nil)
        await fixture.cleanUp()
    }

    @Test("A connect whose entry went with no cancel reaching it ends instead of finishing unowned")
    func connectWithItsEntryGoneEnds() async throws {
        let fixture = try makeFixture(preConnectScript: false)
        let id = fixture.connection.id
        let manager = fixture.manager
        let connection = fixture.connection
        let hold = FakeMSSQLPlugin.holdConnect(for: id)

        let connect = Task { try await manager.ensureConnected(connection) }
        await hold.waitUntilReached()
        manager.removeSession(for: id)
        await hold.release()
        let outcome = await connect.result

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(manager.session(for: id) == nil)
        #expect(manager.healthMonitors[id] == nil)
        #expect(manager.currentStage(for: id) == nil)
        await fixture.cleanUp()
    }
}
