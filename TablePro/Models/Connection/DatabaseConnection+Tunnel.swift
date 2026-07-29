//
//  DatabaseConnection+Tunnel.swift
//  TablePro
//

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
}
