//
//  ConnectionStatusView.swift
//  TablePro
//
//  Central toolbar component displaying database type, version,
//  connection name, and connection state indicator.
//

import SwiftUI
import TableProPluginKit

/// Main connection status display for the toolbar center
struct ConnectionStatusView: View {
    let databaseType: DatabaseType
    let databaseVersion: String?
    let chipText: String
    let databaseGroupingStrategy: GroupingStrategy
    let connectionName: String
    let displayColor: Color
    var safeModeLevel: SafeModeLevel = .silent
    var onSwitchDatabase: (() -> Void)?

    @ScaledMetric private var engineIconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            connectionIdentitySection

            if !chipText.isEmpty {
                Divider()
                    .frame(height: 12)

                chipSection
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
    private var chipSection: some View {
        if !PluginManager.shared.supportsDatabaseSwitching(for: databaseType) {
            chipLabel
                .help(staticChipTooltip)
        } else {
            Button {
                onSwitchDatabase?()
            } label: {
                chipLabel
            }
            .buttonStyle(.plain)
            .help(switchableChipTooltip)
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder")
                .imageScale(.small)
                .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)

            Text(chipText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var chipKindLabel: String {
        switch databaseGroupingStrategy {
        case .bySchema: return String(localized: "Schema")
        case .byDatabase, .flat: return String(localized: "Database")
        }
    }

    private var staticChipTooltip: String {
        String(format: String(localized: "%@: %@"), chipKindLabel, chipText)
    }

    private var switchableChipTooltip: String {
        let switchVerb: String = switch databaseGroupingStrategy {
        case .bySchema: String(localized: "switch schema")
        case .byDatabase, .flat: String(localized: "switch database")
        }
        if safeModeLevel == .readOnly {
            return String(
                format: String(localized: "Current %@: %@ (read only, ⌘K to %@)"),
                chipKindLabel.lowercased(), chipText, switchVerb
            )
        }
        return String(
            format: String(localized: "Current %@: %@ (⌘K to %@)"),
            chipKindLabel.lowercased(), chipText, switchVerb
        )
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
        chipText: "production_db",
        databaseGroupingStrategy: .byDatabase,
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
        chipText: "dev_db",
        databaseGroupingStrategy: .byDatabase,
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
        chipText: "public",
        databaseGroupingStrategy: .bySchema,
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
        chipText: "",
        databaseGroupingStrategy: .byDatabase,
        connectionName: "Local",
        displayColor: .green
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
