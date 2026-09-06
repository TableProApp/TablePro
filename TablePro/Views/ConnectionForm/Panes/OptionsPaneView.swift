//
//  OptionsPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

/// What TablePro is allowed to do with this connection, and what it runs when it opens it.
///
/// Driver options, startup SQL, Safe Mode, external and AI access and iCloud were split across
/// three sidebar panes called Customization, Advanced and AI Rules. They answer one question, so
/// they are one tab.
struct OptionsPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var databaseType: DatabaseType { coordinator.network.type }
    private var aiIsEnabled: Bool { AppSettingsManager.shared.ai.enabled }

    var body: some View {
        Form {
            driverSection
            startupSection
            preConnectSection
            safetySection
            if aiIsEnabled {
                aiRulesSection
            }
            if AppSettingsManager.shared.sync.enabled {
                syncSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Driver options

    @ViewBuilder
    private var driverSection: some View {
        let fields = coordinator.advanced.advancedFields
        if !fields.isEmpty {
            Section(databaseType.displayName) {
                ForEach(fields, id: \.id) { field in
                    if coordinator.advanced.isFieldVisible(field) {
                        ConnectionFieldRow(
                            field: field,
                            value: advancedFieldBinding(for: field)
                        )
                    }
                }
            }
        }
    }

    private func advancedFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: {
                coordinator.advanced.additionalFieldValues[field.id]
                    ?? field.defaultValue ?? ""
            },
            set: { coordinator.advanced.additionalFieldValues[field.id] = $0 }
        )
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            StartupCommandsEditor(text: $coordinator.advanced.startupCommands)
                .frame(height: 80)
        } header: {
            Text(String(localized: "Startup Commands"))
        } footer: {
            Text("SQL commands to run after connecting, e.g. SET time_zone = 'Asia/Ho_Chi_Minh'. One per line or separated by semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var preConnectSection: some View {
        Section {
            StartupCommandsEditor(text: $coordinator.advanced.preConnectScript)
                .frame(height: 80)
        } header: {
            Text(String(localized: "Pre-Connect Script"))
        } footer: {
            Text("Shell script to run before connecting. Non-zero exit aborts connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            Picker(String(localized: "Safe Mode"), selection: $coordinator.customization.safeModeLevel) {
                ForEach(SafeModeLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            if aiIsEnabled {
                Picker(String(localized: "AI Policy"), selection: $coordinator.advanced.aiPolicy) {
                    Text(String(localized: "Use Default"))
                        .tag(AIConnectionPolicy?.none as AIConnectionPolicy?)
                    ForEach(AIConnectionPolicy.allCases) { policy in
                        Text(policy.displayName)
                            .tag(AIConnectionPolicy?.some(policy) as AIConnectionPolicy?)
                    }
                }
            }
            Picker(String(localized: "External Clients"), selection: $coordinator.advanced.externalAccess) {
                ForEach(ExternalAccessLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(String(localized: "Access"))
        } footer: {
            accessFooter
        }
    }

    @ViewBuilder
    private var accessFooter: some View {
        Group {
            if aiIsEnabled {
                // swiftlint:disable:next line_length
                Text(String(localized: "AI Policy controls in-app AI agents. External Clients controls Raycast, Cursor, Claude Desktop, other MCP clients, and AppleScript. Effective scope is the minimum of the requesting token's scope and the External Clients level."))
            } else {
                // swiftlint:disable:next line_length
                Text(String(localized: "Controls how external clients (Raycast, Cursor, Claude Desktop, AppleScript) access this connection. Tokens cannot exceed this level even with full-access scope."))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - AI rules

    private var aiRulesSection: some View {
        Section {
            StartupCommandsEditor(text: $coordinator.aiRules.rules)
                .frame(height: 120)
        } header: {
            Text(String(localized: "AI Rules"))
        } footer: {
            Text("Guidance the AI sees on every chat turn for this connection: table conventions, columns to avoid, join hints, business rules the schema doesn't show.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Toggle(String(localized: "Local only"), isOn: $coordinator.advanced.localOnly)
        } header: {
            Text(String(localized: "iCloud Sync"))
        } footer: {
            Text("This connection won't sync to other devices via iCloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
