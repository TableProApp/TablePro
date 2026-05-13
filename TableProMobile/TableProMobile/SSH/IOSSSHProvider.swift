import Foundation
import TableProDatabase
import TableProModels

final class IOSSSHProvider: SSHProvider, @unchecked Sendable {
    private let tunnelStore = TunnelStore()
    private let secureStore: SecureStore

    init(secureStore: SecureStore) {
        self.secureStore = secureStore
    }

    /// Set pending connectionId atomically via the TunnelStore actor.
    /// Must be called before createTunnel to enable connectionId-based Keychain lookup.
    func setPendingConnectionId(_ id: UUID) async {
        await tunnelStore.setPending(id)
    }

    func createTunnel(
        config: SSHConfiguration,
        remoteHost: String,
        remotePort: Int
    ) async throws -> TableProDatabase.SSHTunnel {
        let connId = await tunnelStore.consumePending()

        // Resolve SSH credentials using macOS-compatible Keychain keys
        let sshPassword: String?
        let keyPassphrase: String?

        var resolvedConfig = config

        if let connId {
            sshPassword = try? secureStore.retrieve(
                forKey: "com.TablePro.sshpassword.\(connId.uuidString)")
            keyPassphrase = try? secureStore.retrieve(
                forKey: "com.TablePro.keypassphrase.\(connId.uuidString)")

            // Restore key content from Keychain if not in config
            if resolvedConfig.privateKeyData == nil || resolvedConfig.privateKeyData?.isEmpty == true {
                resolvedConfig.privateKeyData = try? secureStore.retrieve(
                    forKey: "com.TablePro.sshkeydata.\(connId.uuidString)")
            }
        } else {
            sshPassword = nil
            keyPassphrase = nil
        }

        let tunnel = try await SSHTunnelFactory.create(
            config: resolvedConfig,
            remoteHost: remoteHost,
            remotePort: remotePort,
            sshPassword: sshPassword,
            keyPassphrase: keyPassphrase
        )

        let effectiveId = connId ?? UUID()
        await tunnelStore.add(tunnel, connectionId: effectiveId)

        let port = await tunnel.port
        return TableProDatabase.SSHTunnel(localHost: "127.0.0.1", localPort: port)
    }

    func closeTunnel(for connectionId: UUID) async throws {
        guard let tunnel = await tunnelStore.remove(connectionId: connectionId) else { return }
        await tunnel.close()
    }
}

private actor TunnelStore {
    var tunnels: [UUID: SSHTunnel] = [:]
    private var pendingConnectionId: UUID?

    func setPending(_ id: UUID) {
        pendingConnectionId = id
    }

    func consumePending() -> UUID? {
        let id = pendingConnectionId
        pendingConnectionId = nil
        return id
    }

    func add(_ tunnel: SSHTunnel, connectionId: UUID) {
        tunnels[connectionId] = tunnel
    }

    func remove(connectionId: UUID) -> SSHTunnel? {
        tunnels.removeValue(forKey: connectionId)
    }
}
