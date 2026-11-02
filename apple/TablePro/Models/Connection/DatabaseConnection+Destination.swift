//
//  DatabaseConnection+Destination.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

extension DatabaseConnection {
    // Device-local transports and the tunnel command are left out: a Replace restores them and sync never carries them.
    var destination: ConnectionDestination {
        ConnectionDestination(
            type: type.rawValue,
            host: host,
            port: port,
            transport: destinationTransport,
            tunnel: destinationTunnel,
            additionalFields: additionalFields
        )
    }

    // Fields some drivers dial in place of the host: libSQL and Turso, DynamoDB, Spanner, Firebase.
    private static let endpointFieldIds = ["databaseUrl", "awsEndpointUrl", "spEndpoint", "fbDatabaseURL"]

    // Host and port first, then every other server the connection may dial, so a prompt never hides the
    // real host behind a value the engine ignores, or a server behind "(+N more)".
    var destinationSummary: String {
        var servers = [host.isEmpty || host.hasPrefix("/") ? endpointDescription : HostListEndpoint(host: host, port: port).entry]
        let account = (additionalFields["snowflakeAccount"] ?? "").trimmingCharacters(in: .whitespaces)
        if type.pluginTypeId == "Snowflake", !account.isEmpty {
            servers.append(account)
        }
        servers += activeHostListFieldIds.flatMap { fieldId in
            (additionalFields[fieldId] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        servers += Self.endpointFieldIds
            .map { (additionalFields[$0] ?? "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        let server = servers.filter { seen.insert($0).inserted }.joined(separator: ", ")
        let ssh = resolvedSSHConfig
        guard ssh.enabled, !ssh.host.isEmpty else { return server }
        return String(
            format: String(localized: "%1$@ through the SSH server %2$@"),
            server,
            "\(ssh.host):\(ssh.port ?? 22)"
        )
    }

    private var destinationTransport: ConnectionDestination.Transport {
        switch sslConfig.mode {
        case .disabled, .preferred, .required: return .unverified
        case .verifyCa: return .verifyCA
        case .verifyIdentity: return .verifyIdentity
        }
    }

    private var destinationTunnel: ConnectionDestination.Tunnel {
        switch sshTunnelMode {
        case .disabled:
            return .none
        case .profile(let profileId, _):
            return .profile(profileId)
        case .inline(let config):
            guard config.enabled else { return .none }
            return .ssh(
                server: ConnectionDestination.Endpoint(host: config.host, port: config.port),
                jumps: config.jumpHosts.map { ConnectionDestination.Endpoint(host: $0.host, port: $0.port) }
            )
        }
    }
}
