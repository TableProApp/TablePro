//
//  ConnectionVerificationTests.swift
//  TableProTests
//
//  With the health check turned down or off, nothing polls, so `ConnectionSession.liveness` has no
//  writer but the initial connect. `verifyBeforeUse` is the second writer that keeps the app
//  honest: it checks a connection nobody has heard from in a while at the moment someone reaches
//  for it, and reconnects if it has gone (#2700).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection verification before use", .serialized)
@MainActor
struct ConnectionVerificationTests {
    private func makeSession(
        driver: MockDatabaseDriver,
        typeId: String = FakeMSSQLPlugin.databaseTypeId
    ) -> DatabaseConnection {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: typeId)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func cleanUp(_ connectionId: UUID) async {
        DatabaseManager.shared.removeSession(for: connectionId)
        await SchemaService.shared.invalidate(connectionId: connectionId)
    }

    @Test("a connection that answered recently is not asked again")
    func freshConnectionIsNotPinged() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 0)
        await cleanUp(connection.id)
    }

    @Test("a connection that has been silent too long is checked once")
    func staleConnectionIsPingedOnce() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 1)
        await cleanUp(connection.id)
    }

    @Test("a successful check makes the connection fresh again, so the next use is free")
    func aSuccessfulCheckRefreshesTheAnswer() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)
        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 1)
        await cleanUp(connection.id)
    }

    /// Everything else in the app treats `.live` as "this driver can be believed", so a check that
    /// succeeded has to say so, or a session that recovered keeps carrying the reason it failed.
    @Test("a successful check leaves the session live")
    func aSuccessfulCheckMarksTheSessionLive() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(DatabaseManager.shared.activeSessions[connection.id]?.liveness == .live)
        await cleanUp(connection.id)
    }

    @Test("a query already running on the driver is a better answer than a ping")
    func aQueryInFlightSkipsTheCheck() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        _ = try? await DatabaseManager.shared.trackOperation(sessionId: connection.id) {
            await DatabaseManager.shared.verifyBeforeUse(connection.id)
        }

        #expect(driver.pingCallCount == 0)
        await cleanUp(connection.id)
    }

    /// A session the app already knows is in trouble has a reconnect of its own in flight.
    @Test("a session that is already unreachable is left to its own reconnect")
    func unreachableSessionIsNotChecked() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)
        DatabaseManager.shared.markSessionUnreachable(
            connection.id,
            startedWith: driver,
            info: ConnectionFailureInfo(message: "gone")
        )

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 0)
        await cleanUp(connection.id)
    }

    @Test("several callers reaching for one connection at once check it once between them")
    func concurrentCallersCollapseIntoOneCheck() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        let connectionId = connection.id
        let callers = (0 ..< 8).map { _ in
            Task { @MainActor in await DatabaseManager.shared.verifyBeforeUse(connectionId) }
        }
        for caller in callers {
            await caller.value
        }

        #expect(driver.pingCallCount == 1)
        await cleanUp(connection.id)
    }

    /// Wall-clock time passes during sleep but nothing in the app observes it, so every answer it
    /// is holding was given before a gap the server may well have closed the socket in.
    @Test("waking from sleep makes every connection worth asking about again")
    func wakeInvalidatesEveryAnswer() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)
        #expect(driver.pingCallCount == 0)

        DatabaseManager.shared.forgetAllVerifications()
        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 1)
        await cleanUp(connection.id)
    }

    /// The engines that hold a file rather than a socket opt out of health checks, and the
    /// on-demand path is the same question asked at a different moment: it must not become the way
    /// a check reaches them anyway.
    @Test("an engine that opts out of health checks is not checked before use either")
    func optedOutEngineIsNotChecked() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver, typeId: DatabaseType.sqlite.rawValue)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 0)
        await cleanUp(connection.id)
    }

    @Test("a check that fails reconnects the connection")
    func aFailedCheckReconnects() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        driver.pingError = DatabaseError.notConnected
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(driver.pingCallCount == 1)
        #expect(DatabaseManager.shared.activeSessions[connection.id]?.driver !== driver)
        #expect(DatabaseManager.shared.activeSessions[connection.id]?.liveness == .live)
        await cleanUp(connection.id)
    }

    /// The reconnect disconnects the installed driver before it tries, so a failure that left
    /// liveness alone would hand the user's own operation a handle that cannot work. The type has
    /// no driver plugin registered, so the reconnect fails on its first step with no network and
    /// no waiting.
    @Test("a check that fails and cannot reconnect stops the session reading as live")
    func aFailedRecoveryMarksTheSessionUnreachable() async {
        Self.registerUnreachableTypeIfNeeded()
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver, typeId: Self.unreachableTypeId)
        driver.pingError = DatabaseError.notConnected
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        await DatabaseManager.shared.verifyBeforeUse(connection.id)

        #expect(DatabaseManager.shared.activeSessions[connection.id]?.liveness != .live)
        await cleanUp(connection.id)
    }

    private static let unreachableTypeId = "VerificationReconnectFake"

    private static func registerUnreachableTypeIfNeeded() {
        guard PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: unreachableTypeId) == nil else { return }
        let snapshot = PluginMetadataSnapshot(
            displayName: unreachableTypeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "verificationreconnectfake", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: true, urlSchemes: ["verificationreconnectfake"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: .defaults, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: unreachableTypeId)
    }

    /// A ping cannot be cancelled once it is inside a C call, so it completes late. Applying its
    /// answer to whatever driver the session holds by then is how a losing attempt tears down the
    /// one that replaced it.
    @Test("a late answer about a driver that has been replaced is discarded")
    func aLateAnswerAboutAReplacedDriverIsDiscarded() async {
        let slow = MockDatabaseDriver()
        slow.pingDelaySeconds = 0.3
        slow.pingError = DatabaseError.notConnected
        let connection = makeSession(driver: slow)
        DatabaseManager.shared.markSessionVerified(connection.id, at: .distantPast)

        let connectionId = connection.id
        let check = Task { @MainActor in await DatabaseManager.shared.verifyBeforeUse(connectionId) }
        try? await Task.sleep(for: .milliseconds(50))
        let replacement = MockDatabaseDriver()
        DatabaseManager.shared.updateSession(connectionId) { $0.driver = replacement }
        await check.value

        #expect(slow.pingCallCount == 1)
        #expect(DatabaseManager.shared.activeSessions[connectionId]?.driver === replacement)
        #expect(DatabaseManager.shared.activeSessions[connectionId]?.liveness == .live)
        await cleanUp(connectionId)
    }

    @Test("ending a session forgets when it last answered")
    func removingASessionForgetsItsAnswer() async {
        let driver = MockDatabaseDriver()
        let connection = makeSession(driver: driver)
        DatabaseManager.shared.markSessionVerified(connection.id)

        await cleanUp(connection.id)

        #expect(DatabaseManager.shared.lastVerifiedAt[connection.id] == nil)
    }
}

