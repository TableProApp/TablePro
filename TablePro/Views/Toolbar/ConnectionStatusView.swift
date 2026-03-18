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
    let tagName: String?  // Tag name to avoid duplication
    var safeModeLevel: SafeModeLevel = .silent

    var body: some View {
        HStack(spacing: 10) {
            // Database type icon + version
            databaseInfoSection

            // Vertical separator
            Divider()
                .frame(height: ThemeEngine.shared.activeTheme.spacing.sm)

            // Database name (clickable to switch databases)
            if !databaseName.isEmpty {
                databaseNameSection
            }
        }
    }

    // MARK: - Subviews

    /// Database type and version info
    private var databaseInfoSection: some View {
        Text(formattedDatabaseInfo)
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .regular, design: .monospaced))
            .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)
            .accessibilityLabel(
                String(localized: "Database type: \(formattedDatabaseInfo)")
            )
            .help("Database: \(formattedDatabaseInfo)")
    }

    /// Database name (clickable to open database switcher, plain label for SQLite)
    @ViewBuilder
    private var databaseNameSection: some View {
        if !PluginManager.shared.supportsDatabaseSwitching(for: databaseType) {
            databaseNameLabel
                .help("Database: \(databaseName)")
        } else {
            Button {
                NotificationCenter.default.post(name: .openDatabaseSwitcher, object: nil)
            } label: {
                databaseNameLabel
            }
            .buttonStyle(.plain)
            .help(safeModeLevel == .readOnly
                ? String(localized: "Current database: \(databaseName) (read-only, ⌘K to switch)")
                : String(localized: "Current database: \(databaseName) (⌘K to switch)"))
        }
    }

    private var databaseNameLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder")
                .font(.system(size: 13))
                .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: safeModeLevel.iconName)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(safeModeLevel.badgeColor)
                        .offset(x: 3, y: 2)
                        .help(safeModeLevel.displayName)
                }

            Text(databaseName)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Computed Properties

    private var formattedDatabaseInfo: String {
        if let version = databaseVersion, !version.isEmpty {
            return "\(databaseType.rawValue) \(version)"
        }
        return databaseType.rawValue
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
