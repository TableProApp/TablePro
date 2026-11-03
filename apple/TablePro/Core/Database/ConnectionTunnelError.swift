import Foundation

enum ConnectionTunnelError: Error, LocalizedError, Equatable {
    case mutualExclusivityViolation([ConnectionTunnelKind])
    case remoteFileUnsupported(String)
    case remoteFilePathMissing
    case srvLookupBehindTunnel

    static func refusal(for connection: DatabaseConnection) -> ConnectionTunnelError? {
        guard connection.enabledTunnelKinds.contains(where: { $0 != .remoteFile && $0 != .remoteDatabaseSession })
        else { return nil }
        // An SRV name resolves to the cluster's own servers, which the driver dials around the one forwarded port.
        if connection.type.pluginTypeId == "MongoDB", connection.usesMongoSrv {
            return .srvLookupBehindTunnel
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .mutualExclusivityViolation(let kinds):
            let names = kinds.map(\.displayName).joined(separator: ", ")
            return String(
                format: String(localized: "A connection can use only one connection method at a time. Enabled: %@."),
                names
            )
        case .remoteFileUnsupported(let typeName):
            return String(
                format: String(localized: "%@ connections open a server, not a database file, so there is nothing to fetch over SSH."),
                typeName
            )
        case .remoteFilePathMissing:
            return String(localized: "No remote database file was named for this connection.")
        case .srvLookupBehindTunnel:
            return String(localized: """
                An SRV record names servers the tunnel cannot reach, so the connection would go around it. Turn the tunnel \
                off, or list the servers under Hosts and turn off Use SRV Record.
                """)
        }
    }
}

extension ConnectionTunnelError: ConnectionPreflightReporting {
    var failedBeforeDialing: Bool { true }
}
