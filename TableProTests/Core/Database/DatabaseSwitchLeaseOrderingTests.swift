//
//  DatabaseSwitchLeaseOrderingTests.swift
//  TableProTests
//
//  An engine that reconnects to change database names the target on the session before the new
//  driver exists. A table load that ran in that window took the old driver, still on the previous
//  database, and a restored PostgreSQL tab showed another database's rows under its own title.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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

@Suite("Database switch lease ordering", .serialized)
@MainActor
struct DatabaseSwitchLeaseOrderingTests {
    private static let typeId = "LeaseOrderingReconnectFake"
    private static let unpooledTypeId = "LeaseOrderingUnpooledReconnectFake"

    /// A type that reopens its connection to change database, and whose driver plugin is not
    /// registered, so every switch reaches the reconnect and fails there. `pools` says whether it can
    /// open a second connection for a database the session has left.
    private func registerTypeIfNeeded(_ typeId: String = Self.typeId, pools: Bool = true) {
        guard PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId) == nil else { return }
        let defaults = PluginMetadataSnapshot.CapabilityFlags.defaults
        var capabilities = PluginMetadataSnapshot.CapabilityFlags(
            supportsSchemaSwitching: true,
            supportsImport: defaults.supportsImport,
            supportsExport: defaults.supportsExport,
            supportsSSH: defaults.supportsSSH,
            supportsSSL: defaults.supportsSSL,
            supportsCascadeDrop: defaults.supportsCascadeDrop,
            supportsForeignKeyDisable: defaults.supportsForeignKeyDisable,
            supportsReadOnlyMode: defaults.supportsReadOnlyMode,
            supportsQueryProgress: defaults.supportsQueryProgress,
            requiresReconnectForDatabaseSwitch: true,
            supportsDropDatabase: defaults.supportsDropDatabase
        )
        capabilities.supportsConnectionPooling = pools
        let snapshot = PluginMetadataSnapshot(
            displayName: typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: typeId.lowercased(), parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: [typeId.lowercased()], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId)
    }

    private func makeSession() -> DatabaseConnection {
        registerTypeIfNeeded()
        var connection = TestFixtures.makeConnection(database: "app")
        connection.type = DatabaseType(rawValue: Self.typeId)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func cleanUp(_ connectionId: UUID) {
        DatabaseManager.shared.removeSession(for: connectionId)
        AppSettingsStorage.shared.saveLastDatabase(nil, for: connectionId)
        AppSettingsStorage.shared.saveLastSchema(nil, for: connectionId)
        PluginMetadataRegistry.shared.unregister(typeId: Self.typeId)
    }

    /// Holds the connection's driver until `release` opens, and returns only once it holds it.
    private func holdDriver(_ connectionId: UUID, until release: Latch) async -> Task<Void, Error> {
        let acquired = Latch()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(connectionId) {
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()
        return holder
    }

    /// Waits for callers to queue behind the holder. The bound is there so a caller that never
    /// queues, which is the regression these tests guard, fails the assertions after it rather than
    /// hanging the suite.
    private func waitForQueuedCallers(_ count: Int, on connectionId: UUID) async {
        for _ in 0..<10_000 where DatabaseManager.shared.sessionDriverGate.waiterCount(for: connectionId) < count {
            await Task.yield()
        }
    }

    /// Waits for work running off the main actor to reach a point it reports. Bounded for the same
    /// reason as `waitForQueuedCallers`.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A session browsing `app`, with the connection's pooled connection to `app` seeded, so a read
    /// the pool serves is told apart from one the session driver serves.
    private func makeTableReadSession(type: DatabaseType) -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(database: "app", type: type)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pooled = MockDatabaseDriver(connection: connection)
        MetadataConnectionPool.shared.injectEntry(pooled, scope: appScope(connection))
        return (connection, pooled)
    }

    private func appScope(_ connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
    }

    private func cleanUpTableRead(_ connectionId: UUID) {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        DatabaseManager.shared.removeSession(for: connectionId)
    }

    /// The reported schedule, with its order fixed by the gate rather than by timing: the switch
    /// queues for the driver first, then a table load already routed onto the switch's target queues
    /// behind it. This switch cannot reconnect, so it rolls back and leaves the driver dead. The
    /// load gets its turn only after that and is refused. Without the gate the switch ran at once,
    /// and the load then ran on the driver it was replacing, which was still on `app`.
    @Test("A lease routed onto a switch's target never runs on the driver the switch is replacing")
    func leaseDuringASwitchNeverRunsOnTheReplacedDriver() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let original = try #require(DatabaseManager.shared.driver(for: connection.id) as? MockDatabaseDriver)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let switchTask = Task { @MainActor in
            try await DatabaseManager.shared.switchDatabase(to: "orders", for: connection.id, persist: false)
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "app")

        let orders = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        let lease = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: orders,
                route: .sessionDriver,
                cancellation: .cancellableRead
            ) { driver in
                driver.connection.database
            }
        }
        await waitForQueuedCallers(2, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 2)
        #expect(original.disconnectCallCount == 0)

        release.open()
        try await holder.value
        _ = try? await switchTask.value

        await #expect {
            try await lease.value
        } throws: { error in
            guard case .notConnected = error as? DatabaseError else { return false }
            return true
        }
    }

    @Test("A database switch names nothing on the session while another operation holds the driver")
    func switchWaitsForTheDriver() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let original = try #require(DatabaseManager.shared.driver(for: connection.id) as? MockDatabaseDriver)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let switchTask = Task { @MainActor in
            try await DatabaseManager.shared.switchDatabase(to: "orders", for: connection.id, persist: false)
        }
        await waitForQueuedCallers(1, on: connection.id)

        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "app")
        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.database == "app")
        #expect(original.disconnectCallCount == 0)

        release.open()
        try await holder.value
        _ = try? await switchTask.value
    }

    @Test("A lease that waited behind a switch which left the driver dead is refused")
    func leaseQueuedBehindADeadDriverIsRefused() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let app = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        let lease = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: app,
                route: .sessionDriver,
                cancellation: .cancellableRead
            ) { driver in
                driver.connection.database
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.updateSession(connection.id) { $0.liveness = .unreachable(nil) }
        release.open()
        try await holder.value

        await #expect {
            try await lease.value
        } throws: { error in
            guard case .notConnected = error as? DatabaseError else { return false }
            return true
        }
    }

    @Test("A schema switch queued behind the driver runs on the driver installed when its turn comes")
    func schemaSwitchUsesTheDriverInstalledWhenItRuns() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let original = try #require(DatabaseManager.shared.driver(for: connection.id) as? MockDatabaseDriver)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let schemaSwitch = Task { @MainActor in
            try await DatabaseManager.shared.switchSchema(to: "reporting", for: connection.id)
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        let replacement = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.updateSession(connection.id) { $0.driver = replacement }
        release.open()
        try await holder.value
        try await schemaSwitch.value

        #expect(replacement.switchSchemaCallCount == 1)
        #expect(original.switchSchemaCallCount == 0)
    }

    /// A switch still queued when the connection is closed and opened again would otherwise move the
    /// session that replaced it.
    @Test("A switch queued behind the driver is dropped when the session it was asked on has gone")
    func queuedSwitchIsDroppedForAReplacedSession() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let switchTask = Task { @MainActor in
            try await DatabaseManager.shared.switchDatabase(to: "orders", for: connection.id, persist: false)
        }
        let schemaTask = Task { @MainActor in
            try await DatabaseManager.shared.switchSchema(to: "reporting", for: connection.id)
        }
        await waitForQueuedCallers(2, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 2)

        DatabaseManager.shared.removeSession(for: connection.id)
        let reopened = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: reopened)
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        release.open()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await switchTask.value
        }
        await #expect(throws: CancellationError.self) {
            try await schemaTask.value
        }
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "app")
        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.database == "app")
        #expect(reopened.disconnectCallCount == 0)
        #expect(reopened.switchSchemaCallCount == 0)
    }

    /// A lease that waited behind a holder stuck on the old session used to wake when that holder
    /// returned, find a live session under the same id, and run the old tab's work there.
    @Test("A lease queued when its session ends never runs on the session opened after it")
    func queuedLeaseNeverRunsOnAReopenedSession() async throws {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let ran = LeaseRecord()
        let app = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        let lease = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: app,
                route: .sessionDriver,
                cancellation: .cancellableRead
            ) { _ in
                await MainActor.run { ran.didRun = true }
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.finalizeConnectionFailure(for: connection.id, cancelled: false)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        release.open()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await lease.value
        }
        #expect(!ran.didRun)
    }

    // MARK: - A table read queued through a switch

    /// The reported schedule: a table load for `app` queues behind a switch to `orders` on an engine
    /// that reconnects to switch. When its turn came it was refused with "This tab is on app", although
    /// a pooled connection to `app` would have served it and running it again did.
    @Test("A table read that waited through a switch runs on a pooled connection to its own database")
    func tableReadFollowsTheSwitchOntoThePool() async throws {
        let (connection, pooled) = makeTableReadSession(type: .postgresql)
        defer { cleanUpTableRead(connection.id) }
        let app = appScope(connection)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let read = Task { @MainActor in
            try await DatabaseManager.shared.withTableReadDriver(scope: app, cancellation: .cancellableRead) { driver in
                driver === pooled
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "orders" }
        release.open()
        try await holder.value

        #expect(try await read.value)
    }

    /// The re-route belongs to table reads alone. A COMMIT or an editor statement queued the same way
    /// was written against the session that is gone, so it is still refused and never reaches the pool.
    @Test("Other work queued through the same switch is still refused on the session driver")
    func otherWorkQueuedThroughASwitchIsStillRefused() async throws {
        let (connection, _) = makeTableReadSession(type: .postgresql)
        defer { cleanUpTableRead(connection.id) }
        let app = appScope(connection)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let ran = LeaseRecord()
        let lease = Task { @MainActor in
            try await DatabaseManager.shared.withScopedDriver(
                scope: app,
                route: DatabaseManager.shared.executionRoute(for: app),
                cancellation: .cancellableRead
            ) { _ in
                await MainActor.run { ran.didRun = true }
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "orders" }
        release.open()
        try await holder.value

        await #expect {
            try await lease.value
        } throws: { error in
            guard case .queryFailed(let message) = error as? DatabaseError else { return false }
            return message.contains("app")
        }
        #expect(!ran.didRun)
    }

    @Test("A re-routed table read leaves the session driver free while it runs on the pool")
    func reroutedTableReadDoesNotHoldTheGate() async throws {
        let (connection, pooled) = makeTableReadSession(type: .postgresql)
        defer { cleanUpTableRead(connection.id) }
        let app = appScope(connection)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let running = LeaseRecord()
        let finish = Latch()
        let read = Task { @MainActor in
            try await DatabaseManager.shared.withTableReadDriver(scope: app, cancellation: .cancellableRead) { driver in
                await MainActor.run { running.didRun = true }
                await finish.wait()
                return driver === pooled
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "orders" }
        release.open()
        try await holder.value
        await waitUntil { running.didRun }
        #expect(running.didRun)

        let probe = LeaseRecord()
        let prober = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(connection.id) {
                probe.didRun = true
            }
        }
        await waitUntil { probe.didRun }

        #expect(probe.didRun)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 0)
        finish.open()
        try await prober.value
        #expect(try await read.value)
    }

    /// The driver is judged before the route, so a read that waited behind a driver that stopped
    /// answering is refused like any other lease rather than slipping out to a pooled connection.
    @Test("A table read queued behind a driver that stopped answering is refused and never reaches the pool")
    func tableReadBehindADeadDriverIsRefused() async throws {
        let (connection, _) = makeTableReadSession(type: .postgresql)
        defer { cleanUpTableRead(connection.id) }
        let app = appScope(connection)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let ran = LeaseRecord()
        let read = Task { @MainActor in
            try await DatabaseManager.shared.withTableReadDriver(scope: app, cancellation: .cancellableRead) { _ in
                await MainActor.run { ran.didRun = true }
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.updateSession(connection.id) { session in
            session.browseDatabase = "orders"
            session.liveness = .unreachable(nil)
        }
        release.open()
        try await holder.value

        await #expect {
            try await read.value
        } throws: { error in
            guard case .notConnected = error as? DatabaseError else { return false }
            return true
        }
        #expect(!ran.didRun)
    }

    @Test("A table read left behind by a switch on an engine that cannot pool names its database")
    func tableReadWithNowhereToGoNamesItsDatabase() async throws {
        registerTypeIfNeeded(Self.unpooledTypeId, pools: false)
        let (connection, _) = makeTableReadSession(type: DatabaseType(rawValue: Self.unpooledTypeId))
        defer {
            cleanUpTableRead(connection.id)
            PluginMetadataRegistry.shared.unregister(typeId: Self.unpooledTypeId)
        }
        let app = appScope(connection)
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let ran = LeaseRecord()
        let read = Task { @MainActor in
            try await DatabaseManager.shared.withTableReadDriver(scope: app, cancellation: .cancellableRead) { _ in
                await MainActor.run { ran.didRun = true }
            }
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "orders" }
        release.open()
        try await holder.value

        await #expect {
            try await read.value
        } throws: { error in
            guard case .queryFailed(let message) = error as? DatabaseError else { return false }
            return message.contains("app")
        }
        #expect(!ran.didRun)
    }
}

@MainActor
private final class LeaseRecord {
    var didRun = false
}
