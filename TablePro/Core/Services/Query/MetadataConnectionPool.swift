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

    typealias DriverOpener = @MainActor (DatabaseScope) async throws -> DatabaseDriver

    /// Why an open still in progress was taken away from the callers waiting on it.
    private enum Withdrawal {
        /// The transport it was dialing is being rebuilt, so its callers take a connection again
        /// once the replacement is in place.
        case transportReplaced
        /// What it was opened for is going away, so nothing may open it again.
        case closed
    }

    /// One open in progress, shared by every caller that asks for its key while it runs. It stays
    /// listed until the last of those callers has taken its entry, because an entry nobody has
    /// taken yet looks idle and would otherwise be the first one closed.
    @MainActor
    private final class PendingOpen {
        let task: Task<Void, Error>
        var withdrawal: Withdrawal?
        var waiterCount = 0

        init(task: Task<Void, Error>) {
            self.task = task
        }
    }

    private struct TransportWaiter {
        let ticket: UUID
        let scope: DatabaseScope
        let continuation: CheckedContinuation<Void, Error>
    }

    private var entries: [Key: Entry] = [:]
    private var pending: [Key: PendingOpen] = [:]
    private var transportReplacements: [UUID: Int] = [:]
    private var transportWaiters: [UUID: [TransportWaiter]] = [:]
    private let openDriver: DriverOpener
    static let maxPerConnection = 6
    private static let operationTimeoutSeconds: Double = 15
    private static let preparationTimeoutSeconds: Double = 60
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

    private init(openDriver: DriverOpener? = nil) {
        self.openDriver = openDriver ?? { scope in
            try await MetadataConnectionPool.openSessionDriver(for: scope)
        }
    }

    func withDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let entry = try await acquireEntry(scope: scope, workload: workload)
        entry.inFlightCount += 1
        entry.lastUsed = Date()
        defer { releaseEntry(entry, connectionId: scope.connectionId) }
        return try await entry.runSerially(body)
    }

    /// Closes only the leases attached to one database, which is what a rename of that database
    /// needs: PostgreSQL refuses `ALTER DATABASE ... RENAME` while any backend is connected to it,
    /// and an expanded row or a tab that ran a query there leaves one here.
    func closeAll(connectionId: UUID, database: String) {
        closeEntries(withdrawingOpensAs: .closed) { scope in
            scope.connectionId == connectionId && scope.database == database
        }
    }

    func closeAll(connectionId: UUID) {
        closeEntries(withdrawingOpensAs: .closed) { $0.connectionId == connectionId }
    }

    /// Holds a connection's pooled work while its transport is rebuilt.
    ///
    /// A pooled entry stands on the session's effective connection plus its own database, so it only
    /// has to go when that endpoint does: a tunnel rebuilt on a new local port, or a reconnect
    /// recovering a connection that stopped answering. An open already dialing is withdrawn, and once
    /// it has returned the callers waiting on it take a connection again after `endTransportReplacement`
    /// rather than failing a load nobody cancelled. A new caller waits for the same moment instead of
    /// dialing an endpoint about to close. Replacements nest, and pooled work resumes when the last one
    /// ends. Closing the connection, or one of its databases, fails the callers waiting for it.
    func beginTransportReplacement(connectionId: UUID) {
        transportReplacements[connectionId, default: 0] += 1
        closeEntries(withdrawingOpensAs: .transportReplaced) { $0.connectionId == connectionId }
    }

    /// Has to follow every `beginTransportReplacement` on every exit, cancellation included, or the
    /// connection's pooled work waits for good.
    func endTransportReplacement(connectionId: UUID) {
        guard let depth = transportReplacements[connectionId] else { return }
        guard depth == 1 else {
            transportReplacements[connectionId] = depth - 1
            return
        }
        transportReplacements.removeValue(forKey: connectionId)
        for waiter in transportWaiters.removeValue(forKey: connectionId) ?? [] {
            waiter.continuation.resume()
        }
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

    internal func heldConnectionCount(for connectionId: UUID) -> Int {
        heldCount(for: connectionId)
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
    /// entries another test injected into the shared one. `openDriver` stands in for opening a real
    /// connection, which a test with no plugin cannot do.
    internal static func isolatedForTesting(openDriver: DriverOpener? = nil) -> MetadataConnectionPool {
        MetadataConnectionPool(openDriver: openDriver)
    }

    /// How many callers are waiting for a transport replacement to end, so a test can wait for one
    /// to park instead of guessing how many scheduler turns that takes.
    internal func transportWaiterCount(for connectionId: UUID) -> Int {
        transportWaiters[connectionId]?.count ?? 0
    }

    internal func isReplacingTransport(for connectionId: UUID) -> Bool {
        transportReplacements[connectionId] != nil
    }
    #endif

    private func releaseEntry(_ entry: Entry, connectionId: UUID) {
        entry.inFlightCount -= 1
        guard entry.inFlightCount == 0 else { return }
        if entry.closeWhenIdle {
            entry.driver.disconnect()
            return
        }
        trimIdleEntries(for: connectionId)
    }

    private func closeOrDeferEntry(forKey key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if entry.inFlightCount == 0 {
            entry.driver.disconnect()
        } else {
            entry.closeWhenIdle = true
        }
    }

    private func closeEntries(
        withdrawingOpensAs withdrawal: Withdrawal,
        where matches: (DatabaseScope) -> Bool
    ) {
        for key in pending.keys where matches(key.scope) {
            guard let open = pending.removeValue(forKey: key) else { continue }
            open.withdrawal = withdrawal
            open.task.cancel()
        }
        if withdrawal == .closed {
            failTransportWaiters(where: matches)
        }
        for key in entries.keys where matches(key.scope) {
            closeOrDeferEntry(forKey: key)
        }
        stopSweeperIfEmpty()
    }

    /// A caller parked for a replacement is waiting on its connection as much as one waiting on a
    /// pending open, so closing what it waits for fails it too. Left parked, it would wake when the
    /// replacement ends and open a connection for a session, or a database, that has gone.
    private func failTransportWaiters(where matches: (DatabaseScope) -> Bool) {
        for (connectionId, waiters) in transportWaiters {
            let failing = waiters.filter { matches($0.scope) }
            guard !failing.isEmpty else { continue }
            let remaining = waiters.filter { !matches($0.scope) }
            transportWaiters[connectionId] = remaining.isEmpty ? nil : remaining
            for waiter in failing {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func acquireEntry(scope: DatabaseScope, workload: Workload) async throws -> Entry {
        let key = Key(scope: scope, workload: workload)
        while true {
            try await waitForTransport(for: scope)
            if let entry = reusableEntry(forKey: key) {
                return entry
            }
            let open = try pending[key] ?? startOpen(forKey: key)
            let failure = await completion(of: open, forKey: key)
            /// A withdrawn open can end either way: a driver whose connect honours cancellation
            /// throws, and one that finished first returns without keeping its entry.
            if open.withdrawal == .transportReplaced {
                try Task.checkCancellation()
                continue
            }
            if let failure {
                throw failure
            }
            if let entry = entries[key] {
                return entry
            }
            if open.withdrawal == .closed {
                throw DatabaseError.notConnected
            }
            forgetSpentOpen(open, forKey: key)
        }
    }

    /// An open whose entry went before this caller could take it has nothing left to hand out.
    /// Joining it again returns at once, without a suspension, so a caller that did would spin on
    /// the main actor and starve the other callers still waiting to resume from it.
    private func forgetSpentOpen(_ open: PendingOpen, forKey key: Key) {
        guard pending[key] === open else { return }
        pending.removeValue(forKey: key)
    }

    /// A cached entry is only worth reusing while it is both connected and recent. The
    /// staleness half matters even with the sweeper running, because a Mac that slept comes
    /// back with entries the sweeper never got to and sockets the server has long since
    /// closed. The old entry is closed rather than left behind: overwriting `entries[key]`
    /// with a fresh one used to leak the driver it replaced.
    private func reusableEntry(forKey key: Key) -> Entry? {
        guard let entry = entries[key] else { return nil }
        if entry.driver.status == .connected, !entry.driver.hasLostConnection, !Self.isStale(entry.lastUsed) {
            return entry
        }
        closeOrDeferEntry(forKey: key)
        return nil
    }

    private func startOpen(forKey key: Key) throws -> PendingOpen {
        guard DatabaseManager.shared.session(for: key.scope.connectionId) != nil else {
            throw DatabaseError.notConnected
        }
        evictIdleIfNeeded(for: key.scope.connectionId)
        let task = Task<Void, Error> { [self] in
            let entry = Entry(driver: try await openDriver(key.scope))
            if Task.isCancelled {
                entry.driver.disconnect()
                return
            }
            entries[key] = entry
            startSweeperIfNeeded()
        }
        let open = PendingOpen(task: task)
        pending[key] = open
        return open
    }

    /// Waits for an open to finish, takes it off the pending list once the last caller waiting on it
    /// has, and returns how it failed.
    private func completion(of open: PendingOpen, forKey key: Key) async -> Error? {
        open.waiterCount += 1
        defer {
            open.waiterCount -= 1
            if open.waiterCount == 0, pending[key] === open {
                pending.removeValue(forKey: key)
            }
        }
        do {
            try await open.task.value
            return nil
        } catch {
            return error
        }
    }

    /// Parks a caller for as long as the connection's transport is being replaced. A caller that is
    /// cancelled while parked stops waiting at once rather than when the replacement ends.
    private func waitForTransport(for scope: DatabaseScope) async throws {
        let connectionId = scope.connectionId
        while transportReplacements[connectionId] != nil {
            let ticket = UUID()
            try await withTaskCancellationHandler(
                operation: { try await parkForTransport(ticket: ticket, scope: scope) },
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.failTransportWaiter(ticket: ticket, connectionId: connectionId)
                    }
                }
            )
        }
    }

    private func parkForTransport(ticket: UUID, scope: DatabaseScope) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            transportWaiters[scope.connectionId, default: []].append(
                TransportWaiter(ticket: ticket, scope: scope, continuation: continuation)
            )
        }
    }

    /// Removes the ticket before resuming it, so a cancellation racing the end of a replacement can
    /// only ever find one of them.
    private func failTransportWaiter(ticket: UUID, connectionId: UUID) {
        guard var waiters = transportWaiters[connectionId],
              let index = waiters.firstIndex(where: { $0.ticket == ticket })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        transportWaiters[connectionId] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private static func openSessionDriver(for scope: DatabaseScope) async throws -> DatabaseDriver {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        var connection = session.effectiveConnection ?? session.connection
        let plan = Self.planConnection(
            configuredDatabase: connection.database,
            targetDatabase: scope.database,
            authenticationIsDatabaseScoped: connection.type.authenticationIsDatabaseScoped,
            runsStartupCommands: DatabaseManager.hasStartupCommands(session.connection.startupCommands),
            switchesDatabaseWithoutReconnecting: PluginManager.shared
                .switchesDatabaseWithoutReconnecting(for: connection.type)
        )
        connection.database = plan.connectDatabase

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true,
            purpose: .metadata
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
            if let schema = scope.schema {
                try await Self.switchSchema(driver, to: schema, timeoutSeconds: operationTimeoutSeconds)
            }
        } catch {
            driver.disconnect()
            throw error
        }
        return driver
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

    /// A pooled entry is pinned once, at creation, and then answered from for up to the idle
    /// timeout, where the session driver is pinned again before every scoped operation. So anything
    /// that moves the connection between `connect` and the first read moves it for the entry's whole
    /// life, and the only thing that runs in between is the user's own startup commands. A `USE
    /// other` there leaves every unqualified read answering from `other` while the driver still
    /// reports the database it was asked for, which is how an unqualified `ALTER TABLE` from the
    /// structure editor reached the wrong one.
    ///
    /// Re-asserted only when there is something to undo and only where the engine takes a switch as
    /// a statement: an engine that reconnects to switch would throw away the startup commands it
    /// just ran, and one that cannot switch at all would fail a connection that works today. That is
    /// the same pair `pin(_:to:)` already trusts, so the pool issues no statement the session driver
    /// does not issue for the same scope.
    static func planConnection(
        configuredDatabase: String,
        targetDatabase: String,
        authenticationIsDatabaseScoped: Bool,
        runsStartupCommands: Bool = false,
        switchesDatabaseWithoutReconnecting: Bool = false
    ) -> ConnectionPlan {
        guard authenticationIsDatabaseScoped, targetDatabase != configuredDatabase else {
            let reassert = runsStartupCommands && switchesDatabaseWithoutReconnecting
                && !targetDatabase.isEmpty
            return ConnectionPlan(
                connectDatabase: targetDatabase, switchDatabase: reassert ? targetDatabase : nil
            )
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

    /// Makes room for one more before an open. The caller never waits for room, so a burst of opens
    /// can still run past the limit while its work is in flight; `trimIdleEntries` hands the extra
    /// back as that work ends.
    private func evictIdleIfNeeded(for connectionId: UUID) {
        guard heldCount(for: connectionId) >= Self.maxPerConnection else { return }
        evictLeastRecentlyUsedIdleEntry(for: connectionId)
    }

    /// Keeps a connection at the limit once its work ends. Closing only one idle entry per open, as
    /// the pool used to, left a burst's high-water mark standing until the idle sweep: a tree Refresh
    /// across many databases held every connection it opened for ten minutes (#3103).
    private func trimIdleEntries(for connectionId: UUID) {
        while heldCount(for: connectionId) > Self.maxPerConnection {
            guard evictLeastRecentlyUsedIdleEntry(for: connectionId) else { break }
        }
        stopSweeperIfEmpty()
    }

    /// Every key the connection holds a connection for or is opening one for. Counted by key, so an
    /// open that has finished but is still listed until its callers take the entry counts once.
    private func heldCount(for connectionId: UUID) -> Int {
        var keys = Set(entries.keys.filter { $0.scope.connectionId == connectionId })
        keys.formUnion(pending.keys.filter { $0.scope.connectionId == connectionId })
        return keys.count
    }

    /// An entry whose open is still listed has callers that have not taken it yet, so it is not idle
    /// however it looks.
    @discardableResult
    private func evictLeastRecentlyUsedIdleEntry(for connectionId: UUID) -> Bool {
        let idle = entries.filter { key, entry in
            key.scope.connectionId == connectionId && entry.inFlightCount == 0 && pending[key] == nil
        }
        guard let oldest = idle.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return false }
        entries.removeValue(forKey: oldest.key)
        oldest.value.driver.disconnect()
        return true
    }
}
