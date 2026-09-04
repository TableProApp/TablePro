//
//  ConnectionAdvancedView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ConnectionAdvancedView: View {
    @Binding var additionalFieldValues: [String: String]
    @Binding var startupCommands: String
    @Binding var preConnectScript: String
    @Binding var aiPolicy: AIConnectionPolicy?
    @Binding var externalAccess: ExternalAccessLevel
    @Binding var localOnly: Bool

    /// Nil for a connection the form has not saved yet. The outside-MCP allowlist is keyed by
    /// connection id, so it appears once there is one.
    let connectionId: UUID?

    let databaseType: DatabaseType
    let additionalConnectionFields: [ConnectionField]
    /// Values from every pane, not just this one, so a rule can point at a field in another
    /// section. The Redis Database Index field is hidden by the Connection Mode field, which the
    /// Connection pane owns.
    let visibilityValues: [String: String]

    var body: some View {
        Form {
            let advancedFields = additionalConnectionFields.filter { $0.section == .advanced }
            if !advancedFields.isEmpty {
                Section(databaseType.displayName) {
                    ForEach(advancedFields, id: \.id) { field in
                        if isFieldVisible(field) {
                            ConnectionFieldRow(
                                field: field,
                                value: Binding(
                                    get: {
                                        additionalFieldValues[field.id]
                                            ?? field.defaultValue ?? ""
                                    },
                                    set: { additionalFieldValues[field.id] = $0 }
                                )
                            )
                        }
                    }
                }
            }

            Section {
                StartupCommandsEditor(text: $startupCommands)
                    .frame(height: 80)
            } header: {
                Text(String(localized: "Startup Commands"))
            } footer: {
                Text("SQL commands to run after connecting, e.g. SET time_zone = 'Asia/Ho_Chi_Minh'. One per line or separated by semicolons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                StartupCommandsEditor(text: $preConnectScript)
                    .frame(height: 80)
            } header: {
                Text(String(localized: "Pre-Connect Script"))
            } footer: {
                Text("Shell script to run before connecting. Non-zero exit aborts connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if AppSettingsManager.shared.ai.enabled {
                    Picker(String(localized: "AI Policy"), selection: $aiPolicy) {
                        Text(String(localized: "Use Default"))
                            .tag(AIConnectionPolicy?.none as AIConnectionPolicy?)
                        ForEach(AIConnectionPolicy.allCases) { policy in
                            Text(policy.displayName)
                                .tag(AIConnectionPolicy?.some(policy) as AIConnectionPolicy?)
                        }
                    }
                }

                Picker(String(localized: "External Clients"), selection: $externalAccess) {
                    ForEach(ExternalAccessLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(String(localized: "External Access"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if AppSettingsManager.shared.ai.enabled {
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

            if AppSettingsManager.shared.ai.enabled, let connectionId {
                ConnectionMCPServersView(connectionId: connectionId)
            }

            if AppSettingsManager.shared.sync.enabled {
                Section(String(localized: "iCloud Sync")) {
                    Toggle(String(localized: "Local only"), isOn: $localOnly)
                    Text("This connection won't sync to other devices via iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func isFieldVisible(_ field: ConnectionField) -> Bool {
        PluginFieldRendering.isFieldVisible(field, type: databaseType, values: visibilityValues)
    }
}

// MARK: - Startup Commands Editor

struct StartupCommandsEditor: View {
    @Binding var text: String

    var body: some View {
        TextValueEditor(
            text: $text,
            font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            borderType: .bezelBorder
        )
    }
}
