import SwiftUI

// Settings > Account (clients.md): identity, Plan, then the Features, Devices, Teams and Offline File pages.
internal struct AccountSettingsView: View {
    @ObservedObject var model: AccountSettingsModel
    let showDevices: () -> Void

    var body: some View {
        let content = model.content
        Form {
            AccountIdentitySection(model: model, identity: content.identity, canRefresh: content.canRefresh)

            AccountServerSection(model: model, content: content)

            if content.showsPlan {
                AccountPlanSection(model: model, content: content, showDevices: showDevices)
            }

            Section {
                SettingsDrillRow(route: SettingsRoute.page(.accountFeatures), title: SettingsPage.accountFeatures.title)

                if content.showsDevices {
                    SettingsDrillRow(
                        route: SettingsRoute.page(.accountDevices),
                        title: SettingsPage.accountDevices.title,
                        value: content.devices.map { $0.count.formatted(.number) }
                    )
                }

                if content.showsTeams {
                    SettingsDrillRow(
                        route: SettingsRoute.page(.accountTeams),
                        title: SettingsPage.accountTeams.title,
                        value: content.teams.map { $0.isEmpty ? String(localized: "None") : $0.count.formatted(.number) }
                    )
                }

                if content.sellsPlans {
                    SettingsDrillRow(route: SettingsRoute.page(.accountOffline), title: SettingsPage.accountOffline.title)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-account")
    }
}

private struct AccountIdentitySection: View {
    @ObservedObject var model: AccountSettingsModel
    let identity: AccountSettingsContent.Identity
    let canRefresh: Bool

    var body: some View {
        Section {
            switch identity {
            case .account(let name, let email, true):
                signedIn(name: name, email: email)
            case .account(let name, let email, false):
                offlineFile(name: name, email: email)
            case .signedOut:
                signedOut
            }
        }
    }

    @ViewBuilder
    private func signedIn(name: String?, email: String?) -> some View {
        AccountIdentityRow(
            systemImage: "person.crop.circle.fill",
            tint: .secondary,
            title: name ?? email ?? String(localized: "Signed in"),
            subtitles: name == nil ? [] : [email].compactMap { $0 },
            fullText: email
        ) {
            if model.activity == .signingOut {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Signing out"))
            }

            Button(String(localized: "Sign Out…")) {
                Task { await model.signOut() }
            }
            .disabled(model.isBusy)
            .fixedSize()
            .accessibilityIdentifier("account-sign-out")
        }

        LabeledContent {
            Button(String(localized: "Manage Account…")) {
                model.openPortal(model.services.portal.accountURL)
            }
            .fixedSize()
            .accessibilityIdentifier("account-manage")
        } label: {
            if model.services.server.isProduction {
                Text("Profile, sign-in methods and billing")
            } else {
                Text("Profile and teams")
            }
        }
    }

    // A Mac that only holds an offline file has no session, so it can still sign in.
    @ViewBuilder
    private func offlineFile(name: String?, email: String?) -> some View {
        AccountIdentityRow(
            systemImage: "person.crop.circle.fill",
            tint: .secondary,
            title: name ?? email ?? String(localized: "Signed in"),
            subtitles: (name == nil ? [] : [email].compactMap { $0 }) + [String(localized: "From an offline file")],
            fullText: email
        ) {
            signInControl
        }

        signInFailure
    }

    @ViewBuilder
    private var signedOut: some View {
        let server = model.services.server
        LabeledContent {
            signInControl
        } label: {
            if server.isProduction {
                Text("Sign in to TablePro")
                Text("Your account unlocks the features your plan includes on this Mac. Everything else works without an account.")
            } else {
                Text(String(format: String(localized: "Sign in to %@"), server.host))
                Text("Your organization's TablePro server.")
            }
        }

        signInFailure

        if server.isProduction, server.othersAllowed {
            LabeledContent {
                Button(String(localized: "Use a Company Server…")) {
                    SignInWindowController.present(entersCompanyServer: true)
                }
                .disabled(model.isBusy)
                .fixedSize()
                .accessibilityIdentifier("account-use-company-server")
            } label: {
                Text("Company server")
                Text("Sign in to your organization's own TablePro server.")
            }
        }

        if server.isProduction {
            SettingsHelpRow(SignInCopy.codeHint)
        }
    }

    private var signInControl: some View {
        HStack(spacing: 8) {
            if model.activity == .signingIn {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Signing in"))
            }

            Button(String(localized: "Sign In")) {
                Task {
                    await model.signIn(using: WebAuthenticationSessionAuthenticator())
                }
            }
            .disabled(model.isBusy)
            .fixedSize()
            .accessibilityIdentifier("account-sign-in-button")
        }
    }

    @ViewBuilder
    private var signInFailure: some View {
        if let failure = model.signInFailure {
            AccountFailureLine(message: failure, identifier: "account-sign-in-error")
        }
    }
}

private struct AccountIdentityRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitles: [String]
    var fullText: String?
    var wrapsSubtitles = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                ForEach(subtitles, id: \.self) { subtitle in
                    if wrapsSubtitles {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .textSelection(.enabled)
            .help(fullText ?? "")

            Spacer(minLength: 12)

            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountPlanSection: View {
    @ObservedObject var model: AccountSettingsModel
    let content: AccountSettingsContent
    let showDevices: () -> Void

    var body: some View {
        Section {
            ForEach(content.notices) { notice in
                AccountNoticeRow(notice: notice, model: model, showDevices: showDevices)
            }

            ForEach(content.plans) { plan in
                AccountPlanRow(plan: plan, model: model)
            }

            if content.isFree {
                LabeledContent {
                    Button(String(localized: "Upgrade…")) {
                        Telemetry.shared.upgradeClicked(from: .licenseSettings)
                        model.openPortal(model.services.portal.portalBilling)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("account-upgrade")
                } label: {
                    Text("You're on Free")
                    Text("A paid plan adds the features listed under Features.")
                }
            }

            // A company server's license is in the Server section, and its entitlement may name no plan of its own.
            if content.notices.isEmpty, content.plans.isEmpty, !content.isFree, content.sellsPlans {
                AccountLoadingRow(label: String(localized: "Checking your plan"))
            }

            if let state = content.verificationState {
                AccountVerificationRow(
                    state: state,
                    model: model,
                    showsRefresh: content.canRefresh && !content.offersRetry
                )
            }

            // The last check still holds, so no notice above names a Refresh that just failed.
            if content.verification != nil,
               let failure = LicensePresentation.checkFailureMessage(model.access.state.refresh) {
                AccountFailureLine(message: failure)
            }
        } header: {
            Text("Plan")
        }
    }
}

private struct AccountNoticeRow: View {
    let notice: AccountSettingsContent.Notice
    @ObservedObject var model: AccountSettingsModel
    let showDevices: () -> Void

    private var severity: NoticeSeverity {
        notice.isInformational ? .info : .warning
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity.symbolName)
                .foregroundStyle(severity.tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)

                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            action
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-notice-\(notice.id)")
    }

    @ViewBuilder
    private var action: some View {
        switch notice {
        case .deviceLimit:
            Button(String(localized: "Show Devices"), action: showDevices)
                .fixedSize()
                .accessibilityIdentifier("account-choose-device")
        case .paymentProblem(let plan):
            if let billing = plan.billing {
                Button(String(localized: "Update Payment Method…")) { model.openPortal(billing) }
                    .fixedSize()
            }
        case .canceling:
            // The plan's own row has Billing…, where the cancellation is resumed.
            EmptyView()
        case .expiringSoon(_, true), .expired(_, true):
            Button(String(localized: "Import Offline File…")) { model.presentsOfflineImporter = true }
                .disabled(model.isBusy)
                .fixedSize()
        case .expiringSoon, .expired, .verificationFailed:
            HStack(spacing: 8) {
                if model.activity == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Refreshing"))
                }

                Button(String(localized: "Try Again")) {
                    Task { await model.checkNow() }
                }
                .disabled(model.isBusy)
                .fixedSize()
            }
        }
    }
}

private struct AccountPlanRow: View {
    let plan: AccountSettingsContent.PlanRow
    @ObservedObject var model: AccountSettingsModel

    var body: some View {
        SettingsRecordRow(title: plan.title, subtitle: plan.owner) {
            if let status = plan.status {
                AccountPlanStatusLabel(status: status)
            }

            if let billing = plan.billing {
                Button(String(localized: "Billing…")) { model.openPortal(billing) }
                    .fixedSize()
            }
        }
        .modifier(AccountRowMenu(title: String(localized: "Billing…"), isAvailable: plan.billing != nil) {
            if let billing = plan.billing {
                model.openPortal(billing)
            }
        })
    }
}

private struct AccountPlanStatusLabel: View {
    let status: AccountSettingsContent.PlanStatus

    var body: some View {
        Group {
            switch status {
            case .paymentProblem:
                Label {
                    Text("Payment problem")
                } icon: {
                    Image(systemName: NoticeSeverity.warning.symbolName)
                        .foregroundStyle(NoticeSeverity.warning.tint)
                }
            case .active:
                Text("Active")
            case .lifetime:
                Text("Lifetime")
            case .renewsOn(let date):
                Text(String(format: String(localized: "Renews on %@"), date.formatted(date: .abbreviated, time: .omitted)))
            case .endsOn(let date), .canceling(endsAt: .some(let date)):
                Text(String(format: String(localized: "Ends on %@"), date.formatted(date: .abbreviated, time: .omitted)))
            case .canceling(endsAt: .none):
                Text("Canceling")
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .layoutPriority(1)
    }
}

private struct AccountVerificationRow: View {
    let state: AccountSettingsContent.VerificationState
    @ObservedObject var model: AccountSettingsModel
    let showsRefresh: Bool

    var body: some View {
        SettingsRecordRow(title: title, subtitle: subtitle) {
            if showsRefresh {
                AccountRefreshControl(model: model)
            }
        }
    }

    private var title: String {
        switch state {
        case .verified(let at?, _):
            String(format: String(localized: "Verified %@"), at.formatted(.relative(presentation: .named)))
        case .verified(nil, _):
            String(localized: "Verified")
        case .offlineFile, .offlineFileExpired:
            String(localized: "Offline file")
        case .expired:
            String(localized: "Expired")
        case .notVerified:
            String(localized: "Not verified yet")
        }
    }

    private var subtitle: String? {
        switch state {
        case .verified(_, let until), .offlineFile(let until):
            String(format: String(localized: "Valid until %@"), until.formatted(date: .abbreviated, time: .omitted))
        case .expired(let on), .offlineFileExpired(let on):
            String(format: String(localized: "Expired on %@"), on.formatted(date: .abbreviated, time: .omitted))
        case .notVerified:
            nil
        }
    }
}

private struct AccountRefreshControl: View {
    @ObservedObject var model: AccountSettingsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.activity == .checking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Refreshing"))
            }

            Button(String(localized: "Refresh")) {
                Task { await model.checkNow() }
            }
            .disabled(model.isBusy)
            .fixedSize()
            .accessibilityIdentifier("account-refresh")
        }
    }
}

internal struct AccountDevicesPage: View {
    @ObservedObject var model: AccountSettingsModel

    var body: some View {
        let devices = model.content.devices
        Form {
            Section {
                if let devices {
                    if devices.isEmpty, model.devices.failure == nil {
                        Text("No devices are signed in.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(devices) { device in
                        AccountDeviceRow(
                            device: device,
                            isRemoving: model.activity == .removing(device.id),
                            isDisabled: model.isBusy
                        ) {
                            model.pendingRemoval = device
                        }
                    }
                } else if model.devices.isLoading {
                    AccountLoadingRow(label: String(localized: "Loading devices"))
                }

                if let failure = model.devices.failure {
                    AccountLoadFailureRow(message: failure, isRetrying: model.devices.isLoading) {
                        Task { await model.loadDevices() }
                    }
                }

                if model.services.server.isProduction {
                    SettingsHelpRow("A plan works on up to 3 devices at a time. Removing one signs TablePro out there.")
                } else {
                    SettingsHelpRow("Removing a device signs TablePro out there.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.accountDevices.pageIdentifier)
    }
}

private struct AccountDeviceRow: View {
    let device: AccountSettingsContent.DeviceRow
    let isRemoving: Bool
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        SettingsRecordRow(
            title: device.name,
            subtitle: AccountDeviceText.detail(system: device.system, lastSeenAt: device.lastSeenAt, isThisMac: device.isThisMac)
        ) {
            if let offlineUntil = device.offlineUntil {
                Text(AccountDeviceText.offlineFile(until: offlineUntil))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            } else if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Removing"))
            } else if device.canRemove {
                Button(String(localized: "Remove…"), action: onRemove)
                    .disabled(isDisabled)
                    .fixedSize()
                    .accessibilityLabel(Text(String(format: String(localized: "Remove %@"), device.name)))
            }
        }
        .modifier(AccountRowMenu(
            title: String(localized: "Remove…"),
            isAvailable: device.canRemove && !isRemoving,
            isDisabled: isDisabled,
            action: onRemove
        ))
    }
}

internal struct AccountTeamsPage: View {
    @ObservedObject var model: AccountSettingsModel

    var body: some View {
        let teams = model.content.teams
        Form {
            Section {
                if let teams {
                    if teams.isEmpty, model.profile.failure == nil {
                        Text("You are not on a team.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(teams) { team in
                        AccountTeamRow(team: team, model: model)
                    }
                } else if model.profile.isLoading {
                    AccountLoadingRow(label: String(localized: "Loading teams"))
                }

                if let failure = model.profile.failure {
                    AccountLoadFailureRow(message: failure, isRetrying: model.profile.isLoading) {
                        Task { await model.loadProfile() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.accountTeams.pageIdentifier)
    }
}

private struct AccountTeamRow: View {
    let team: AccountSettingsContent.TeamRow
    @ObservedObject var model: AccountSettingsModel

    private var subtitle: String {
        let seat = team.hasSeat ? String(localized: "Seat assigned") : String(localized: "No seat")
        guard let role = team.role else { return seat }
        return String(format: String(localized: "%@ · %@"), role, seat)
    }

    var body: some View {
        SettingsRecordRow(title: team.name, subtitle: subtitle) {
            Button(String(localized: "Manage…")) { model.openPortal(team.manage) }
                .fixedSize()
                .accessibilityLabel(Text(String(format: String(localized: "Manage %@"), team.name)))
        }
        .modifier(AccountRowMenu(title: String(localized: "Manage…")) {
            model.openPortal(team.manage)
        })
    }
}

internal struct AccountOfflinePage: View {
    @ObservedObject var model: AccountSettingsModel

    var body: some View {
        let machineID = model.services.machineID
        Form {
            Section {
                LabeledContent(String(localized: "Machine ID")) {
                    HStack(spacing: 8) {
                        Text(verbatim: machineID)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 240, alignment: .trailing)
                            .help(machineID)
                            .accessibilityIdentifier("account-machine-id")

                        Button(String(localized: "Copy")) {
                            ClipboardService.shared.writeText(machineID)
                        }
                        .fixedSize()
                        .accessibilityLabel(Text("Copy Machine ID"))
                    }
                }

                LabeledContent {
                    Button(String(localized: "Import Offline File…")) {
                        model.presentsOfflineImporter = true
                    }
                    .disabled(model.isBusy)
                    .fixedSize()
                    .accessibilityIdentifier("account-import-offline-file")
                } label: {
                    Text("Offline file")
                    Text("For a Mac that never reaches the internet, create an offline file for this machine ID in your account, then import it here.")
                }
            }

            Section {
                LabeledContent {
                    Button(String(localized: "Use License Key…")) {
                        model.presentLicenseKey()
                    }
                    .disabled(model.isBusy)
                    .fixedSize()
                    .accessibilityIdentifier("account-use-license-key")
                } label: {
                    Text("License key")
                    Text("Sign this Mac in with a key from an older version of TablePro.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.accountOffline.pageIdentifier)
    }
}

private struct AccountLoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountLoadFailureRow: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: NoticeSeverity.warning.symbolName)
                .foregroundStyle(NoticeSeverity.warning.tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading"))
            } else {
                Button(String(localized: "Try Again"), action: onRetry)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountFailureLine: View {
    let message: String
    var identifier: String?

    var body: some View {
        NoticeLabel(message)
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier ?? "")
    }
}

// A row's one action also sits in its context menu and its accessibility actions.
private struct AccountRowMenu: ViewModifier {
    let title: String
    var isAvailable = true
    var isDisabled = false
    let action: () -> Void

    func body(content: Content) -> some View {
        if isAvailable {
            content
                .contextMenu {
                    Button(title, action: action)
                        .disabled(isDisabled)
                }
                .accessibilityAction(named: Text(title)) {
                    if !isDisabled { action() }
                }
        } else {
            content
        }
    }
}
