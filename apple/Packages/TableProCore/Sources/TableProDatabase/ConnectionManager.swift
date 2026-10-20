import Foundation
import TableProModels

public final class ConnectionManager: @unchecked Sendable {
    public static let defaultTeardownWaitLimit: Duration = .seconds(5)

    private let driverFactory: DriverFactory
    private let secureStore: SecureStore
    private let sshProvider: SSHProvider?
    private let teardownWaitLimit: Duration
    private let clock: any Clock<Duration>

    private let lock = NSLock()
    private var sessions: [UUID: ConnectionSession] = [:]
    private var teardowns: [UUID: ConnectionTeardown] = [:]
    private var blockingTeardowns: Set<UUID> = []
    private var attemptGenerations: [UUID: Int] = [:]
    private var lastTeardownId = 0
    private var sessionEndObservers: [@Sendable (UUID, any DatabaseDriver) -> Void] = []
    private var dials: [UUID: SessionDial] = [:]
    private var catalogs: [UUID: CatalogConnection] = [:]
    private let now: @Sendable () -> Date

    // The Mac's metadata pool values: an idle server connection is not held for good, and a failure is tried again.
    static let catalogIdleLimit: TimeInterval = 600
    static let catalogRetryDelay: TimeInterval = 30

    public init(
        driverFactory: DriverFactory,
        secureStore: SecureStore,
        sshProvider: SSHProvider? = nil,
        teardownWaitLimit: Duration = ConnectionManager.defaultTeardownWaitLimit,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.driverFactory = driverFactory
        self.secureStore = secureStore
        self.sshProvider = sshProvider
        self.teardownWaitLimit = teardownWaitLimit
        self.clock = clock
        self.now = now
    }

    // A teardown wait that gives up leaves the teardown running and counting as suspension-blocking.
    public func connect(
        _ connection: DatabaseConnection,
        prompter: (any ConnectionPrompter)? = nil
    ) async throws -> ConnectionSession {
        // Ahead of beginAttempt, so a refusal neither cancels an attempt in flight nor tears down the open session.
        if let refusal = driverFactory.refusal(for: connection) { throw refusal }
        let generation = beginAttempt(for: connection.id)
        switch await awaitTeardown(of: connection.id, bound: .after(teardownWaitLimit)) {
        case .cleared:
            break
        case .cancelled:
            throw CancellationError()
        case .stillClosing:
            throw ConnectionError.previousSessionStillClosing
        }
        guard isCurrentAttempt(generation, for: connection.id) else { throw CancellationError() }
        let password = try secureStore.retrieve(forKey: Self.passwordKey(for: connection.id))

        var effectiveHost = connection.host
        var effectivePort = connection.port
        var tunnelId: UUID?
        if connection.sshEnabled, let ssh = connection.sshConfiguration {
            guard let provider = sshProvider else {
                throw ConnectionError.sshNotSupported
            }
            let tunnel = try await provider.createTunnel(
                config: ssh,
                connectionId: connection.id,
                remoteHost: connection.host,
                remotePort: connection.port,
                prompter: prompter
            )
            tunnelId = tunnel.id
            effectiveHost = tunnel.localHost
            effectivePort = tunnel.localPort
        }

        do {
            var effectiveConnection = connection
            effectiveConnection.host = effectiveHost
            effectiveConnection.port = effectivePort

            let driver = try driverFactory.createDriver(for: effectiveConnection, password: password)
            try await driver.connect()

            let session = ConnectionSession(
                connectionId: connection.id,
                driver: driver,
                activeDatabase: connection.database,
                status: .connected
            )
            let dial = SessionDial(connection: connection, host: effectiveHost, port: effectivePort)
            guard adoptSession(session, dial: dial, for: connection.id, generation: generation) else {
                if let tunnelId, let provider = sshProvider {
                    try? await provider.closeTunnel(id: tunnelId)
                }
                try? await driver.disconnect()
                throw CancellationError()
            }
            return session
        } catch {
            if let tunnelId, let provider = sshProvider {
                try? await provider.closeTunnel(id: tunnelId)
            }
            throw error
        }
    }

    /// `Task.cancel()` cannot retire an attempt: the drivers block in C calls that never observe it.
    public func invalidateAttempt(for connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        attemptGenerations[connectionId, default: 0] += 1
    }

    private func beginAttempt(for connectionId: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (attemptGenerations[connectionId] ?? 0) + 1
        attemptGenerations[connectionId] = next
        return next
    }

    private func adoptSession(_ session: ConnectionSession, dial: SessionDial, for id: UUID, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard attemptGenerations[id] == generation else { return false }
        sessions[id] = session
        dials[id] = dial
        return true
    }

