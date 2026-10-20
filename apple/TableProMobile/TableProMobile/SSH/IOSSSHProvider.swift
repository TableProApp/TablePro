import Foundation
import os
import TableProDatabase
import TableProModels

nonisolated protocol ProvidedTunnel: AnyObject, Sendable {
    var localPort: Int { get }
    func close()
    func onDeath(_ handler: @escaping @Sendable () -> Void)
}

extension SSHTunnel: ProvidedTunnel {}

nonisolated struct TunnelRequest: Sendable {
    let config: SSHConfiguration
    let remoteHost: String
    let remotePort: Int
    let credentials: SSHTunnelCredentials
    let jumpHostCredentials: [UUID: JumpHostCredential]
    let prompter: (any ConnectionPrompter)?
}

final class IOSSSHProvider: SSHProvider, @unchecked Sendable {
    typealias OpenTunnel = @Sendable (TunnelRequest) async throws -> any ProvidedTunnel

    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSSSHProvider")

    private let tunnelStore = TunnelStore()
    private let secureStore: SecureStore
    private let container: AppContainerPaths
    private let openTunnel: OpenTunnel
    private let deathObservers = OSAllocatedUnfairLock<[@Sendable (UUID) -> Void]>(initialState: [])

    init(
        secureStore: SecureStore,
        container: AppContainerPaths = .live,
        openTunnel: @escaping OpenTunnel = { request in
            try await SSHTunnelFactory.create(
                config: request.config,
                remoteHost: request.remoteHost,
                remotePort: request.remotePort,
                credentials: request.credentials,
                jumpHostCredentials: request.jumpHostCredentials,
                prompter: request.prompter
            )
        }
    ) {
        self.secureStore = secureStore
        self.container = container
        self.openTunnel = openTunnel
    }

    // Called with the connection whose tunnel stopped on its own, as the Mac's onDeath reports it.
    func observeTunnelDeaths(_ observer: @escaping @Sendable (UUID) -> Void) {
        deathObservers.withLock { $0.append(observer) }
    }

    func createTunnel(
        config: SSHConfiguration,
        connectionId: UUID,
        remoteHost: String,
        remotePort: Int,
        prompter: (any ConnectionPrompter)?
    ) async throws -> TableProDatabase.SSHTunnel {
        var resolvedConfig = config
        resolvedConfig.privateKeyPath = config.privateKeyPath.map(container.localPath(forStoredPath:))
        let hopCredentials = try jumpHostCredentials(for: connectionId, hops: config.jumpHosts)

        let tunnel = try await openTunnel(TunnelRequest(
            config: resolvedConfig,
            remoteHost: remoteHost,
            remotePort: remotePort,
            credentials: SSHTunnelCredentials(connectionId: connectionId, secureStore: secureStore),
            jumpHostCredentials: hopCredentials,
            prompter: prompter
        ))

        let tunnelId = UUID()
        await tunnelStore.add(tunnel, id: tunnelId, connectionId: connectionId)
        tunnel.onDeath { [weak self] in
            Task { await self?.tunnelDied(id: tunnelId) }
        }

        return TableProDatabase.SSHTunnel(id: tunnelId, localHost: "127.0.0.1", localPort: tunnel.localPort)
    }

    // A tunnel its owner already closed or replaced is not a death worth reporting.
    private func tunnelDied(id: UUID) async {
        guard let connectionId = await tunnelStore.remove(id: id)?.connectionId else { return }
        Self.logger.warning("SSH tunnel stopped for connection \(connectionId, privacy: .public)")
        for observer in deathObservers.withLock({ $0 }) {
            observer(connectionId)
        }
    }

    // A key that could not be read is not a missing key: telling the user to set one would be wrong.
    private func jumpHostCredentials(for connectionId: UUID, hops: [SSHJumpHost]) throws -> [UUID: JumpHostCredential] {
        guard !hops.isEmpty else { return [:] }
        do {
            return try JumpHostCredentialStore.load(for: connectionId, in: secureStore)
        } catch {
            let privateDescription = String(reflecting: error)
            Self.logger.error("Reading the jump host keys failed: \(privateDescription, privacy: .private)")
            throw SSHTunnelError.jumpHostKeysUnreadable(error.localizedDescription)
        }
    }

    func closeTunnel(for connectionId: UUID) async throws {
        for tunnel in await tunnelStore.removeAll(connectionId: connectionId) {
            tunnel.close()
        }
    }

    func closeTunnel(id: UUID) async throws {
        guard let entry = await tunnelStore.remove(id: id) else { return }
        entry.tunnel.close()
    }
}

/// Keyed by tunnel rather than by connection, because a cancelled attempt and the retry that
/// replaced it both own a tunnel for the same connection, and the loser must close only its own.
private actor TunnelStore {
    struct Entry {
        let connectionId: UUID
        let tunnel: any ProvidedTunnel
    }

    private var entries: [UUID: Entry] = [:]

    func add(_ tunnel: any ProvidedTunnel, id: UUID, connectionId: UUID) {
        entries[id] = Entry(connectionId: connectionId, tunnel: tunnel)
    }

    func remove(id: UUID) -> Entry? {
        entries.removeValue(forKey: id)
    }

    func removeAll(connectionId: UUID) -> [any ProvidedTunnel] {
        let matching = entries.filter { $0.value.connectionId == connectionId }
        for key in matching.keys { entries.removeValue(forKey: key) }
        return matching.values.map(\.tunnel)
    }
}
