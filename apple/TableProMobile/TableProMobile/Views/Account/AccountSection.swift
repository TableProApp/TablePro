import SwiftUI
import UIKit

// Settings' TablePro Account: sign in to tablepro.app or the organization's server, this account's devices, sign out.
struct AccountSection: View {
    let account: AccountModel
    let managed: ManagedAppConfiguration

    @EnvironmentObject private var sceneDelegate: TableProSceneDelegate

    @State private var failure: String?
    @State private var confirmsSignOut = false

    var body: some View {
        Section {
            switch account.availability {
            case .opening:
                ProgressView()
            case .waitingForUnlock:
                Text("Unlock this device to use your TablePro account.")
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Your TablePro account could not open on this device.")
                    .foregroundStyle(.secondary)
            case .open:
                if !account.isRestored {
                    ProgressView()
                } else if account.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }
            }
        } header: {
            Text("TablePro Account")
        } footer: {
            if let notice = signOutNotice {
                Text(notice)
            }
        }
        .alert(
            String(localized: "Account"),
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog(
            String(localized: "Sign out of TablePro on this device?"),
            isPresented: $confirmsSignOut,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Sign Out"), role: .destructive) {
                Task { await account.signOut() }
            }
        }
    }

    @ViewBuilder
    private var signedOut: some View {
        Button(String(localized: "Sign In")) {
            Task { await signIn() }
        }
        .disabled(account.isBusy)
        .accessibilityIdentifier("account-sign-in")
        NavigationLink {
            AccountServerPage(account: account, managed: managed)
        } label: {
            serverRow
        }
        .disabled(!account.server.othersAllowed)
    }

    @ViewBuilder
    private var signedIn: some View {
        if let email = account.snapshot.email {
            LabeledContent(String(localized: "Signed In As")) {
                VStack(alignment: .trailing) {
                    if let name = account.snapshot.name, !name.isEmpty {
                        Text(verbatim: name)
                    }
                    Text(verbatim: email)
                        .foregroundStyle(.secondary)
                }
            }
        }
        serverRow
        if let notice = account.license.flatMap(AccountServerLicenseText.notice) {
            Label(notice, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        problemRow
        NavigationLink(String(localized: "Devices")) {
            AccountDevicesPage(account: account)
        }
        Button(String(localized: "Sign Out"), role: .destructive) {
            confirmsSignOut = true
        }
        .disabled(account.isBusy)
    }

    private var serverRow: some View {
        LabeledContent {
            Text(verbatim: account.server.host)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text("Server")
            if account.server.isManaged {
                Text("Managed by your organization")
            }
        }
    }

    @ViewBuilder
    private var problemRow: some View {
        switch account.snapshot.problem {
        case .deviceLimitReached:
            Label(
                String(localized: "Your plan's devices are all in use. Remove one in Devices to use this device."),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .refreshFailed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    error.mobileDescription ?? String(localized: "The account could not be refreshed."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Button(String(localized: "Try Again")) {
                    Task { await refresh() }
                }
            }
        case .expired, nil:
            EmptyView()
        }
    }

    private var signOutNotice: String? {
        switch account.involuntarySignOut {
        case .refreshRefused:
            String(localized: "You were signed out because the server no longer accepts this sign-in. Sign in again.")
        case .deviceRevoked:
            String(localized: "You were signed out because this device was removed from your account.")
        case .serverChanged:
            String(localized: "You were signed out because the server changed.")
        case .user, nil:
            nil
        }
    }

    private func signIn() async {
        do throws(AccountError) {
            try await account.signIn(using: WebAuthenticationSessionAuthenticator { [sceneDelegate] in
                sceneDelegate.presentationWindow
            })
        } catch {
            failure = error.mobileDescription
        }
    }

    private func refresh() async {
        do throws(AccountError) {
            try await account.refresh()
        } catch {
            failure = error.mobileDescription
        }
    }
}

enum AccountServerLicenseText {
    // Past its end the organization's license still lets this device sign in; it only says so.
    static func notice(_ license: AccountServerLicense) -> String? {
        guard license.state != .active else { return nil }
        let date = license.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return String(
            format: String(localized: "Your organization's TablePro license expired on %@. Ask your administrator to renew it."),
            date
        )
    }
}
