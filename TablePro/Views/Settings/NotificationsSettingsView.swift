//
//  NotificationsSettingsView.swift
//  TablePro
//

import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @Binding var settings: NotificationSettings

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("Notify when long-running work finishes", isOn: $settings.isEnabled)
                    .accessibilityIdentifier("notifications-enabled-toggle")

                Picker("Only after", selection: $settings.thresholdSeconds) {
                    ForEach(Self.thresholdChoices, id: \.self) { seconds in
                        Text(Self.thresholdLabel(seconds)).tag(seconds)
                    }
                }
                .disabled(!settings.isEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("TablePro only notifies when the result is not already on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notify about") {
                ForEach(TrackedOperationKind.allCases, id: \.self) { kind in
                    Toggle(kind.settingsLabel, isOn: binding(for: kind))
                        .disabled(!settings.isEnabled)
                }
            }

            if authorizationStatus == .denied {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Notifications are turned off for TablePro in System Settings.")
                        Spacer()
                        Button("Open System Settings", action: Self.openSystemSettings)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            authorizationStatus = await NotificationAuthorization.shared.refresh()
        }
    }

    private func binding(for kind: TrackedOperationKind) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledKindIds.contains(kind.rawValue) },
            set: { settings.setEnabled($0, for: kind) }
        )
    }

    private static let thresholdChoices = [5, 10, 20, 30, 60, 120, 300, 600]

    private static func thresholdLabel(_ seconds: Int) -> String {
        guard seconds >= 60 else {
            return String(format: String(localized: "%lld seconds"), seconds)
        }
        return String(format: String(localized: "%lld minutes"), seconds / 60)
    }

    private static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

extension TrackedOperationKind {
    var settingsLabel: String {
        switch self {
        case .query: return String(localized: "Queries")
        case .queryBatch: return String(localized: "Statement batches")
        case .rowSave: return String(localized: "Row edits")
        case .schemaChange: return String(localized: "Structure changes")
        case .dataImport: return String(localized: "Imports")
        case .dataExport: return String(localized: "Exports")
        case .objectCopy: return String(localized: "Object copies")
        case .backup: return String(localized: "Backups")
        case .fetchAll: return String(localized: "Fetch all rows")
        case .mcpQuery: return String(localized: "AI and MCP queries")
        case .scriptQuery: return String(localized: "AppleScript queries")
        }
    }
}