    public func storePassword(_ password: String, for connectionId: UUID) throws {
        try secureStore.store(password, forKey: Self.passwordKey(for: connectionId))
    }

    public func deletePassword(for connectionId: UUID) throws {
        try secureStore.delete(forKey: Self.passwordKey(for: connectionId))
    }

    private static func passwordKey(for connectionId: UUID) -> String {
        "com.TablePro.password.\(connectionId.uuidString)"
    }

    /// Drops the session and waits for the teardown to land, rather than bounding it the way `connect`
    /// does. `releaseSuspensionBlockingResources` runs through here under an iOS background task
    /// assertion taken to cover exactly this wait, and giving up early ends that assertion over a driver
    /// that still holds its file: a `duckdb_close` that checkpoints a long WAL takes as long as it takes.
    /// The assertion's own expiration handler is the bound, because it is the only one the system honours.
    public func disconnect(_ connectionId: UUID) async {
        invalidateAttempt(for: connectionId)
        await awaitTeardown(of: connectionId, bound: .untilFinished)
    }

    @discardableResult
    private func awaitTeardown(of connectionId: UUID, bound: TeardownBound) async -> TeardownWait {
        guard let teardown = claimTeardown(for: connectionId) else { return .cleared }
        switch bound {
        case .untilFinished:
            return await teardown.waitUntilFinished() ? .cleared : .cancelled
        case .after(let limit):
            return await Self.wait(on: teardown, within: limit, clock: clock)
        }
    }

    private static func wait(
        on teardown: ConnectionTeardown,
        within limit: Duration,
        clock: any Clock<Duration>
    ) async -> TeardownWait {
        await withTaskGroup(of: TeardownWait.self) { group in
            group.addTask {
                await teardown.waitUntilFinished() ? .cleared : .cancelled
            }
            group.addTask {
                do {
                    try await clock.sleep(for: limit)
                } catch {
                    return .cancelled
                }
                return .stillClosing
            }
            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            return outcome
        }
    }

    private func isCurrentAttempt(_ generation: Int, for connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attemptGenerations[connectionId] == generation
    }

    public var hasSuspensionBlockingResources: Bool {
        !suspensionBlockingIds().isEmpty
    }

