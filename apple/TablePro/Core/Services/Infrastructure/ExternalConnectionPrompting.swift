//
//  ExternalConnectionPrompting.swift
//  TablePro
//

import AppKit
import Foundation
import TableProSSHConfig

internal enum ExternalConnectionDecision: Sendable {
    case connect
    case alwaysAllow
    case cancel
}

@MainActor
internal protocol ExternalConnectionPrompting {
    func prompt(
        for connection: DatabaseConnection,
        filter: ConnectionURLFilter?,
        offerAlwaysAllow: Bool
    ) async -> ExternalConnectionDecision
}

@MainActor
internal struct ExternalConnectionAlertPrompt: ExternalConnectionPrompting {
    internal func prompt(
        for connection: DatabaseConnection,
        filter: ConnectionURLFilter?,
        offerAlwaysAllow: Bool
    ) async -> ExternalConnectionDecision {
        let alert = Self.makeAlert(for: connection, filter: filter, offerAlwaysAllow: offerAlwaysAllow)
        let response = await present(alert)
        switch response {
        case .alertFirstButtonReturn:
            return .connect
        case .alertThirdButtonReturn where offerAlwaysAllow:
            return .alwaysAllow
        default:
            return .cancel
        }
    }

    internal static func makeAlert(
        for connection: DatabaseConnection,
        filter: ConnectionURLFilter? = nil,
        offerAlwaysAllow: Bool
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open External Database Connection?")
        let details = details(for: connection).joined(separator: "\n")
        if let filter {
            alert.informativeText = String(
                format: String(localized: """
                    An external link wants to connect to a %@ database and filter a table:

                    %@

                    Connect only if you trust the source of this link and the filter below.
                    """),
                connection.type.rawValue,
                details
            )
            /// `informativeText` neither scrolls nor reveals invisible characters. An overlay scroller
            /// stays hidden until scrolled, so line breaks could push SQL out of the box unnoticed.
            let box = AlertHelper.scrollingTextAccessory(RevealedText(filter.displayText).plainText)
            box.scrollerStyle = .legacy
            box.autohidesScrollers = true
            alert.accessoryView = box
        } else {
            alert.informativeText = String(
                format: String(localized: """
                    An external link wants to connect to a %@ database:

                    %@

                    Connect only if you trust the source of this link.
                    """),
                connection.type.rawValue,
                details
            )
        }
        alert.alertStyle = .warning
        /// Connecting is the risky half of this decision, so it gives up Return. Escape stays on
        /// Cancel, which is the only binding that dismisses the alert from the keyboard.
        alert.addButton(withTitle: String(localized: "Connect")).keyEquivalent = ""
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        if offerAlwaysAllow {
            alert.addButton(withTitle: String(localized: "Always Allow"))
        }
        return alert
    }

    private static func details(for connection: DatabaseConnection) -> [String] {
        let server = connection.serverEndpoint
        var details: [String] = [
            connection.localSocketFile.map { String(format: String(localized: "Socket: %@"), $0) }
                ?? String(format: String(localized: "Host: %@"), "\(server.host):\(server.port)")
        ]
        if !connection.username.isEmpty {
            details.append(String(format: String(localized: "User: %@"), connection.username))
        }
        if !connection.database.isEmpty {
            details.append(String(format: String(localized: "Database: %@"), connection.database))
        }
        details.append(contentsOf: sshDetails(for: connection))
        details.append(contentsOf: transportDetails(for: connection))
        return details
    }

    // Behind a tunnel the database host is its far end, usually localhost, so the alert names every server the
    // session crosses. A linked profile is read as it stands now, which is where the connect goes.
    private static func sshDetails(for connection: DatabaseConnection) -> [String] {
        let linked = SSHProfileStorage.shared.refreshingLinkedProfile(connection).resolvedSSHConfig
        let ssh = linked.enabled ? linked : connection.sshConfig
        guard ssh.enabled, !ssh.host.isEmpty else { return [] }

        let port = ssh.port ?? 22
        let target = ssh.username.isEmpty ? "\(ssh.host):\(port)" : "\(ssh.username)@\(ssh.host):\(port)"
        var details = [String(format: String(localized: "SSH Tunnel: %@"), target)]

        let hops = ssh.jumpHosts.filter { !$0.host.isEmpty }
        guard !hops.isEmpty else { return details }

        let described = hops.map { hop -> String in
            let hopPort = hop.port ?? 22
            return hop.username.isEmpty ? "\(hop.host):\(hopPort)" : "\(hop.username)@\(hop.host):\(hopPort)"
        }
        details.append(String(format: String(localized: "Jump Hosts: %@"), described.joined(separator: ", ")))
        return details
    }

    private static func transportDetails(for connection: DatabaseConnection) -> [String] {
        connection.enabledTunnelKinds.compactMap { kind -> String? in
            let target: String
            switch kind {
            case .ssh, .remoteFile, .remoteDatabaseSession:
                return nil
            case .socksProxy:
                guard let proxy = connection.resolvedSOCKSProxyConfig else { return nil }
                target = "\(proxy.host):\(proxy.port)"
            case .tunnelCommand:
                guard let command = connection.resolvedTunnelCommandConfig else { return nil }
                target = command.method.displayName
            case .cloudflare:
                guard let tunnel = connection.resolvedCloudflareConfig else { return nil }
                target = tunnel.accessHostname
            case .cloudSQLProxy:
                guard let proxy = connection.resolvedCloudSQLProxyConfig else { return nil }
                target = proxy.instanceConnectionName
            }
            return String(format: String(localized: "%1$@: %2$@"), kind.displayName, target)
        }
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = AlertHelper.resolveWindow(NSApp.keyWindow) else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