@Suite("Health monitor scheduling", .serialized)
@MainActor
struct HealthMonitorSchedulingTests {
    private func makeSession() -> DatabaseConnection {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        session.driver = MockDatabaseDriver()
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func withHealthCheck(_ setting: ConnectionHealthCheck, _ body: () async -> Void) async {
        let previous = AppSettingsManager.shared.general.connectionHealthCheck
        AppSettingsManager.shared.general.connectionHealthCheck = setting
        await body()
        AppSettingsManager.shared.general.connectionHealthCheck = previous
    }

    /// The whole point of the on-demand setting: not a very long interval, no scheduled work at
    /// all. A task that wakes up to decide it has nothing to do is still something waking up.
    @Test("on demand starts no monitor at all")
    func onDemandStartsNoMonitor() async {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await withHealthCheck(.onDemand) {
            await DatabaseManager.shared.startHealthMonitor(for: connection.id)
        }

        #expect(DatabaseManager.shared.healthMonitors[connection.id] == nil)
        await DatabaseManager.shared.stopHealthMonitor(for: connection.id)
    }

    @Test("a polling setting starts a monitor")
    func aPollingSettingStartsAMonitor() async {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await withHealthCheck(.every15Minutes) {
            await DatabaseManager.shared.startHealthMonitor(for: connection.id)
        }

        #expect(DatabaseManager.shared.healthMonitors[connection.id] != nil)
        await DatabaseManager.shared.stopHealthMonitor(for: connection.id)
    }

    /// The monitor is built once, when the connection opens, so switching the setting has to reach
    /// what is already open or it only applies to the next connection someone makes.
    @Test("turning the check off stops the monitor an open connection already has")
    func switchingToOnDemandStopsALiveMonitor() async {
        let connection = makeSession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await withHealthCheck(.every30Seconds) {
            await DatabaseManager.shared.startHealthMonitor(for: connection.id)
        }
        #expect(DatabaseManager.shared.healthMonitors[connection.id] != nil)

        await withHealthCheck(.onDemand) {
            await DatabaseManager.shared.startHealthMonitor(for: connection.id)
        }

        #expect(DatabaseManager.shared.healthMonitors[connection.id] == nil)
        await DatabaseManager.shared.stopHealthMonitor(for: connection.id)
    }
}
