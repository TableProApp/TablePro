//
//  DatabaseConnection+Tunnel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseConnection {
    static let preTunnelHostKey = "preTunnelHost"
    static let preTunnelPortKey = "preTunnelPort"

    /// The endpoint this connection addressed before a tunnel rewrote it to the local
    /// forward. Absent when the driver dials the server directly. Anything that must
    /// name the real server rather than the socket the driver opens reads these:
    /// pgpass lookups and RDS IAM token signing.
    var preTunnelHost: String? {
        additionalFields[Self.preTunnelHostKey]?.nilIfEmpty
    }

    var preTunnelPort: Int? {
        additionalFields[Self.preTunnelPortKey].flatMap(Int.init)
    }

    /// The host-list fields this connection's driver declares, if any.
    var hostListFieldIds: [String] {
        declaredConnectionFields
            .filter { field in
                if case .hostList = field.fieldType { return true }
                return false
            }
            .map(\.id)
    }

    /// The host list the connection's current settings actually use.
    ///
    /// Redis declares one for Sentinel and one for Cluster, and a field the form has hidden keeps
    /// its old value, so picking the first declared list would forward a Cluster connection to the
    /// Sentinel address the user typed before switching modes.
    var activeHostListFieldIds: [String] {
        let fields = declaredConnectionFields
        let visible = fields
            .filter { field in
                guard case .hostList = field.fieldType else { return false }
                return fields.isVisible(field, forValues: additionalFields)
            }
            .map(\.id)
        return visible.isEmpty ? hostListFieldIds : visible
    }

    private var declaredConnectionFields: [ConnectionField] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: type.pluginTypeId)?
            .connection.additionalConnectionFields ?? []
    }

    /// Where a tunnel should forward to.
    ///
    /// A tunnel carries one local port to one remote address, so a connection that names its
    /// servers in a host list rather than in Host and Port has to nominate one of them. The first
    /// entry is the one used, which is also what makes a host-list connection reachable over SSH
    /// at all: Host is blank whenever the form is showing a host list.
    var tunnelForwardEndpoint: (host: String, port: Int) {
        for fieldId in activeHostListFieldIds {
            guard let raw = additionalFields[fieldId]?.nilIfEmpty else { continue }
            guard let first = raw.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
                  !first.isEmpty else { continue }
            let bracketed = first.hasPrefix("[")
            if bracketed, let closing = first.firstIndex(of: "]") {
                let host = String(first[first.index(after: first.startIndex) ..< closing])
                let rest = first[first.index(after: closing)...]
                let parsedPort = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
                return (host, parsedPort ?? port)
            }
            if let lastColon = first.lastIndex(of: ":"), !first[..<lastColon].contains(":"),
               let parsedPort = Int(first[first.index(after: lastColon)...]) {
                return (String(first[..<lastColon]), parsedPort)
            }
            return (first, port)
        }
        return (host, port)
    }
}
