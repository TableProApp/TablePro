//
//  ConnectionStatusView.swift
//  TablePro
//
//  Central toolbar component displaying database type, version,
//  connection name, and connection state indicator.
//

import SwiftUI

/// Main connection status display for the toolbar center
struct ConnectionStatusView: View {
    let databaseType: DatabaseType
    let databaseVersion: String?
    let databaseName: String
    let connectionName: String
    let displayColor: Color
    var safeModeLevel: SafeModeLevel = .silent
    var onSwitchDatabase: (() -> Void)?

    @ScaledMetric private var engineIconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            connectionIdentitySection

            if !databaseName.isEmpty {
                Divider()
                    .frame(height: 12)

                databaseNameSection
            }
        }
    }

    // MARK: - Subviews

    private var connectionIdentitySection: some View {
        HStack(spacing: 6) {
            databaseType.iconImage
                .renderingMode(.template)
                .foregroundStyle(displayColor)
                .frame(width: engineIconSize, height: engineIconSize)

            Text(connectionName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help(connectionTooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connectionAccessibilityLabel)
    }

    @ViewBuilder
    private var databaseNameSection: some View {
        if !PluginManager.shared.supportsDatabaseSwitching(for: databaseType) {
            databaseNameLabel
                .help("Database: \(databaseName)")
        } else {
            Button {
                onSwitchDatabase?()
            } label: {
                databaseNameLabel
            }
            .buttonStyle(.plain)
            .help(safeModeLevel == .readOnly
                ? String(format: String(localized: "Current database: %@ (read only, ⌘K to switch)"), databaseName)
                : String(format: String(localized: "Current database: %@ (⌘K to switch)"), databaseName))
        }
    }

    private var databaseNameLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder")
                .imageScale(.small)
                .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)

            Text(databaseName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Computed Properties

    private var formattedDatabaseInfo: String {
        if let version = databaseVersion, !version.isEmpty {
            return "\(databaseType.rawValue) \(version)"
        }
        return databaseType.rawValue
    }

    private var connectionTooltip: String {
        String(format: String(localized: "%@ • %@"), connectionName, formattedDatabaseInfo)
    }

    private var connectionAccessibilityLabel: String {
        String(format: String(localized: "Connection: %@, %@"), connectionName, formattedDatabaseInfo)
    }
}

// MARK: - Preview

#Preview("MariaDB") {
    ConnectionStatusView(
        databaseType: .mariadb,
        databaseVersion: "11.1.2",
        databaseName: "production_db",
        connectionName: "Production Database",
        displayColor: .cyan
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("MySQL") {
    ConnectionStatusView(
        databaseType: .mysql,
        databaseVersion: "8.0.35",
        databaseName: "dev_db",
        connectionName: "Development",
        displayColor: .orange
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("PostgreSQL Dark") {
    ConnectionStatusView(
        databaseType: .postgresql,
        databaseVersion: "16.1",
        databaseName: "analytics",
        connectionName: "Analytics DB",
        displayColor: .blue
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("Empty Database") {
    ConnectionStatusView(
        databaseType: .mysql,
        databaseVersion: "9.5.0",
        databaseName: "",
        connectionName: "Local",
        displayColor: .green
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