    @discardableResult
    public func releaseSuspensionBlockingResources() async -> [UUID] {
        let ids = suspensionBlockingIds()
        guard !ids.isEmpty else { return [] }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.disconnect(id) }
            }
        }
        return ids
    }

    private func suspensionBlockingIds() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        let connected = sessions.filter { $0.value.driver.holdsSuspensionBlockingResource }.map(\.key)
        return Array(blockingTeardowns.union(connected))
    }

    /// Closes the tunnel before the driver, because a driver blocked reading through a tunnel the server
    /// dropped only returns once its socket's peer closes; the reverse order queues `disconnect()` behind
    /// a read that never completes. The lock is held past the `teardowns` write, so the task's own
    /// `retireTeardown` cannot clear an entry that is not installed yet.
    private func claimTeardown(for connectionId: UUID) -> ConnectionTeardown? {
        lock.lock()
        guard let session = sessions.removeValue(forKey: connectionId) else {
            let running = teardowns[connectionId]
            lock.unlock()
            return running
        }
        lastTeardownId += 1
        let teardown = ConnectionTeardown(id: lastTeardownId)
        let sshProvider = sshProvider
        dials.removeValue(forKey: connectionId)
        let catalog = catalogs.removeValue(forKey: connectionId)
        // Apart from the teardown, which a catalog open still dialing would otherwise hold for its connect timeout.
        if let catalog {
            Task { await catalog.close() }
        }
        Task { [weak self] in
            if let sshProvider {
                try? await sshProvider.closeTunnel(for: connectionId)
            }
            try? await session.driver.disconnect()
            self?.retireTeardown(teardown.id, for: connectionId)
            teardown.finish()
        }
        teardowns[connectionId] = teardown
        if session.driver.holdsSuspensionBlockingResource {
            blockingTeardowns.insert(connectionId)
        }
        let observers = sessionEndObservers
        lock.unlock()
        // After the unlock: an observer may call back into the manager, and this lock is not recursive.
        for observer in observers {
            observer(connectionId, session.driver)
        }
        return teardown
    }

    public func observeSessionEnds(_ observer: @escaping @Sendable (UUID, any DatabaseDriver) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sessionEndObservers.append(observer)
    }

    /// Runs before `ConnectionTeardown.finish()`, so a waiter it wakes already reads the cleared state.
    private func retireTeardown(_ teardownId: Int, for connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard teardowns[connectionId]?.id == teardownId else { return }
        teardowns.removeValue(forKey: connectionId)
        blockingTeardowns.remove(connectionId)
    }

    // For catalog reads the user did not ask for: on the session they would end a page the grid streams and replace
    // MySQL's ROW_COUNT() and warnings or SQL Server's @@ROWCOUNT. Nil for an engine with one connection per file.
    public func catalogDriver(for connectionId: UUID, database: String) async -> (any DatabaseDriver)? {
        switch claimCatalog(for: connectionId, database: database) {
        case nil:
            return nil
        case .join(let connection):
            return await connection.driver()
        case .opened(let connection, let replaced):
            if let replaced {
                Task { await replaced.close() }
            }
            let driver = await connection.driver()
            // A teardown or a newer key that landed during the open owns the slot; this driver is nobody's.
            guard isCurrentCatalog(connection, for: connectionId) else {
                await connection.close()
                return nil
            }
            return driver
        }
    }

    // Nil when there is no catalog connection, or it stopped answering and was dropped: the caller reads elsewhere.
    public func readCatalog<T: Sendable>(
        for connectionId: UUID,
        database: String,
        _ read: @Sendable (any DatabaseDriver) async throws -> T
    ) async throws -> T? {
        guard let driver = await catalogDriver(for: connectionId, database: database) else { return nil }
        do {
            return try await read(driver)
        } catch {
            guard (try? await driver.ping()) != true else { throw error }
            await discardCatalogDriver(driver, for: connectionId)
            return nil
        }
    }

    public func discardCatalogDriver(_ driver: any DatabaseDriver, for connectionId: UUID) async {
        guard let connection = takeCatalog(holding: driver, for: connectionId) else { return }
        await connection.close()
    }

    private func claimCatalog(for connectionId: UUID, database: String) -> CatalogClaim? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[connectionId], let dial = dials[connectionId],
              driverFactory.opensCatalogConnections(for: dial.connection) else {
            return nil
        }
        let key = CatalogKey(session: ObjectIdentifier(session.driver), database: database)
        let time = now()
        if let existing = catalogs[connectionId], existing.key == key,
           existing.isFresh(at: time, idleLimit: Self.catalogIdleLimit, retryDelay: Self.catalogRetryDelay) {
            existing.markUsed(at: time)
            return .join(existing)
        }
        let replaced = catalogs[connectionId]
        let now = self.now
        let opening = CatalogConnection(key: key, startedAt: time, now: now) { [driverFactory, secureStore] in
            try await Self.openCatalogDriver(dial: dial, database: database, factory: driverFactory, secureStore: secureStore)
        }
        catalogs[connectionId] = opening
        return .opened(opening, replacing: replaced)
    }

    private func takeCatalog(holding driver: any DatabaseDriver, for connectionId: UUID) -> CatalogConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard let connection = catalogs[connectionId], connection.holds(driver) else { return nil }
        catalogs.removeValue(forKey: connectionId)
        return connection
    }

    private func takeCatalog(for connectionId: UUID, unlessDatabase database: String) -> CatalogConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard let connection = catalogs[connectionId], connection.key.database != database else { return nil }
        catalogs.removeValue(forKey: connectionId)
        return connection
    }

    private func isCurrentCatalog(_ connection: CatalogConnection, for connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return catalogs[connectionId] === connection
    }

    private static func openCatalogDriver(
        dial: SessionDial,
        database: String,
        factory: DriverFactory,
        secureStore: SecureStore
    ) async throws -> any DatabaseDriver {
        var target = dial.connection
        if !database.isEmpty {
            target.database = database
        }
        target.host = dial.host
        target.port = dial.port
        let password = try secureStore.retrieve(forKey: passwordKey(for: dial.connection.id))
        let driver = try factory.createDriver(for: target, password: password)
        try await driver.connect()
        do {
            try await factory.prepareCatalogDriver(driver, for: target)
        } catch {
            try? await driver.disconnect()
            throw error
        }
        return driver
    }

    public func updateSession(_ connectionId: UUID, _ mutation: (inout ConnectionSession) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[connectionId] else { return }
        mutation(&session)
        sessions[connectionId] = session
    }

    public func switchDatabase(_ connectionId: UUID, to database: String) async throws {
        guard let session = session(for: connectionId) else {
            throw ConnectionError.notConnected
        }
        try await session.driver.switchDatabase(to: database)
        updateSession(connectionId) { $0.activeDatabase = database }
        // SQL Server refuses to drop a database a connection is in, so the catalog connection leaves with the session.
        if let catalog = takeCatalog(for: connectionId, unlessDatabase: database) {
            await catalog.close()
        }
    }

    public func session(for connectionId: UUID) -> ConnectionSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[connectionId]
    }

    private enum CatalogClaim {
        case join(CatalogConnection)
        case opened(CatalogConnection, replacing: CatalogConnection?)
    }

    private enum TeardownBound: Sendable {
        case after(Duration)
        case untilFinished
    }

    private enum TeardownWait: Sendable {
        case cleared
        case cancelled
        case stillClosing
    }
}

