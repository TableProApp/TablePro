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
    private var teardowns: [UUID: Teardown] = [:]
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
        switch await awaitTeardown(of: connection.id) {
        case .cleared:
            break
        case .cancelled:
            throw CancellationError()
        case .stillClosing:
            throw ConnectionError.previousSessionStillClosing(connection.name)
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

    /// Drops the session and waits for its teardown under the same bound `connect` uses, then returns
    /// whether or not the teardown landed, so a stuck driver cannot hold a background release open.
    public func disconnect(_ connectionId: UUID) async {
        invalidateAttempt(for: connectionId)
        await awaitTeardown(of: connectionId)
    }

    @discardableResult
    private func awaitTeardown(of connectionId: UUID) async -> TeardownWait {
        guard let teardown = claimTeardown(for: connectionId) else { return .cleared }
        switch await BoundedWait.outcome(of: teardown.task, within: teardownWaitLimit) {
        case .completed:
            return .cleared
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .stillClosing
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
    /// `finishTeardown` cannot clear an entry that is not installed yet.
    private func claimTeardown(for connectionId: UUID) -> Teardown? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: connectionId) else {
            return teardowns[connectionId]
        }
        lastTeardownId += 1
        let teardownId = lastTeardownId
        let sshProvider = sshProvider
        let task = Task { [weak self] in
            if let sshProvider {
                try? await sshProvider.closeTunnel(for: connectionId)
            }
            try? await session.driver.disconnect()
            self?.finishTeardown(teardownId, for: connectionId)
        }
        let teardown = Teardown(id: teardownId, task: task)
        teardowns[connectionId] = teardown
        if session.driver.holdsSuspensionBlockingResource {
            blockingTeardowns.insert(connectionId)
        }
        return teardown
    }

    private func finishTeardown(_ teardownId: Int, for connectionId: UUID) {
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

    private struct Teardown: Sendable {
        let id: Int
        let task: Task<Void, Never>
    }

    private enum TeardownWait: Sendable {
        case cleared
        case cancelled
        case stillClosing
    }
}

/// `await task.value` on a `Task<_, Never>` ignores the awaiting task's cancellation entirely: measured,
/// a waiter cancelled at +0.200s stayed suspended until the task it awaited finished at +1.059s. Bridging
/// the completion through an `AsyncStream`, whose iterator is cancellation-aware, ends the wait at +0.205s.
private enum BoundedWait {
    fileprivate enum Outcome<Value: Sendable>: Sendable {
        case completed(Value)
        case cancelled
        case timedOut
    }

    fileprivate static func outcome<Value: Sendable>(
        of task: Task<Value, Never>,
        within limit: Duration
    ) async -> Outcome<Value> {
        let (outcomes, reporter) = AsyncStream<Outcome<Value>>.makeStream()
        Task { reporter.yield(.completed(await task.value)) }
        let deadline = Task {
            do {
                try await Task.sleep(for: limit)
            } catch {
                return
            }
            reporter.yield(.timedOut)
        }
        defer { deadline.cancel() }
        var iterator = outcomes.makeAsyncIterator()
        return await iterator.next() ?? .cancelled
    }
}
