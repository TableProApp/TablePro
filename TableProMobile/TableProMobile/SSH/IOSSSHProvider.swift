import Foundation
import TableProDatabase
import TableProModels

final class IOSSSHProvider: SSHProvider, @unchecked Sendable {
    private let tunnelStore = TunnelStore()
    private let secureStore: SecureStore

    init(secureStore: SecureStore) {
        self.secureStore = secureStore
    }

    func createTunnel(
        config: SSHConfiguration,
        connectionId: UUID,
        remoteHost: String,
        remotePort: Int
    ) async throws -> TableProDatabase.SSHTunnel {
        var resolvedConfig = config

        let sshPassword = try? secureStore.retrieve(
            forKey: "com.TablePro.sshpassword.\(connectionId.uuidString)")
        let keyPassphrase = try? secureStore.retrieve(
            forKey: "com.TablePro.keypassphrase.\(connectionId.uuidString)")

        if resolvedConfig.privateKeyData == nil || resolvedConfig.privateKeyData?.isEmpty == true {
            resolvedConfig.privateKeyData = try? secureStore.retrieve(
                forKey: "com.TablePro.sshkeydata.\(connectionId.uuidString)")
        }

        let tunnel = try await SSHTunnelFactory.create(
            config: resolvedConfig,
            remoteHost: remoteHost,
            remotePort: remotePort,
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase
        )

        let tunnelId = UUID()
        await tunnelStore.add(tunnel, id: tunnelId, connectionId: connectionId)

        let port = await tunnel.port
        return TableProDatabase.SSHTunnel(id: tunnelId, localHost: "127.0.0.1", localPort: port)
    }

    func closeTunnel(for connectionId: UUID) async throws {
        for tunnel in await tunnelStore.removeAll(connectionId: connectionId) {
            await tunnel.close()
        }
    }

    func closeTunnel(id: UUID) async throws {
        guard let tunnel = await tunnelStore.remove(id: id) else { return }
        await tunnel.close()
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
