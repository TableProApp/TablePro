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

    // Read through the linked SSH profile as it stands now, which is where the next connect dials.
    @MainActor var dialedDestination: ConnectionDestination {
        SSHProfileStorage.shared.refreshingLinkedProfile(self).destination
    }

    // The SSH server and jump hosts this copy names, in order. A profile counts by its servers, never its id.
    var destinationTunnel: ConnectionDestination.Tunnel {
        let config = resolvedSSHConfig
        guard config.enabled else { return .none }
        return .ssh(
            server: ConnectionDestination.Endpoint(host: config.host, port: config.port),
            jumps: config.jumpHosts.map { ConnectionDestination.Endpoint(host: $0.host, port: $0.port) }
        )
    }

    // Host and port first, then every other server or project the connection may sign in to, so a prompt never
    // hides the real host behind a value the engine ignores, or a server behind "(+N more)". Where plugin fields name
    // the server, as DuckDB's Remote fields do, they stand in for Host, which nothing dials.
    var destinationSummary: String {
        var servers: [String]
        if activeServerEndpointFields != nil {
            let server = serverEndpoint
            servers = [HostListEndpoint(host: server.host, port: server.port).entry]
        } else {
            servers = [host.isEmpty || host.hasPrefix("/") ? endpointDescription : HostListEndpoint(host: host, port: port).entry]
        }
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
        guard ssh.enabled, !ssh.host.isEmpty, opensSSHServer else { return server }
        return String(
            format: String(localized: "%1$@ through the SSH server %2$@"),
            server,
            "\(ssh.host):\(ssh.port ?? 22)"
        )
    }

    // The catalog's destinations this engine reads with these settings, in form order. Host lists and server fields are
    // named above. An engine with no declared fields names every destination it carries.
    private var activeDestinationFieldIds: [String] {
        let declared = PluginMetadataRegistry.shared.snapshot(for: type)?.connection.additionalConnectionFields ?? []
        guard !declared.isEmpty else {
            return additionalFields.keys
                .filter { ConnectionFieldCatalog.trust(of: $0) == .destination }
                .sorted()
        }
        let serverFieldIds = activeServerEndpointFields.map { [$0.hostFieldId, $0.portFieldId] } ?? []
        return declared.compactMap { field -> String? in
            if case .hostList = field.fieldType { return nil }
            guard !serverFieldIds.contains(field.id),
                  ConnectionFieldCatalog.trust(of: field.id) == .destination,
                  declared.isVisible(field, forValues: additionalFields)
            else { return nil }
            return field.id
        }
    }

    // A stored SSH server the connect goes around, because the driver dials no forwarded port, is not part of the route.
    private var opensSSHServer: Bool {
        enabledTunnelKinds.contains { $0 == .ssh || $0 == .remoteFile || $0 == .remoteDatabaseSession }
    }

    private var destinationTransport: ConnectionDestination.Transport {
        switch sslConfig.mode {
        case .disabled, .preferred, .required: return .unverified
        case .verifyCa: return .verifyCA
        case .verifyIdentity: return .verifyIdentity
        }
    }
}
