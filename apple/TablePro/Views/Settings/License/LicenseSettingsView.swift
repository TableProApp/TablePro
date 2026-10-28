//
//  LicenseSettingsView.swift
//  TablePro
//

import SwiftUI

// What the account services back today; Settings > Account replaces it in M16.6.
struct LicenseSettingsView: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared

    @State private var isWorking = false
    @State private var failure: String?

    private var state: AccountState { featureAccess.state }

    var body: some View {
        Form {
            if let notice = LicenseNotice.make(state: state, current: featureAccess.currentEntitlement) {
                LicenseNoticeSection(notice: notice)
            }

            if state.isSignedIn || state.entitlement != nil {
                identitySection
            } else {
                landingSection
            }

            LicenseFeaturesSections(featureAccess: featureAccess)
        }
        .formStyle(.grouped)
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: featureAccess.currentEntitlement == nil ? "seal" : "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(featureAccess.currentEntitlement == nil ? Color.secondary : Color.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    if let email = state.entitlement?.email, !email.isEmpty {
                        Text(email)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    ForEach(state.entitlement?.licenses ?? [], id: \.id) { license in
                        Text(Self.planLine(license))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isWorking {
                    ProgressView().controlSize(.small)
                }

                Button(String(localized: "Refresh")) {
                    run { await AccountServices.shared.refreshEntitlement() }
                }
                .disabled(isWorking || !state.isSignedIn)
                .accessibilityIdentifier("license-refresh")
            }
            .padding(.vertical, 4)

            Link(String(localized: "Manage Account"), destination: AccountServices.shared.configuration.accountURL)

            if state.isSignedIn {
                Button(String(localized: "Sign Out"), role: .destructive) {
                    run { await AccountServices.shared.signOut() }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("account-sign-out")
            }
        }
    }

    private var landingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unlock the paid features")
                        .font(.headline)

                    Text("Everything else keeps working without a license, with nothing counting down.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(String(localized: "Sign In")) { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                        .accessibilityIdentifier("account-sign-in-button")

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func signIn() {
        failure = nil
        Task {
            isWorking = true
            defer { isWorking = false }
            do throws(AccountError) {
                try await AccountServices.shared.signIn(using: WebAuthenticationSessionAuthenticator())
            } catch {
                failure = error.friendlyDescription
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        Task {
            isWorking = true
            defer { isWorking = false }
            await work()
        }
    }

    // The plan and cycle are the server's words, shown as they come.
    private static func planLine(_ license: EntitlementLicense) -> String {
        var parts = [license.plan.capitalized, license.cycle.capitalized]
        if let team = license.team {
            parts.append(team.name)
        }
        return parts.joined(separator: ", ")
    }
}

private struct LicenseNotice: Equatable {
    enum Action: Equatable {
        case refresh
        case manageAccount
    }

    let title: String
    let message: String
    let action: Action

    static func make(state: AccountState, current: Entitlement?) -> LicenseNotice? {
        guard current == nil else { return nil }
        if case .deviceLimitReached = state.refresh {
            return LicenseNotice(
                title: String(localized: "Device Limit Reached"),
                message: String(localized: "Your license is in use on 3 other devices. Remove one from your account to use it here."),
                action: .manageAccount
            )
        }
        if state.entitlement != nil {
            return LicenseNotice(
                title: String(localized: "Your license has expired"),
                message: String(localized: "Connect to the internet to verify your license."),
                action: .refresh
            )
        }
        if state.isSignedIn, case .failed = state.refresh {
            return LicenseNotice(
                title: String(localized: "License validation failed"),
                message: String(localized: "Connect to the internet to verify your license."),
                action: .refresh
            )
        }
        return nil
    }
}

private struct LicenseNoticeSection: View {
    let notice: LicenseNotice

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)

                    Text(notice.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch notice.action {
                    case .refresh:
                        Button(String(localized: "Try Again")) {
                            Task { await AccountServices.shared.refreshEntitlement() }
                        }
                        .padding(.top, 2)
                    case .manageAccount:
                        Link(String(localized: "Manage Account"), destination: AccountServices.shared.configuration.accountURL)
                            .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    LicenseSettingsView()
        .frame(width: 640, height: 500)
}
