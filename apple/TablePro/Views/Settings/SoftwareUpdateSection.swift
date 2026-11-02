import AppKit
import SwiftUI

struct SoftwareUpdateSection: View {
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
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("software-update-detail")
            }
            .accessibilityElement(children: .contain)

            Picker("Update channel:", selection: channel) {
                Text("Stable").tag(UpdateChannel.stable)
                Text("Beta").tag(UpdateChannel.beta)
            }
            .accessibilityIdentifier("update-channel-picker")

            Toggle("Automatically check for updates", isOn: automaticallyChecksForUpdates)
                .accessibilityIdentifier("automatic-update-check-toggle")

            Toggle("Download and install updates automatically", isOn: automaticallyDownloadsUpdates)
                .disabled(!updater.allowsAutomaticUpdates)
                .accessibilityIdentifier("automatic-update-install-toggle")
                .help(String(localized: "A new version downloads in the background and installs the next time you quit TablePro."))

            Button {
                NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
            } label: {
                Text(String(localized: "What's New"))
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("whats-new-link")
        } header: {
            Text("Software Update")
        } footer: {
            Text("Betas get new features first. Switching back to Stable keeps the beta you have until a newer release ships.")
        }
    }
}
