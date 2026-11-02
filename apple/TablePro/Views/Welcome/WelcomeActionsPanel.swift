import SwiftUI

struct WelcomeActionsPanel: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var updates = UpdateCenter.shared
    let onActivateLicense: () -> Void
    let onNewConnection: () -> Void
    let onOpenFile: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromApp: () -> Void
    let onImportFromAWS: () -> Void
    let onImportConnectionsFile: () -> Void
    let onOpenProjectFolder: () -> Void

    // Captured once: the same appearance that reads the stored value overwrites it.
    @State private var showsWhatsNew: Bool?

    var body: some View {
        VStack(spacing: 0) {
            identity
                .padding(.top, 28)

            Spacer(minLength: 24)

            actions
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: recordAppVersion)
    }

    private var identity: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 8, x: 0, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: "TablePro")
                    .font(.title2.weight(.semibold))

                Text(String(format: String(localized: "Version %@"), Bundle.main.displayVersion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("welcome-version-line")

                if let title = updates.status.indicatorTitle {
                    Button(title) {
                        updates.performPrimaryAction()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(updates.status.indicatorHelp ?? "")
                    .accessibilityIdentifier("welcome-update-link")
                }

                if showsWhatsNew == true {
                    Button(String(format: String(localized: "What's New in %@"), Bundle.main.appVersion)) {
                        NSApp.sendAction(#selector(AppDelegate.openChangelog(_:)), to: nil, from: nil)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityIdentifier("welcome-updated-line")
                }
            }

            VStack(spacing: 4) {
                licenseNotice
                if licenseManager.supportAudience == .prospect {
                    SupportPromptLink()
                }
            }
            .font(.subheadline)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: onNewConnection) {
                Text("New Connection…")
                    .frame(maxWidth: .infinity)
            }

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
    }

    private func recordAppVersion() {
        guard showsWhatsNew == nil else { return }
        showsWhatsNew = WhatsNewNotice(bundle: .main, defaults: AppStorageEnvironment.shared.defaults).recordLaunch()
    }

    // Only states that need the person: an active license says nothing. A license the server has not
    // confirmed in 30 days still pauses paid features, so it keeps its warning.
    @ViewBuilder
    private var licenseNotice: some View {
        switch licenseManager.status {
        case .active:
            EmptyView()
        case .validationFailed:
            Label(licenseManager.currentTier.displayName, systemImage: "exclamationmark.seal.fill")
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
