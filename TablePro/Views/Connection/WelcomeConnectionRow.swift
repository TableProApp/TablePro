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

    private var showsLocalOnly: Bool {
        connection.localOnly && !connection.isSample
    }

    var body: some View {
        HStack {
            connection.type.iconImage
                .renderingMode(.template)
                .font(.title3)
                .foregroundStyle(connection.displayColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitleText)
            }

            Spacer(minLength: 8)

            trailingAccessories
        }
        .contentShape(Rectangle())
        .overlay(DoubleClickDetector { onConnect?() })
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: 8) {
            if showsLocalOnly {
                Image(systemName: "icloud.slash")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "Local only, not synced to iCloud"))
                    .accessibilityLabel(String(localized: "Local only"))
            }

            if let tag = displayTag {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tag.color.color)
                        .frame(width: 8, height: 8)
                    Text(tag.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: String(localized: "Tag: %@"), tag.name))
            }
        }
    }

    private var subtitleText: String {
        var components: [String] = [primaryEndpoint]
        if let viaText = sshViaText {
            components.append(viaText)
        }
        if connection.isSample {
            components.append(String(localized: "Sample"))
        }
        return components.joined(separator: " · ")
    }

    private var primaryEndpoint: String {
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        if let mongoHosts = connection.additionalFields["mongoHosts"], mongoHosts.contains(",") {
            let count = mongoHosts.split(separator: ",").count
            return String(format: String(localized: "%@ (+%d more)"), hostWithOptionalPort, count - 1)
        }
        return hostWithOptionalPort
    }

    private var hostWithOptionalPort: String {
        if connection.port == connection.type.defaultPort {
            return connection.host
        }
        return "\(connection.host):\(connection.port)"
    }

    /// Apple's semantic convention for routed/relayed connections is the
    /// "via X" suffix (AirDrop, Mail forwarded threads, Network preferences).
    /// Returns nil when SSH is not enabled or the bastion host is empty.
    private var sshViaText: String? {
        let ssh = connection.resolvedSSHConfig
        guard ssh.enabled, !ssh.host.isEmpty else { return nil }
        return String(format: String(localized: "via %@"), ssh.host)
    }
}
