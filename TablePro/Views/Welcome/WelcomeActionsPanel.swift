//
//  WelcomeActionsPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeActionsPanel: View {
    let onActivateLicense: () -> Void
    let onNewConnection: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromApp: () -> Void
    let onImportConnectionsFile: () -> Void
    let onOpenProjectFolder: () -> Void

    private let updater = SoftwareUpdater.shared

    /// Captured once, because the stored value is overwritten on the same appearance that reads
    /// it. Without the capture the line would replace itself with nothing on the next redraw.
    @State private var lastSeenAppVersion = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

                VStack(spacing: 6) {
                    Text(verbatim: "TablePro")
                        .font(.title2.weight(.semibold))

                    versionLine

                    if showsUpdatedLine {
                        updatedLine
                    }

                    licenseLine
                }
            }

            Spacer()
                .frame(height: 28)

            VStack(spacing: 8) {
                Button(action: onNewConnection) {
                    Text("New Connection…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)

                WelcomeImportMenuButton(actions: WelcomeImportActions(
                    importConnectionsFile: onImportConnectionsFile,
                    importFromURL: onImportFromURL,
                    importFromApp: onImportFromApp,
                    openProjectFolder: onOpenProjectFolder
                ))
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer()

            SyncStatusIndicator(onActivateLicense: onActivateLicense)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: recordAppVersion)
    }

    private func recordAppVersion() {
        let defaults = AppStorageEnvironment.shared.defaults
        let key = PreferenceKeys.lastSeenAppVersion.name
        let current = Bundle.main.appVersion
        guard lastSeenAppVersion.isEmpty else { return }
        lastSeenAppVersion = defaults.string(forKey: key) ?? current
        defaults.set(current, forKey: key)
    }

    /// Updates install on quit with no dialog, so the release notes stop passing in front of
    /// anyone. This is the replacement, and it is deliberately pull-shaped: a window that appeared
    /// after every silent install would be more than a hundred interruptions a year spent on
    /// exactly the thing background installs exist to remove. The welcome window is the exception
    /// because the user chose to open it.
    private var showsUpdatedLine: Bool {
        !lastSeenAppVersion.isEmpty && lastSeenAppVersion != Bundle.main.appVersion
    }

    private var updatedLine: some View {
        HStack(spacing: 6) {
            Text(String(format: String(localized: "Updated from %@"), lastSeenAppVersion))
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button {
                NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
            } label: {
                Text(String(localized: "What's New"))
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .accessibilityIdentifier("welcome-updated-line")
    }

    private var versionLine: some View {
        HStack(spacing: 6) {
            Text(String(format: String(localized: "Version %@"), Bundle.main.appVersion))
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button {
                updater.checkForUpdates()
            } label: {
                Text(updater.checkForUpdatesTitle)
            }
            .buttonStyle(.link)
            .disabled(!updater.canCheckForUpdates)
        }
        .font(.callout)
    }

    /// The badge follows entitlement and the support link follows whether anything has been paid,
    /// which are different questions: a license the server has not confirmed in 30 days still
    /// pauses Pro features, and its owner is still not someone to ask for a purchase.
    private var licenseLine: some View {
        HStack(spacing: 6) {
            licenseBadge

            if LicenseManager.shared.supportAudience == .prospect {
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                SupportPromptLink()
            }
        }
        .font(.subheadline)
    }

    /// Exhaustive on purpose. This used to read `status.isValid`, so the one status that means
    /// "a paying customer who has been offline" was offered an activation sheet that needs the
    /// network to succeed, which is the one thing it could not do.
    @ViewBuilder
    private var licenseBadge: some View {
        switch LicenseManager.shared.status {
        case .active:
            Label(String(localized: "Pro"), systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        case .validationFailed:
            Label(String(localized: "Pro"), systemImage: "exclamationmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .help(String(localized: "License not verified in 30 days. Connect to the internet to check it."))
        case .unlicensed, .expired, .suspended, .deactivated:
            Button(action: onActivateLicense) {
                Text(String(localized: "Activate License"))
            }
            .buttonStyle(.link)
        }
    }
}
