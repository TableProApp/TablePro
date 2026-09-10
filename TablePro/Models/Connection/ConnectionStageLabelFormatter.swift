//
//  ConnectionStageLabelFormatter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Two forms of the same stage, and only one of them is drawn.
///
/// `description` is the line beside the progress bar. It exists for the steps where the app is
/// blocked on something that is not the database: a hop the reader cannot see, a script they
/// wrote, or the reader themselves. Every other step restates the card it sits under, which
/// already carries the connection's name and its endpoint, so it draws nothing at all. The HIG
/// makes the description conditional in the same words: "If it's helpful, display a description
/// that provides additional context for the task. Be accurate and succinct. Avoid vague terms
/// like loading or authenticating because they seldom add value."
///
/// Two of those steps were also never comparable between engines. `negotiatingEncryption` is
/// reported by 2 of the 38 drivers and `authenticating` by 3, so the same connect narrated a
/// different story depending on which plugin answered, for a difference the reader has no way to
/// act on.
///
/// `announcement` is the spoken form and covers every step, because a progress bar tells VoiceOver
/// nothing and the step is then the only progress there is. Quiet on screen is not quiet in the
/// accessibility tree.
internal enum ConnectionStageLabelFormatter {
    /// What the connecting card draws, or nil where the bar alone says as much.
    internal static func description(for stage: ConnectionStage, connection: DatabaseConnection) -> String? {
        switch stage {
        case .resolvingTunnel:
            guard let via = tunnelDescription(for: connection) else {
                return String(localized: "Waiting for the tunnel")
            }
            return String(format: String(localized: "Waiting for %@"), via)
        case .runningPreConnectScript:
            return String(localized: "Waiting for your pre-connect script")
        case .awaitingCredentials:
            return String(localized: "Waiting for your password")
        case .custom(let text):
            /// A plugin that went to the trouble of naming its own step has said something the
            /// shared vocabulary does not cover, so it is drawn as written.
            return text
        case .openingConnection, .negotiatingEncryption, .authenticating, .preparingSession:
            return nil
        @unknown default:
            return nil
        }
    }

    internal static func announcement(for stage: ConnectionStage, connection: DatabaseConnection) -> String {
        String(
            format: String(localized: "%1$@ on %2$@"),
            spokenLabel(for: stage, connection: connection),
            connection.name
        )
    }

    /// Spoken rather than drawn, so it answers for the steps the card stays quiet about. The
    /// vocabulary is deliberately the plain one: to a reader who cannot see the bar, "Opening the
    /// connection" is the progress, not a restatement of it.
    private static func spokenLabel(for stage: ConnectionStage, connection: DatabaseConnection) -> String {
        if let description = description(for: stage, connection: connection) {
            return description
        }
        switch stage {
        case .negotiatingEncryption:
            return String(localized: "Negotiating encryption")
        case .authenticating:
            let username = trimmedUsername(of: connection)
            guard !username.isEmpty else { return String(localized: "Checking your credentials") }
            return String(format: String(localized: "Authenticating %@"), username)
        case .preparingSession:
            return String(localized: "Preparing the session")
        case .openingConnection, .resolvingTunnel, .runningPreConnectScript, .awaitingCredentials, .custom:
            return String(localized: "Opening the connection")
        @unknown default:
            return String(localized: "Opening the connection")
        }
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
        case .tunnelCommand:
            return String(localized: "the tunnel command")
        case .remoteFile:
            let host = connection.resolvedSSHConfig.host.trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? nil : host
        case .none:
            return nil
        }
    }
}
