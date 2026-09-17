//
//  WelcomeActionsPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeActionsPanel: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    let onActivateLicense: () -> Void
    let onNewConnection: () -> Void
    let onOpenFile: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromApp: () -> Void
    let onImportFromAWS: () -> Void
    let onImportConnectionsFile: () -> Void
    let onOpenProjectFolder: () -> Void

    private let updater = SoftwareUpdater.shared

    /// Captured once, because the stored value is overwritten on the same appearance that reads
    /// it. Without the capture the line would replace itself with nothing on the next redraw.
    @State private var lastSeenAppVersion = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(verbatim: "TablePro")
                        .font(.title2.weight(.semibold))

                    Text(String(format: String(localized: "Version %@"), Bundle.main.appVersion))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(updater.checkForUpdatesTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(!updater.canCheckForUpdates)

                    if showsWhatsNew {
                        Button(String(format: String(localized: "What's New in %@"), Bundle.main.appVersion)) {
                            NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityIdentifier("welcome-updated-line")
                    }
                }

                VStack(spacing: 4) {
                    licenseBadge
                    if licenseManager.supportAudience == .prospect {
                        SupportPromptLink()
                    }
                }
                .font(.subheadline)
            }
            .padding(.top, 28)

            Spacer()
                .frame(height: 24)

            VStack(spacing: 8) {
                Button(action: onNewConnection) {
                    Text("New Connection…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onOpenFile) {
                    Text("Open File…")
                        .frame(maxWidth: .infinity)
                }

                WelcomeImportMenuButton(actions: WelcomeImportActions(
                    importConnectionsFile: onImportConnectionsFile,
                    importFromURL: onImportFromURL,
                    importFromApp: onImportFromApp,
                    importFromAWS: onImportFromAWS,
                    openProjectFolder: onOpenProjectFolder
                ))
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

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
    /// anyone. This is the pull-shaped replacement, shown on the window the user chose to open.
    private var showsWhatsNew: Bool {
        !lastSeenAppVersion.isEmpty && lastSeenAppVersion != Bundle.main.appVersion
    }

    /// The badge follows entitlement and the support link follows whether anything has been paid,
    /// which are different questions: a license the server has not confirmed in 30 days still
    /// pauses Pro features, and its owner is still not someone to ask for a purchase.
    @ViewBuilder
    private var licenseBadge: some View {
        switch licenseManager.status {
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
