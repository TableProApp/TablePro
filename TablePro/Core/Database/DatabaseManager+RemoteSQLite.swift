//
//  DatabaseManager+RemoteSQLite.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseManager {
    /// Rewrites a SQLite connection to reach its database through a live session on the SSH server.
    ///
    /// The symmetry with the tunnel arm is the point: that one swaps `host` and `port` for a
    /// forwarded port and hands the driver a connection with no idea a tunnel exists. This does the
    /// same, and adds two fields the SQLite plugin reads to pick the agent backend and to present
    /// the token the listener admits it with. The driver still just opens what it is told to open.
    internal func buildRemoteSQLiteEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil
    ) async throws -> DatabaseConnection {
        let sshConfig = connection.resolvedSSHConfig
        guard let field = pluginManager.localFilePathField(for: connection.type) else {
            throw ConnectionTunnelError.remoteFileUnsupported(connection.type.displayName)
        }
        guard !sshConfig.remoteFilePath.isEmpty else { throw ConnectionTunnelError.remoteFilePathMissing }

        let credentials = sshCredentials(for: connection, passwordOverride: sshPasswordOverride)
        let endpoint = try await RemoteSQLiteTransportManager.shared.createTunnel(
            connectionId: connection.id,
            config: sshConfig,
            credentials: credentials
        )

        return connection.openingRemoteSQLiteSession(
            host: "127.0.0.1",
            port: endpoint.port,
            token: endpoint.token,
            remotePath: sshConfig.remoteFilePath,
            field: field
        )
    }

    /// Handle a dead remote SQLite session by reconnecting with exponential backoff, the same path
    /// an SSH tunnel death takes.
    func handleRemoteSQLiteTunnelDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Remote SQLite",
            disconnectedMessage: String(localized: "Remote SQLite session disconnected. Click to reconnect.")
        )
    }
}

extension DatabaseConnection {
    /// Returns a copy whose driver opens the remote database over the loopback session: the file
    /// path the agent opens, the local endpoint the driver dials, the marker that selects the agent
    /// backend, and the token the listener admits it with. The SSH configuration is cleared so
    /// nothing tries to tunnel a second time.
    func openingRemoteSQLiteSession(
        host: String,
        port: Int,
        token: String,
        remotePath: String,
        field: LocalFilePathField
    ) -> DatabaseConnection {
        var copy = self
        copy.host = host
        copy.port = port
        switch field {
        case .database:
            copy.database = remotePath
        case .additionalField(let id):
            copy.additionalFields[id] = remotePath
        }
        copy.additionalFields[RemoteSQLiteWire.backendFieldKey] = RemoteSQLiteWire.agentBackendValue
        copy.additionalFields[RemoteSQLiteWire.tokenFieldKey] = token
        /// `resolvedSSHConfig` reads `sshTunnelMode`, so clearing `sshConfig` alone would leave the
        /// effective connection still resolving to a remote session. Disabling the mode is what stops
        /// anything from tunnelling the local endpoint a second time.
        copy.sshConfig = SSHConfiguration()
        copy.sshTunnelMode = .disabled
        return copy
    }
}
