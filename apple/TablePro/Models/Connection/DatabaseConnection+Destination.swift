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

    // Host and port first, then every other server or project the connection may sign in to, so a prompt never
    // hides the real host behind a value the engine ignores, or a server behind "(+N more)".
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
        servers += activeDestinationFieldIds
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

    // The catalog's destinations this engine reads with these settings, in form order. Host lists are named entry by
    // entry above. An engine with no declared fields names every destination it carries.
    private var activeDestinationFieldIds: [String] {
        let declared = PluginMetadataRegistry.shared.snapshot(for: type)?.connection.additionalConnectionFields ?? []
        guard !declared.isEmpty else {
            return additionalFields.keys
                .filter { ConnectionFieldCatalog.trust(of: $0) == .destination }
                .sorted()
        }
        return declared.compactMap { field -> String? in
            if case .hostList = field.fieldType { return nil }
            guard ConnectionFieldCatalog.trust(of: field.id) == .destination,
                  declared.isVisible(field, forValues: additionalFields)
            else { return nil }
            return field.id
        }
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
