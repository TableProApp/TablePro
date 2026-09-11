//
//  MetadataConnectionPool.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
final class MetadataConnectionPool {
    static let shared = MetadataConnectionPool()

    enum Workload: Hashable, Sendable {
        case interactive
        case bulk
    }

    private struct Key: Hashable, Sendable {
        let scope: DatabaseScope
        let workload: Workload
    }

    @MainActor
    private final class Entry {
        let driver: DatabaseDriver
        var lastUsed: Date
        var inFlightCount: Int
        var closeWhenIdle: Bool
        private var tail: Task<Void, Never> = Task {}

        init(driver: DatabaseDriver) {
            self.driver = driver
            self.lastUsed = Date()
            self.inFlightCount = 0
            self.closeWhenIdle = false
        }

        /// The work runs in its own task so the next caller can queue behind it, so
        /// cancelling the caller has to be forwarded explicitly or a stopped query
        /// would keep running with nobody waiting on it.
        func runSerially<T: Sendable>(
            _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
        ) async throws -> T {
            let previous = tail
            let driver = self.driver
            let work = Task { @MainActor () async throws -> T in
                await previous.value
                try Task.checkCancellation()
                return try await body(driver)
            }
            tail = Task { @MainActor in _ = try? await work.value }
            return try await withTaskCancellationHandler(
                operation: { try await work.value },
                onCancel: { work.cancel() }
            )
        }
    }

    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Void, Error>] = [:]
    private let maxPerConnection = 6
    private let operationTimeoutSeconds: Double = 15
    private let preparationTimeoutSeconds: Double = 60
    private var sweeper: Task<Void, Never>?

    /// How long a pooled connection may sit unused before it is handed back.
    ///
    /// These are connections the user never opened: the pool takes one per database the sidebar
    /// touches, up to six, and the only thing that ever closed one was the count cap at acquire
    /// time or the whole connection going away. Browsing six databases and then leaving the app
    /// open left six idle server connections held for as long as it ran (#2700).
    ///
    /// Ten minutes rather than something tighter, because re-taking one is a whole connect,
    /// measured at 1.7-5.8ms on loopback but 800-1900ms across the internet, and someone still
    /// working must never pay that. Ten minutes of silence is nobody still working.
    static let idleTimeout: TimeInterval = 600

    /// The sweeper wakes more often than the timeout so a connection that goes idle just after a
    /// tick does not wait a whole second timeout, and never so often that an idle app spends the
    /// day waking up.
    private static let sweepInterval: Duration = .seconds(60)

    private init() {}

    func withDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let entry = try await acquireEntry(scope: scope, workload: workload)
        entry.inFlightCount += 1
        entry.lastUsed = Date()
        defer { releaseEntry(entry) }
        return try await entry.runSerially(body)
    }

    /// Closes only the leases attached to one database, which is what a rename of that database
    /// needs: PostgreSQL refuses `ALTER DATABASE ... RENAME` while any backend is connected to it,
    /// and an expanded row or a tab that ran a query there leaves one here.
    func closeAll(connectionId: UUID, database: String) {
        for key in pending.keys
        where key.scope.connectionId == connectionId && key.scope.database == database {
            pending[key]?.cancel()
            pending.removeValue(forKey: key)
        }
        for key in entries.keys
        where key.scope.connectionId == connectionId && key.scope.database == database {
            closeOrDeferEntry(forKey: key)
        }
        stopSweeperIfEmpty()
    }

    func closeAll(connectionId: UUID) {
        for key in pending.keys where key.scope.connectionId == connectionId {
            pending[key]?.cancel()
            pending.removeValue(forKey: key)
        }
        for key in entries.keys where key.scope.connectionId == connectionId {
            closeOrDeferEntry(forKey: key)
        }
        stopSweeperIfEmpty()
    }

    #if DEBUG
    /// Seeds a connected driver as the pooled connection for `scope`, so a test can observe
    /// what runs on the pool without a plugin to open a real connection.
    internal func injectEntry(
        _ driver: DatabaseDriver,
        scope: DatabaseScope,
        workload: Workload = .interactive,
        lastUsed: Date = Date()
    ) {
        let entry = Entry(driver: driver)
        entry.lastUsed = lastUsed
        entries[Key(scope: scope, workload: workload)] = entry
    }

    internal func pooledDriverCount(for connectionId: UUID) -> Int {
        entries.keys.filter { $0.scope.connectionId == connectionId }.count
    }

    internal func markInFlight(scope: DatabaseScope, workload: Workload = .interactive) {
        entries[Key(scope: scope, workload: workload)]?.inFlightCount += 1
    }

    internal var hasSweeper: Bool {
        sweeper != nil
    }

    /// The sweeper is started by opening a pooled connection, which a test with no plugin cannot
    /// do, so a test that wants to watch it stop has to start it the way `openEntry` does.
    internal func startSweeperForTesting() {
        startSweeperIfNeeded()
    }

    /// A pool of its own, so a test that moves the clock or empties the pool cannot close the
    /// entries another test injected into the shared one.
    internal static func isolatedForTesting() -> MetadataConnectionPool {
        MetadataConnectionPool()
    }
    #endif

    private func releaseEntry(_ entry: Entry) {
        entry.inFlightCount -= 1
        if entry.inFlightCount == 0, entry.closeWhenIdle {
            entry.driver.disconnect()
        }
    }

    private func closeOrDeferEntry(forKey key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if entry.inFlightCount == 0 {
            entry.driver.disconnect()
        } else {
            entry.closeWhenIdle = true
        }
    }

    private func acquireEntry(scope: DatabaseScope, workload: Workload) async throws -> Entry {
        let connectionId = scope.connectionId
        let key = Key(scope: scope, workload: workload)
        /// A cached entry is only worth reusing while it is both connected and recent. The
        /// staleness half matters even with the sweeper running, because a Mac that slept comes
        /// back with entries the sweeper never got to and sockets the server has long since
        /// closed. The old entry is closed rather than left behind: overwriting `entries[key]`
        /// with a fresh one used to leak the driver it replaced.
        if let entry = entries[key] {
            if entry.driver.status == .connected, !entry.driver.hasLostConnection, !Self.isStale(entry.lastUsed) {
                return entry
            }
            closeOrDeferEntry(forKey: key)
        }

        if let inFlight = pending[key] {
            try await inFlight.value
            guard let entry = entries[key] else { throw DatabaseError.notConnected }
            return entry
        }

        guard DatabaseManager.shared.session(for: connectionId) != nil else {
            throw DatabaseError.notConnected
        }

        evictIdleIfNeeded(for: connectionId)

        let task = Task<Void, Error> { [self] in
            let entry = try await openEntry(key: key)
            if Task.isCancelled {
                entry.driver.disconnect()
                return
            }
            entries[key] = entry
            startSweeperIfNeeded()
        }
        pending[key] = task
        defer { if pending[key] == task { pending.removeValue(forKey: key) } }
        try await task.value

        guard let entry = entries[key] else { throw DatabaseError.notConnected }
        return entry
    }

    private func openEntry(key: Key) async throws -> Entry {
        guard let session = DatabaseManager.shared.session(for: key.scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        var connection = session.effectiveConnection ?? session.connection
        let plan = Self.planConnection(
            configuredDatabase: connection.database,
            targetDatabase: key.scope.database,
            authenticationIsDatabaseScoped: connection.type.authenticationIsDatabaseScoped
        )
        connection.database = plan.connectDatabase

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )
        do {
            try await Self.connect(driver, database: plan.connectDatabase, timeoutSeconds: operationTimeoutSeconds)
            try await Self.prepareSession(
                driver,
                queryTimeoutSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds,
                startupCommands: session.connection.startupCommands,
                connectionName: session.connection.name,
                timeoutSeconds: preparationTimeoutSeconds
            )
            if let database = plan.switchDatabase {
                try await Self.switchDatabase(driver, to: database, timeoutSeconds: operationTimeoutSeconds)
            }
            if let schema = key.scope.schema {
                try await Self.switchSchema(driver, to: schema, timeoutSeconds: operationTimeoutSeconds)
            }
        } catch {
            driver.disconnect()
            throw error
        }
        return Entry(driver: driver)
    }

    static func connect(_ driver: DatabaseDriver, database: String, timeoutSeconds: Double) async throws {
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(format: String(localized: "Connecting to '%@' timed out."), database)
        ) {
            try await driver.connect()
        }
    }

    struct ConnectionPlan: Sendable, Equatable {
        let connectDatabase: String
        let switchDatabase: String?
    }

    static func planConnection(
        configuredDatabase: String,
        targetDatabase: String,
        authenticationIsDatabaseScoped: Bool
    ) -> ConnectionPlan {
        guard authenticationIsDatabaseScoped, targetDatabase != configuredDatabase else {
            return ConnectionPlan(connectDatabase: targetDatabase, switchDatabase: nil)
        }
        return ConnectionPlan(connectDatabase: configuredDatabase, switchDatabase: targetDatabase)
    }

    static func switchDatabase(_ driver: DatabaseDriver, to database: String, timeoutSeconds: Double) async throws {
        guard let adapter = driver as? PluginDriverAdapter else {
            throw DatabaseError.unsupportedOperation
        }
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(format: String(localized: "Switching to database '%@' timed out."), database)
        ) {
            try await adapter.switchDatabase(to: database)
        }
    }

    static func switchSchema(_ driver: DatabaseDriver, to schema: String, timeoutSeconds: Double) async throws {
        guard let switchable = driver as? SchemaSwitchable else { return }
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(format: String(localized: "Switching to schema '%@' timed out."), schema)
        ) {
            try await switchable.switchSchemaIfNeeded(to: schema)
        }
    }

    /// The startup commands are the user's own SQL and the query timeout can be a statement of its own,
    /// so neither belongs under the single-round-trip budget the other steps use. They still need a
    /// deadline: a hang here never resolves `pending[key]`, and a later reader joining that entry stays
    /// suspended with no error and no log line at all.
    static func prepareSession(
        _ driver: DatabaseDriver,
        queryTimeoutSeconds: Int,
        startupCommands: String?,
        connectionName: String,
        timeoutSeconds: Double
    ) async throws {
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(localized: "Preparing the metadata connection timed out.")
        ) {
            try? await driver.applyQueryTimeout(queryTimeoutSeconds)
            await DatabaseManager.shared.executeStartupCommands(
                startupCommands, on: driver, connectionName: connectionName
            )
        }
    }

    /// Disconnects the driver when the deadline fires so a driver call that
    /// ignores task cancellation still completes and the timeout can propagate.
    private static func bounded(
        driver: DatabaseDriver,
        timeoutSeconds: Double,
        timeoutMessage: String,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try await withTimeout(
                seconds: timeoutSeconds,
                onTimeout: { driver.disconnect() },
                operation: operation
            )
        } catch is TimeoutError {
            throw DatabaseError.connectionFailed(timeoutMessage)
        }
    }

    static func isStale(_ lastUsed: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUsed) >= idleTimeout
    }

    /// Runs only while the pool is holding something, so an app with nothing pooled schedules
    /// nothing at all. One task for the whole pool rather than one per connection, because the
    /// pool is one map and a sweep reads all of it.
    private func startSweeperIfNeeded() {
        guard sweeper == nil, !entries.isEmpty else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                guard !Task.isCancelled else { return }
                self?.sweepIdleEntries()
            }
        }
    }

    private func stopSweeperIfEmpty() {
        guard entries.isEmpty, pending.isEmpty else { return }
        sweeper?.cancel()
        sweeper = nil
    }

    /// Hands back every connection nobody has used for `idleTimeout`. An entry with work on it is
    /// left alone whatever its age: `lastUsed` is stamped when the work starts, so a long export
    /// would otherwise have its own connection closed underneath it.
    internal func sweepIdleEntries(now: Date = Date()) {
        for (key, entry) in entries where entry.inFlightCount == 0 && Self.isStale(entry.lastUsed, now: now) {
            entries.removeValue(forKey: key)
            entry.driver.disconnect()
        }
        stopSweeperIfEmpty()
    }

    private func evictIdleIfNeeded(for connectionId: UUID) {
        let live = entries.filter { $0.key.scope.connectionId == connectionId }
        let pendingCount = pending.keys.filter { $0.scope.connectionId == connectionId }.count
        guard live.count + pendingCount >= maxPerConnection else { return }
        let oldestIdle = live
            .filter { $0.value.inFlightCount == 0 }
            .min { $0.value.lastUsed < $1.value.lastUsed }
        guard let oldestIdle else { return }
        oldestIdle.value.driver.disconnect()
        entries.removeValue(forKey: oldestIdle.key)
    }
}