/// One teardown, and the waiters parked on it.
///
/// `await task.value` on a `Task<_, Never>` ignores the awaiting task's cancellation entirely: measured,
/// a waiter cancelled at +0.200s stayed suspended until the task it awaited finished at +1.059s. Parking
/// each waiter on its own continuation is what makes a wait cancellable, and it is also what lets a wait
/// that gives up take its continuation with it, rather than leaving one bridging task per attempt
/// suspended for as long as the teardown runs.
private final class ConnectionTeardown: @unchecked Sendable {
    let id: Int

    private let lock = NSLock()
    private var hasFinished = false
    private var lastWaiterId = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledWaiters: Set<Int> = []

    init(id: Int) {
        self.id = id
    }

    func finish() {
        lock.lock()
        hasFinished = true
        let parked = waiters
        waiters.removeAll()
        cancelledWaiters.removeAll()
        lock.unlock()
        for continuation in parked.values {
            continuation.resume(returning: true)
        }
    }

    /// `true` once the teardown lands, `false` when the waiting task is cancelled before it does.
    func waitUntilFinished() async -> Bool {
        let waiterId = reserveWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                park(continuation, as: waiterId)
            }
        } onCancel: {
            cancelWaiter(waiterId)
        }
    }

    private func reserveWaiter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        lastWaiterId += 1
        return lastWaiterId
    }

    /// Cancellation can land before the continuation exists, so a waiter cancelled that early is recorded
    /// by id and answered here instead.
    private func park(_ continuation: CheckedContinuation<Bool, Never>, as waiterId: Int) {
        lock.lock()
        if hasFinished {
            lock.unlock()
            continuation.resume(returning: true)
            return
        }
        if cancelledWaiters.remove(waiterId) != nil {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        waiters[waiterId] = continuation
        lock.unlock()
    }

    private func cancelWaiter(_ waiterId: Int) {
        lock.lock()
        if hasFinished {
            lock.unlock()
            return
        }
        guard let continuation = waiters.removeValue(forKey: waiterId) else {
            cancelledWaiters.insert(waiterId)
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume(returning: false)
    }
}

// The host and port are the tunnel's local end when SSH is on, so a catalog connection reuses the tunnel.
private struct SessionDial: Sendable {
    let connection: DatabaseConnection
    let host: String
    let port: Int
}

private struct CatalogKey: Equatable, Sendable {
    let session: ObjectIdentifier
    let database: String
}

private final class CatalogConnection: @unchecked Sendable {
    let key: CatalogKey

    private let lock = NSLock()
    private let opening: Task<(any DatabaseDriver)?, Never>
    private var opened: (any DatabaseDriver)?
    private let failures: FailureClock
    private var isClosed = false
    private var lastUsed: Date

    init(
        key: CatalogKey,
        startedAt: Date,
        now: @escaping @Sendable () -> Date,
        open: @escaping @Sendable () async throws -> any DatabaseDriver
    ) {
        self.key = key
        self.lastUsed = startedAt
        let failures = FailureClock()
        self.failures = failures
        self.opening = Task {
            do {
                return try await open()
            } catch {
                failures.record(now())
                return nil
            }
        }
    }

    func driver() async -> (any DatabaseDriver)? {
        adopt(await opening.value)
    }

    func holds(_ driver: any DatabaseDriver) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let opened else { return false }
        return opened === driver
    }

    // A failed open is tried again after a while; an idle connection may be one the server or a NAT already dropped.
    func isFresh(at time: Date, idleLimit: TimeInterval, retryDelay: TimeInterval) -> Bool {
        if let failedAt = failures.time { return time.timeIntervalSince(failedAt) < retryDelay }
        lock.lock()
        defer { lock.unlock() }
        return time.timeIntervalSince(lastUsed) < idleLimit
    }

    func markUsed(at time: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastUsed = time
    }

    // A close that lands while the open is in flight still ends the connection once it is up.
    func close() async {
        guard markClosed(), let driver = await opening.value else { return }
        try? await driver.disconnect()
    }

    private func adopt(_ driver: (any DatabaseDriver)?) -> (any DatabaseDriver)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        opened = driver
        return driver
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        isClosed = true
        opened = nil
        return true
    }
}

private final class FailureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Date?

    var time: Date? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ time: Date) {
        lock.lock()
        defer { lock.unlock() }
        recorded = time
    }
}
