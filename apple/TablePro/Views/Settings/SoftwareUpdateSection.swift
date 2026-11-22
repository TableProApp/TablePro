import AppKit
import SwiftUI

struct SoftwareUpdatePage: View {
    @ObservedObject var updater: SoftwareUpdater
    @ObservedObject var updates: UpdateCenter

    private var summary: SoftwareUpdateSummary {
        updates.status.summary(currentVersion: Bundle.main.appVersion, lastChecked: updater.lastUpdateCheckDate)
    }

    // The updater owns these, so `GeneralSettings` holds no copy for settings sync to overwrite.
    private var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var automaticallyDownloadsUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }
        )
    }

    private var channel: Binding<UpdateChannel> {
        Binding(
            get: { updater.channel },
            set: { updater.setChannel($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(summary.actionTitle) {
                        updates.performPrimaryAction()
                    }
                    .disabled(!updates.isPrimaryActionEnabled)
                    .accessibilityIdentifier("software-update-action")
                } label: {
                    Text(summary.headline)
                        .accessibilityIdentifier("software-update-headline")
                    Text(summary.detail)
                        .accessibilityIdentifier("software-update-detail")
                }
                .accessibilityElement(children: .contain)

                Button(String(localized: "What's New")) {
                    NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("whats-new-link")
            }

            Section {
                Toggle("Automatically check for updates", isOn: automaticallyChecksForUpdates)
                    .accessibilityIdentifier("automatic-update-check-toggle")

                Toggle(isOn: automaticallyDownloadsUpdates) {
                    Text("Download and install updates automatically")
                    Text("A new version downloads in the background and installs the next time you quit TablePro.")
                }
                .disabled(!updater.allowsAutomaticUpdates || !updater.automaticallyChecksForUpdates)
                .accessibilityIdentifier("automatic-update-install-toggle")
            } header: {
                Text("Automatic Updates")
            }

            Section {
                Picker(selection: channel) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Beta").tag(UpdateChannel.beta)
                } label: {
                    Text("Update channel")
                    Text("Betas get new features first. Switching back to Stable keeps the beta you have until a newer release ships.")
                }
                .accessibilityIdentifier("update-channel-picker")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.softwareUpdate.pageIdentifier)
    }
}
