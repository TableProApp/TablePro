//
//  WelcomeConnectionRow.swift
//  TablePro
//

import SwiftUI

struct WelcomeConnectionRow: View {
    let connection: DatabaseConnection
    let sshProfile: SSHProfile?
    var onConnect: (() -> Void)?

    private var displayTag: ConnectionTag? {
        guard let tagId = connection.tagId else { return nil }
        return TagStorage.shared.tag(for: tagId)
    }

    var body: some View {
        HStack(spacing: 12) {
            connection.type.iconImage
                .renderingMode(.template)
                .font(.system(size: 16))
                .foregroundStyle(connection.displayColor)
                .frame(
                    width: 16,
                    height: 16
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    if let tag = displayTag {
                        Text(tag.name)
                            .font(.system(size: 9))
                            .foregroundStyle(tag.color.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    tag.color.color.opacity(0.15)))
                    }

                    if connection.isSample {
                        Text(String(localized: "Sample"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .help(String(localized: "Bundled sample database"))
                    }

                    if connection.resolvedSSHConfig.enabled {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(sshTunnelTooltip)
                            .accessibilityLabel(String(localized: "SSH tunnel"))
                    }

                    if connection.localOnly && !connection.isSample {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help(String(localized: "Local only - not synced to iCloud"))
                    }
                }

                Text(connectionSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(connectionSubtitle)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(
            DoubleClickDetector { onConnect?() }
        )
    }

    private var connectionSubtitle: String {
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        if let mongoHosts = connection.additionalFields["mongoHosts"], mongoHosts.contains(",") {
            let count = mongoHosts.split(separator: ",").count
            return String(
                format: String(localized: "%@ (+%d more)"),
                hostWithOptionalPort, count - 1
            )
        }
        return hostWithOptionalPort
    }

    private var hostWithOptionalPort: String {
        if connection.port == connection.type.defaultPort {
            return connection.host
        }
        return "\(connection.host):\(connection.port)"
    }

    private var sshTunnelTooltip: String {
        let ssh = connection.resolvedSSHConfig
        let userPrefix = ssh.username.isEmpty ? "" : "\(ssh.username)@"
        let portSuffix: String
        if let port = ssh.port, port != 22 {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        let target = "\(userPrefix)\(ssh.host)\(portSuffix)"
        return String(format: String(localized: "Connects via SSH tunnel: %@"), target)
    }
}
