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
    let connectionState: ToolbarConnectionState
    let displayColor: Color
    let tagName: String?
    var safeModeLevel: SafeModeLevel = .silent
    var onSwitchDatabase: (() -> Void)?

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
            Circle()
                .fill(displayColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )

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

    /// Database name (clickable to open database switcher, plain label for SQLite)
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

#Preview("Connected") {
    ConnectionStatusView(
        databaseType: .mariadb,
        databaseVersion: "11.1.2",
        databaseName: "production_db",
        connectionName: "Production Database",
        connectionState: .connected,
        displayColor: .cyan,
        tagName: "production"
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Executing - No Duplicate") {
    ConnectionStatusView(
        databaseType: .mysql,
        databaseVersion: "8.0.35",
        databaseName: "dev_db",
        connectionName: "Development",
        connectionState: .executing,
        displayColor: .orange,
        tagName: "local"
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("No Tag") {
    ConnectionStatusView(
        databaseType: .postgresql,
        databaseVersion: "16.1",
        databaseName: "analytics",
        connectionName: "Analytics DB",
        connectionState: .connected,
        displayColor: .blue,
        tagName: nil
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("Duplicate Name") {
    ConnectionStatusView(
        databaseType: .mysql,
        databaseVersion: "9.5.0",
        databaseName: "laravel",
        connectionName: "Local",
        connectionState: .connected,
        displayColor: .green,
        tagName: "local"
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
