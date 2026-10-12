import Foundation
import TableProModels

public final class ConnectionManager: @unchecked Sendable {
    public static let defaultTeardownWaitLimit: Duration = .seconds(5)

    private let driverFactory: DriverFactory
    private let secureStore: SecureStore
    private let sshProvider: SSHProvider?
    private let teardownWaitLimit: Duration

    private let lock = NSLock()
    private var sessions: [UUID: ConnectionSession] = [:]
    private var teardowns: [UUID: ConnectionTeardown] = [:]
    private var blockingTeardowns: Set<UUID> = []
    private var attemptGenerations: [UUID: Int] = [:]
    private var lastTeardownId = 0

    public init(
        driverFactory: DriverFactory,
        secureStore: SecureStore,
        sshProvider: SSHProvider? = nil,
        teardownWaitLimit: Duration = ConnectionManager.defaultTeardownWaitLimit
    ) {
        self.driverFactory = driverFactory
        self.secureStore = secureStore
        self.sshProvider = sshProvider
        self.teardownWaitLimit = teardownWaitLimit
    }

    /// Opens a session, waiting out a teardown still running for the same connection first.
    ///
    /// That wait ends on the calling task's cancellation with `CancellationError`, and after
    /// `teardownWaitLimit` with `ConnectionError.previousSessionStillClosing`. Neither ending opens a
    /// session over resources the old driver still holds, and neither retires the teardown: it keeps
    /// running, it keeps counting as a suspension-blocking resource, and the next attempt succeeds as
    /// soon as it lands.
    public func connect(
        _ connection: DatabaseConnection,
        prompter: (any ConnectionPrompter)? = nil
    ) async throws -> ConnectionSession {
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
            guard adoptSession(session, for: connection.id, generation: generation) else {
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

    private func adoptSession(_ session: ConnectionSession, for id: UUID, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard attemptGenerations[id] == generation else { return false }
        sessions[id] = session
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
            return await Self.wait(on: teardown, within: limit)
        }
    }

    private static func wait(on teardown: ConnectionTeardown, within limit: Duration) async -> TeardownWait {
        await withTaskGroup(of: TeardownWait.self) { group in
            group.addTask {
                await teardown.waitUntilFinished() ? .cleared : .cancelled
            }
            group.addTask {
                do {
                    try await Task.sleep(for: limit)
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
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: connectionId) else {
            return teardowns[connectionId]
        }
        lastTeardownId += 1
        let teardown = ConnectionTeardown(id: lastTeardownId)
        let sshProvider = sshProvider
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
        return teardown
    }

    /// Runs before `ConnectionTeardown.finish()`, so a waiter it wakes already reads the cleared state.
    private func retireTeardown(_ teardownId: Int, for connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard teardowns[connectionId]?.id == teardownId else { return }
        teardowns.removeValue(forKey: connectionId)
        blockingTeardowns.remove(connectionId)
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
    }

    public func session(for connectionId: UUID) -> ConnectionSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[connectionId]
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
