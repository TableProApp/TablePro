//
//  DatabaseManager+RemoteSQLite.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSSHConfig

extension DatabaseManager {
    internal func buildRemoteSQLiteEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil,
        deadline: ConnectionDeadline
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
            credentials: credentials,
            deadline: deadline
        )

        return connection.openingRemoteSQLiteSession(
            host: "127.0.0.1",
            port: endpoint.port,
            token: endpoint.token,
            remotePath: sshConfig.remoteFilePath,
            field: field
        )
    }

    func handleRemoteSQLiteTunnelDied(connectionId: UUID) async {
        recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Remote SQLite",
            disconnectedMessage: String(localized: "Remote SQLite session disconnected.")
        )
    }
}

extension DatabaseConnection {
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
        // `resolvedSSHConfig` reads `sshTunnelMode`, so clearing `sshConfig` alone would tunnel the endpoint again.
        copy.sshConfig = SSHConfiguration()
        copy.sshTunnelMode = .disabled
        return copy
    }
}
