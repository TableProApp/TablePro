import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @Binding var settings: NotificationSettings
    @ObservedObject var visit: SettingsPaneVisit

    @StateObject private var permission = NotificationPermissionMonitor()

    var body: some View {
        Form {
            if settings.isEnabled, permission.status == .denied {
                Section {
                    permissionRow
                }
            }

            Section {
                Toggle(isOn: $settings.isEnabled) {
                    Text("Show notifications")
                    Text(
                        "When long-running work finishes out of sight, an agent needs your answer or its reply fails, or an extension can't load or update."
                    )
                }
                .accessibilityIdentifier("notifications-enabled-toggle")

                Picker(selection: threshold) {
                    ForEach(settings.thresholdOptions, id: \.self) { seconds in
                        Text(verbatim: SettingsFormat.duration(seconds: seconds)).tag(seconds)
                    }
                } label: {
                    Text("Treat work as long-running after")
                    Text(
                        "When work this long finishes out of sight, its tab is marked and, with notifications on, a notification shows."
                    )
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("notifications-threshold-picker")
            }
        }
        .formStyle(.grouped)
        .task(id: visit.count) {
            await permission.refresh()
        }
    }

    private var permissionRow: some View {
        LabeledContent {
            Button("Open System Settings", action: Self.openSystemSettings)
                .accessibilityIdentifier("notifications-open-system-settings")
        } label: {
            Label {
                Text("Notifications are off in System Settings")
                Text("TablePro can't show any notification until you allow it there.")
            } icon: {
                Image(systemName: NoticeSeverity.warning.symbolName)
                    .foregroundStyle(NoticeSeverity.warning.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications-permission-row")
    }

    // A stored value outside the allowed range shows the value that applies instead of a blank pop-up.
    private var threshold: Binding<Int> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.validatedThresholdSeconds },
            set: { settings.wrappedValue.thresholdSeconds = $0 }
        )
    }

    private static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
