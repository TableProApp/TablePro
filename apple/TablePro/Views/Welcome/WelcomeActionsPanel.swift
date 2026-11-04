import SwiftUI
import TableProSyncTransport

struct WelcomeActionsPanel: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var updates = UpdateCenter.shared
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared
    let onSignIn: () -> Void
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
                licenseLine
                syncLine
                if featureAccess.supportAudience == .prospect {
                    prospectLinks
                }
            }
            .font(.subheadline)
        }
    }

    // The timeline holds both links, not the sale line alone: an empty TimelineView still takes the
    // stack's spacing, so outside the sale it would leave a gap under the support link.
    private var prospectLinks: some View {
        let sale = DatedSale.blackFriday2026
        return TimelineView(DatedSaleSchedule(sale: sale)) { context in
            VStack(spacing: 4) {
                SupportPromptLink()
                if sale.isLive(at: context.date) {
                    Link(
                        String(
                            format: String(localized: "Black Friday: %lld%% off Pro until %@"),
                            sale.percentOff,
                            sale.end.formatted(.dateTime.month(.abbreviated).day())
                        ),
                        destination: sale.page
                    )
                    .buttonStyle(.link)
                    .accessibilityIdentifier("welcome-sale-link")
                }
            }
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

    // Only a state that needs the person: a working plan says nothing, and neither does a free account.
    @ViewBuilder
    private var licenseLine: some View {
        if let line = LicensePresentation.welcomeLine(
            state: featureAccess.state,
            configuration: AccountServices.shared.configuration,
            now: Date()
        ) {
            Button(line.title) {
                perform(line.action)
            }
            .buttonStyle(.link)
            .help(line.message)
            .accessibilityIdentifier("welcome-license-line")
        }
    }

    // A state without an action, and a check whose outcome needs room, open Settings > Account.
    private func perform(_ action: LicenseNoticeAction?) {
        switch action {
        case .signIn:
            onSignIn()
        case .some(let action):
            action.perform(referrer: .welcome)
        case nil:
            WindowOpener.shared.openSettings(tab: .account)
        }
    }

    // Only a blocker that stops uploads until the person acts; the Sync pane explains it.
    @ViewBuilder
    private var syncLine: some View {
        let presentation = SyncStatusPresentation(status: syncCoordinator.syncStatus)
        if presentation.showsOnWelcome {
            Button(presentation.title) {
                WindowOpener.shared.openSettings(tab: .sync)
            }
            .buttonStyle(.link)
            .help(presentation.message ?? "")
            .accessibilityIdentifier("welcome-sync-line")
        }
    }
}
