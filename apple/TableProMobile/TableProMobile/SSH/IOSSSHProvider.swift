import Foundation
import os
import TableProDatabase
import TableProModels
import TableProSSHTransport

final class IOSSSHProvider: SSHProvider, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSSSHProvider")

    private let tunnelStore = TunnelStore()
    private let secureStore: SecureStore
    private let container: AppContainerPaths

    init(secureStore: SecureStore, container: AppContainerPaths = .live) {
        self.secureStore = secureStore
        self.container = container
    }

    func createTunnel(
        config: SSHConfiguration,
        connectionId: UUID,
        sshProfileId: UUID?,
        destination: SSHForwardDestination,
        prompter: (any ConnectionPrompter)?
    ) async throws -> TableProDatabase.SSHTunnel {
        var resolvedConfig = config
        resolvedConfig.privateKeyPath = config.privateKeyPath.map(container.localPath(forStoredPath:))
        let hopCredentials = try jumpHostCredentials(for: connectionId, hops: config.jumpHosts)

        let tunnel = try await SSHTunnelFactory.create(
            config: resolvedConfig,
            destination: destination,
            credentials: SSHTunnelCredentials(
                connectionId: connectionId,
                sshProfileId: sshProfileId,
                secureStore: secureStore
            ),
            jumpHostCredentials: hopCredentials,
            prompter: prompter
        )

        let tunnelId = UUID()
        await tunnelStore.add(tunnel, id: tunnelId, connectionId: connectionId)

        return TableProDatabase.SSHTunnel(id: tunnelId, localHost: "127.0.0.1", localPort: tunnel.localPort)
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
        guard let tunnel = await tunnelStore.remove(id: id) else { return }
        tunnel.close()
    }
}

/// Keyed by tunnel rather than by connection, because a cancelled attempt and the retry that
/// replaced it both own a tunnel for the same connection, and the loser must close only its own.
private actor TunnelStore {
    private struct Entry {
        let connectionId: UUID
        let tunnel: SSHTunnel
    }

    private var entries: [UUID: Entry] = [:]

    func add(_ tunnel: SSHTunnel, id: UUID, connectionId: UUID) {
        entries[id] = Entry(connectionId: connectionId, tunnel: tunnel)
    }

    func remove(id: UUID) -> SSHTunnel? {
        entries.removeValue(forKey: id)?.tunnel
    }

    func removeAll(connectionId: UUID) -> [SSHTunnel] {
        let matching = entries.filter { $0.value.connectionId == connectionId }
        for key in matching.keys { entries.removeValue(forKey: key) }
        return matching.values.map(\.tunnel)
    }
}
