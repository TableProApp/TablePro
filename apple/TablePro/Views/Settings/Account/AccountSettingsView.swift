//
//  AccountSettingsView.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

// Settings > Account (clients.md): Account, Plan, Features, Devices, Teams, Offline.
internal struct AccountSettingsView: View {
    @StateObject private var model: AccountSettingsModel
    @Environment(\.openURL) private var openURL
    @State private var pendingRemoval: AccountSettingsContent.DeviceRow?

    init(model: @autoclosure @escaping () -> AccountSettingsModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        let content = model.content
        Form {
            AccountIdentitySection(model: model, identity: content.identity)

            if content.showsPlan {
                planSection(content)
            }

            AccountFeaturesSection(access: model.access, offersPurchase: content.identity == .signedOut)

            if content.showsDevices {
                devicesSection(content.devices)
            }

            teamsSection(content.teams)

            AccountOfflineSection(model: model, content: content)
        }
        .formStyle(.grouped)
        .task { await model.reload() }
        .sheet(isPresented: $model.presentsDeviceLimit) {
            DeviceLimitSheet(model: DeviceLimitModel(services: model.services))
        }
        .sheet(isPresented: $model.presentsLicenseKey) {
            LicenseKeySheet(
                storedKey: model.licenseKeyPrefill,
                signedInEmail: model.access.state.isSignedIn ? model.profile.value?.email ?? model.access.state.entitlement?.email : nil,
                isWorking: model.activity == .usingKey
            ) { key in
                await model.useLicenseKey(key)
            }
        }
        .fileImporter(
            isPresented: $model.presentsOfflineImporter,
            allowedContentTypes: [UTType(filenameExtension: "jwt") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importOfflineFile(at: url) }
            }
        }
        .alert(
            model.actionFailure?.title ?? "",
            isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } }),
            presenting: model.actionFailure
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { failure in
            Text(failure.message)
        }
        .confirmationDialog(
            pendingRemoval.map { String(format: String(localized: "Remove “%@”?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { row in
            Button(String(localized: "Remove"), role: .destructive) {
                Task { await model.removeDevice(row) }
            }
        } message: { _ in
            Text("TablePro on that device signs out the next time it checks your account. Its paid features keep working until its last check expires.")
        }
    }

    // MARK: - Plan

    private func planSection(_ content: AccountSettingsContent) -> some View {
        Section {
            ForEach(content.notices) { notice in
                AccountNoticeRow(notice: notice, model: model)
            }

            ForEach(content.plans) { plan in
                AccountPlanRow(plan: plan)
            }

            if content.notices.isEmpty, content.plans.isEmpty, !content.isFree {
                AccountLoadingRow(label: String(localized: "Checking your plan"))
            }

            if content.isFree {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're on Free")
                        Text("Paid plans add the features below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(String(localized: "Upgrade…")) {
                        openURL(model.services.configuration.portalBilling)
                    }
                    .accessibilityIdentifier("account-upgrade")
                }
            }
        } header: {
            Text("Plan")
        }
    }

    // MARK: - Devices

    private func devicesSection(_ devices: [AccountSettingsContent.DeviceRow]?) -> some View {
        Section {
            if let devices {
                ForEach(devices) { device in
                    AccountDeviceRow(
                        device: device,
                        isRemoving: model.activity == .removing(device.id),
                        isDisabled: model.isBusy
                    ) {
                        pendingRemoval = device
                    }
                }
            } else if model.devices.isLoading {
                AccountLoadingRow(label: String(localized: "Loading devices"))
            }

            if let failure = model.devices.failure {
                AccountLoadFailureRow(message: failure) {
                    Task { await model.loadDevices() }
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("A plan works on up to 3 devices at a time. Removing one signs TablePro out there.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Teams

    @ViewBuilder
    private func teamsSection(_ teams: [AccountSettingsContent.TeamRow]?) -> some View {
        let failure = model.access.state.isSignedIn ? model.profile.failure : nil
        if teams?.isEmpty == false || failure != nil || (teams == nil && model.profile.isLoading) {
            Section {
                ForEach(teams ?? []) { team in
                    AccountTeamRow(team: team)
                }

                if teams == nil, model.profile.isLoading {
                    AccountLoadingRow(label: String(localized: "Loading teams"))
                }

                if let failure {
                    AccountLoadFailureRow(message: failure) {
                        Task { await model.loadProfile() }
                    }
                }
            } header: {
                Text("Teams")
            }
        }
    }
}

// MARK: - Account

private struct AccountIdentitySection: View {
    @ObservedObject var model: AccountSettingsModel
    let identity: AccountSettingsContent.Identity
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch identity {
            case .account(let name, let email, let isSignedIn):
                signedIn(name: name, email: email, isSignedIn: isSignedIn)
            case .licenseKey(let isValid):
                licenseKey(isValid: isValid)
            case .signedOut:
                signedOut
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private func signedIn(name: String?, email: String?, isSignedIn: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? email ?? String(localized: "Signed in"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if name != nil, let email {
                    Text(email)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !isSignedIn {
                    Text("From an offline file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)

            Spacer()

            if model.activity == .signingOut {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Signing out"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)

        HStack {
            if isSignedIn {
                Button(String(localized: "Manage Account…")) {
                    openURL(model.services.configuration.accountURL)
                }
                .accessibilityIdentifier("account-manage")

                Spacer()

                Button(String(localized: "Sign Out")) {
                    Task { await model.signOut() }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("account-sign-out")
            } else {
                signInButton
                Spacer()
            }
        }
    }

    // The key exchange signs this Mac in, so a sign-in here would leave the key unexchanged.
    private func licenseKey(isValid: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isValid ? "checkmark.seal.fill" : "seal")
                .font(.largeTitle)
                .foregroundStyle(isValid ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("License key")
                    .font(.headline)

                Text(isValid
                    ? String(localized: "TablePro signs you in with your license key the next time it reaches the server.")
                    : String(localized: "Connect to the internet to verify your license."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sign in to TablePro")
                .font(.headline)

            Text("Your account unlocks the features your plan includes on this Mac. Everything else works without an account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        if let failure = model.signInFailure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-sign-in-error")
        }

        HStack(spacing: 10) {
            signInButton
                .buttonStyle(.borderedProminent)

            if model.activity == .signingIn {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Signing in"))
            }

            Spacer()
        }

        Text(SignInCopy.codeHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var signInButton: some View {
        Button(String(localized: "Sign In")) {
            Task {
                await model.signIn(using: WebAuthenticationSessionAuthenticator())
            }
        }
        .disabled(model.isBusy)
        .accessibilityIdentifier("account-sign-in-button")
    }
}

// MARK: - Offline

private struct AccountOfflineSection: View {
    @ObservedObject var model: AccountSettingsModel
    let content: AccountSettingsContent

    var body: some View {
        Section {
            if let verification = content.verification {
                HStack {
                    Text(Self.verificationText(verification))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    refreshButton
                }
            } else if content.canRefresh {
                HStack {
                    Text("Not verified yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    refreshButton
                }
            }

            LabeledContent(String(localized: "Machine ID")) {
                HStack(spacing: 8) {
                    Text(verbatim: content.machineID)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("account-machine-id")

                    Button(String(localized: "Copy")) {
                        ClipboardService.shared.writeText(content.machineID)
                    }
                    .accessibilityLabel(Text("Copy Machine ID"))
                }
            }

            HStack {
                Button(String(localized: "Import Offline File…")) {
                    model.presentsOfflineImporter = true
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("account-import-offline-file")

                Button(String(localized: "Use License Key…")) {
                    model.presentLicenseKey()
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("account-use-license-key")

                Spacer()
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("For a Mac that never reaches the internet, create an offline file for this machine ID in your account, then import it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if content.canRefresh {
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
                .accessibilityIdentifier("account-refresh")
            }
        }
    }

    static func verificationText(_ verification: AccountSettingsContent.Verification) -> String {
        let until = verification.validUntil.formatted(date: .abbreviated, time: .omitted)
        if verification.isExpired {
            return verification.isOfflineFile
                ? String(format: String(localized: "Offline file expired on %@"), until)
                : String(format: String(localized: "Expired on %@"), until)
        }
        if verification.isOfflineFile {
            return String(format: String(localized: "Offline file, valid until %@"), until)
        }
        return String(
            format: String(localized: "Verified %@, valid until %@"),
            verification.verifiedAt.formatted(.relative(presentation: .named)),
            until
        )
    }
}

// MARK: - Rows

private struct AccountPlanRow: View {
    let plan: AccountSettingsContent.PlanRow
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)

                Text(plan.owner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            if let status = plan.status {
                AccountPlanStatusLabel(status: status)
            }

            if let billing = plan.billing {
                Button(String(localized: "Billing…")) { openURL(billing) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountPlanStatusLabel: View {
    let status: AccountSettingsContent.PlanStatus

    var body: some View {
        switch status {
        case .paymentProblem:
            Label(String(localized: "Payment problem"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .active:
            Text("Active")
                .foregroundStyle(.secondary)
        case .lifetime:
            Text("Lifetime")
                .foregroundStyle(.secondary)
        case .endsOn(let date), .canceling(endsAt: .some(let date)):
            Text(String(format: String(localized: "Ends on %@"), date.formatted(date: .abbreviated, time: .omitted)))
                .foregroundStyle(.secondary)
        case .canceling(endsAt: .none):
            Text("Canceling")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AccountNoticeRow: View {
    let notice: AccountSettingsContent.Notice
    @ObservedObject var model: AccountSettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                action
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-notice-\(notice.id)")
    }

    private var title: String {
        switch notice {
        case .deviceLimit:
            return String(localized: "Device limit reached")
        case .paymentProblem:
            return String(localized: "Payment problem")
        case .canceling:
            return String(localized: "Your plan is canceling")
        case .expiringSoon(_, true):
            return String(localized: "Your offline file expires soon")
        case .expiringSoon:
            return String(localized: "Verify your plan soon")
        case .expired(_, true):
            return String(localized: "Your offline file has expired")
        case .expired, .verificationFailed:
            return String(localized: "Your plan could not be verified")
        }
    }

    private var message: String {
        switch notice {
        case .deviceLimit:
            return String(localized: "Your plan is in use on 3 other devices. Remove one to use it on this Mac. Until then, TablePro works on the Free plan here.")
        case .paymentProblem(let plan):
            if plan.billing == nil {
                return String(format: String(localized: "The last payment for %@ (%@) failed. The team's owner can update the payment method."), plan.title, plan.owner)
            }
            return String(format: String(localized: "The last payment for %@ failed. Update your payment method to keep your plan."), plan.title)
        case .canceling(let plan, let endsAt):
            guard let endsAt else {
                return String(format: String(localized: "%@ does not renew."), plan.title)
            }
            return String(
                format: String(localized: "%@ ends on %@ and does not renew."),
                plan.title,
                endsAt.formatted(date: .abbreviated, time: .omitted)
            )
        case .expiringSoon(let expiresAt, let isOfflineFile):
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            return isOfflineFile
                ? String(format: String(localized: "It expires on %@. Create a new one in your account and import it."), date)
                : String(format: String(localized: "TablePro has not reached the server for a while. Connect to the internet before %@ to keep your paid features."), date)
        case .expired(let at, let isOfflineFile):
            let date = at.formatted(date: .abbreviated, time: .omitted)
            return isOfflineFile
                ? String(format: String(localized: "It expired on %@. Create a new one in your account and import it."), date)
                : String(format: String(localized: "The last check expired on %@. Connect to the internet and refresh."), date)
        case .verificationFailed(let message):
            return message ?? String(localized: "Connect to the internet to verify your license.")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch notice {
        case .deviceLimit:
            Button(String(localized: "Choose a Device…")) { model.presentsDeviceLimit = true }
                .accessibilityIdentifier("account-choose-device")
        case .paymentProblem(let plan):
            if let billing = plan.billing {
                Button(String(localized: "Update Payment Method…")) { openURL(billing) }
            }
        case .canceling:
            // The plan's own row has Billing…, where the cancellation is resumed.
            EmptyView()
        case .expiringSoon(_, true), .expired(_, true):
            Button(String(localized: "Import Offline File…")) { model.presentsOfflineImporter = true }
        case .expiringSoon, .expired, .verificationFailed:
            Button(String(localized: "Try Again")) {
                Task { await model.checkNow() }
            }
            .disabled(model.isBusy)
        }
    }
}

private struct AccountDeviceRow: View {
    let device: AccountSettingsContent.DeviceRow
    let isRemoving: Bool
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.system.hasPrefix("macOS") ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if device.isThisMac {
                        Text("This Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    }
                }

                Text(AccountDeviceText.detail(system: device.system, lastSeenAt: device.lastSeenAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let offlineUntil = device.offlineUntil {
                Text(AccountDeviceText.offlineFile(until: offlineUntil))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Removing"))
            } else if device.canRemove {
                Button(String(localized: "Remove"), action: onRemove)
                    .disabled(isDisabled)
                    .accessibilityLabel(Text(String(format: String(localized: "Remove %@"), device.name)))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountTeamRow: View {
    let team: AccountSettingsContent.TeamRow
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(team.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(team.name)

                if let role = team.role {
                    Text(role)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if team.hasSeat {
                Label(String(localized: "Seat"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Text("No seat")
                    .foregroundStyle(.secondary)
            }

            Button(String(localized: "Manage…")) { openURL(team.manage) }
                .accessibilityLabel(Text(String(format: String(localized: "Manage %@"), team.name)))
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AccountLoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountLoadFailureRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(String(localized: "Try Again"), action: onRetry)
        }
    }
}
