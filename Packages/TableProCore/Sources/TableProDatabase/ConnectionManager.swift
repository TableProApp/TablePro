import Foundation
import TableProModels

public final class ConnectionManager: @unchecked Sendable {
    private let driverFactory: DriverFactory
    private let secureStore: SecureStore
    private let sshProvider: SSHProvider?

    private let lock = NSLock()
    private var sessions: [UUID: ConnectionSession] = [:]
    private var teardowns: [UUID: Task<Void, Never>] = [:]
    private var blockingTeardowns: Set<UUID> = []
    private var attemptGenerations: [UUID: Int] = [:]

    public init(
        driverFactory: DriverFactory,
        secureStore: SecureStore,
        sshProvider: SSHProvider? = nil
    ) {
        self.driverFactory = driverFactory
        self.secureStore = secureStore
        self.sshProvider = sshProvider
    }

    public func connect(_ connection: DatabaseConnection) async throws -> ConnectionSession {
        let generation = beginAttempt(for: connection.id)
        await awaitTeardown(of: connection.id)
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
                remotePort: connection.port
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
                try? await driver.disconnect()
                if let tunnelId, let provider = sshProvider {
                    try? await provider.closeTunnel(id: tunnelId)
                }
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

    public func disconnect(_ connectionId: UUID) async {
        invalidateAttempt(for: connectionId)
        await awaitTeardown(of: connectionId)
    }

    private func awaitTeardown(of connectionId: UUID) async {
        guard let teardown = claimTeardown(for: connectionId) else { return }
        await teardown.value
        finishTeardown(teardown, for: connectionId)
    }

    private func isCurrentAttempt(_ generation: Int, for connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attemptGenerations[connectionId] == generation
    }

    public var hasSuspensionBlockingResources: Bool {
        !suspensionBlockingIds().isEmpty
    }

    public func releaseSuspensionBlockingResources() async {
        let ids = suspensionBlockingIds()
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.disconnect(id) }
            }
        }
    }

    private func suspensionBlockingIds() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        let connected = sessions.filter { $0.value.driver.holdsSuspensionBlockingResource }.map(\.key)
        return Array(blockingTeardowns.union(connected))
    }

    private func claimTeardown(for connectionId: UUID) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: connectionId) else {
            return teardowns[connectionId]
        }
        let sshProvider = sshProvider
        let teardown = Task {
            try? await session.driver.disconnect()
            if let sshProvider {
                try? await sshProvider.closeTunnel(for: connectionId)
            }
        }
        teardowns[connectionId] = teardown
        if session.driver.holdsSuspensionBlockingResource {
            blockingTeardowns.insert(connectionId)
        }
        return teardown
    }

    private func finishTeardown(_ teardown: Task<Void, Never>, for connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard teardowns[connectionId] == teardown else { return }
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
}
