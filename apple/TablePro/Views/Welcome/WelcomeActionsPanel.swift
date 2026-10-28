import Combine
import SwiftUI

struct WelcomeActionsPanel: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var updater = SoftwareUpdater.shared
    let onActivateLicense: () -> Void
    let onNewConnection: () -> Void
    let onOpenFile: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromApp: () -> Void
    let onImportFromAWS: () -> Void
    let onImportConnectionsFile: () -> Void
    let onOpenProjectFolder: () -> Void

    // One key, not the whole manager: the window lives all session and every settings write would redraw it.
    @State private var showsVersionInfo = AppSettingsManager.shared.general.showWelcomeVersionInfo

    private static let versionInfoSetting = AppSettingsManager.shared.$general
        .map(\.showWelcomeVersionInfo)
        .removeDuplicates()

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
        .onReceive(Self.versionInfoSetting) { showsVersionInfo = $0 }
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

                if showsVersionInfo {
                    Text(String(format: String(localized: "Version %@"), Bundle.main.displayVersion))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("welcome-version-line")
                }

                // A deferred update has its gentle reminder here, so hiding the line never hides that.
                if showsVersionInfo || updater.hasPendingUpdate {
                    Button(updater.checkForUpdatesTitle) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityIdentifier("welcome-check-for-updates-link")
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
                if featureAccess.supportAudience == .prospect {
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

    // Only states that need the person: a working entitlement says nothing, and neither does a free account.
    @ViewBuilder
    private var licenseNotice: some View {
        let state = featureAccess.state
        if featureAccess.currentEntitlement != nil {
            EmptyView()
        } else if case .failed = state.refresh, state.isSignedIn {
            Label(String(localized: "License validation failed"), systemImage: "exclamationmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .help(String(localized: "Connect to the internet to verify your license."))
        } else if !state.isSignedIn, state.legacy == nil {
            Button(action: onActivateLicense) {
                Text(String(localized: "Sign In"))
            }
            .buttonStyle(.link)
        }
    }
}
