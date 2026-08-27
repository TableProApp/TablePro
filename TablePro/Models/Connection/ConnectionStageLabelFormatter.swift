//
//  ConnectionStageLabelFormatter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Two forms of the same stage. `stepLabel` sits under a heading that already names the
/// connection and its endpoint, so it only has to say which step is running. `announcement`
/// is spoken with no surrounding context, so it names the connection itself.
///
/// Neither form is ever a bare "Loading" or "Authenticating": the HIG calls those out by name
/// as descriptions that add nothing, and a step that does not say what it is acting on is
/// exactly that.
internal enum ConnectionStageLabelFormatter {
    internal static func stepLabel(for stage: ConnectionStage, connection: DatabaseConnection) -> String {
        switch stage {
        case .resolvingTunnel:
            guard let via = tunnelDescription(for: connection) else {
                return String(localized: "Opening the tunnel")
            }
            return String(format: String(localized: "Opening the tunnel through %@"), via)
        case .runningPreConnectScript:
            return String(localized: "Running the pre-connect script")
        case .awaitingCredentials:
            return String(localized: "Waiting for your password")
        case .openingConnection:
            return String(localized: "Opening the connection")
        case .negotiatingEncryption:
            return String(localized: "Negotiating encryption")
        case .authenticating:
            let username = trimmedUsername(of: connection)
            guard !username.isEmpty else { return String(localized: "Checking your credentials") }
            return String(format: String(localized: "Authenticating %@"), username)
        case .preparingSession:
            return String(localized: "Preparing the session")
        case .custom(let text):
            return text
        @unknown default:
            return String(localized: "Opening the connection")
        }
    }

    internal static func announcement(for stage: ConnectionStage, connection: DatabaseConnection) -> String {
        String(
            format: String(localized: "%1$@ on %2$@"),
            stepLabel(for: stage, connection: connection),
            connection.name
        )
    }

    private static func trimmedUsername(of connection: DatabaseConnection) -> String {
        connection.username.trimmingCharacters(in: .whitespaces)
    }

    private static func tunnelDescription(for connection: DatabaseConnection) -> String? {
        switch connection.activeTunnelKind {
        case .ssh:
            let host = connection.resolvedSSHConfig.host.trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? nil : host
        case .cloudflare:
            return "Cloudflare"
        case .cloudSQLProxy:
            return "Cloud SQL Auth Proxy"
        case .socksProxy:
            return String(localized: "the SOCKS proxy")
        case .remoteFile:
            let host = connection.resolvedSSHConfig.host.trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? nil : host
        case .none:
            return nil
        }
    }
}
