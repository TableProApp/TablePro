//
//  DatabaseConnection+Display.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseConnection {
    var connectionSubtitle: String {
        var components: [String] = [endpointDescription]
        if let database = databaseDescriptor {
            components.append(database)
        }
        if let via = sshViaDescriptor {
            components.append(via)
        }
        return components.joined(separator: " · ")
    }

    var endpointDescription: String {
        if let remote = remoteFileOrigin {
            return remote
        }
        if let socketPath = sshForwardUnixSocketPath, resolvedSSHConfig.enabled {
            return (socketPath as NSString).abbreviatingWithTildeInPath
        }
        if let hostList = hostListDescription {
            return hostList
        }
        if host.isEmpty {
            let trimmed = database.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? type.rawValue : (trimmed as NSString).abbreviatingWithTildeInPath
        }
        if host.hasPrefix("/") {
            return (host as NSString).abbreviatingWithTildeInPath
        }
        return hostWithOptionalPort
    }

    /// A connection that names its servers in a host list has no single Host to show, and the
    /// field it uses depends on its own settings: Redis has one list for Sentinel and another for
    /// Cluster. Without this a Sentinel connection reads as just "Redis" in the connection list.
    private var hostListDescription: String? {
        for fieldId in activeHostListFieldIds {
            guard let raw = additionalFields[fieldId]?.nilIfEmpty else { continue }
            let entries = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = entries.first else { continue }
            guard entries.count > 1 else { return first }
            return String(format: String(localized: "%@ (+%d more)"), first, entries.count - 1)
        }
        return nil
    }

    private var databaseDescriptor: String? {
        guard !host.isEmpty || hostListDescription != nil else { return nil }
        switch type.pathFieldRole {
        case .database, .serviceName:
            let trimmed = database.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case .databaseIndex:
            guard let index = redisDatabase else { return nil }
            return String(format: String(localized: "db %d"), index)
        case .filePath:
            return nil
        @unknown default:
            return nil
        }
    }

    private var hostWithOptionalPort: String {
        port == type.defaultPort ? host : "\(host):\(port)"
    }

    private var sshViaDescriptor: String? {
        let ssh = resolvedSSHConfig
        guard ssh.enabled, !ssh.host.isEmpty else { return nil }
        guard !ssh.forwardsRemoteFile else { return nil }
        return String(format: String(localized: "via %@"), ssh.host)
    }

    /// `user@host:/path` for a connection whose database file lives on an SSH server.
    ///
    /// It replaces the endpoint rather than sitting beside it, because the alternative is a row
    /// that reads exactly like a local file. Someone who cannot tell the two apart at a glance can
    /// edit production believing they are editing a copy on their own disk.
    var remoteFileOrigin: String? {
        let ssh = resolvedSSHConfig
        guard ssh.forwardsRemoteFile else { return nil }
        let account = ssh.username.isEmpty ? ssh.host : "\(ssh.username)@\(ssh.host)"
        return "\(account):\(ssh.remoteFilePath)"
    }
}
