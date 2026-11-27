import SwiftUI
import UIKit

// Settings' TablePro Account: sign in to tablepro.app or the organization's server, this account's devices, its
// end-to-end keys, sign out.
struct AccountSection: View {
    let account: AccountModel
    let managed: ManagedAppConfiguration

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var sceneDelegate: TableProSceneDelegate

    @State private var failure: String?
    @State private var confirmsSignOut = false
    // Sign Out erases this device's keys, which the question says before the person answers.
    @State private var signOutErasesKeys = false
    @State private var isCheckingKeys = false
    @State private var isErasingKeys = false
    @State private var keysPrompt = AccountKeysSignOutPrompt()
    // Team Library edits the team has not taken, nil when they could not be read, and why an upload left some.
    @State private var teamChanges: [String]? = []
    @State private var uploadProblem: TeamLibraryProblem?
    @State private var isUploadingTeamChanges = false
    // The sign-in the question was asked about; a confirmation that outlives it signs nothing out.
    @State private var signOutSession: String?

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
            if hasTeamChanges {
                Button(String(localized: "Upload and Sign Out")) {
                    Task { await uploadThenSignOut() }
                }
                Button(String(localized: "Discard and Sign Out"), role: .destructive) {
                    Task { await signOut() }
                }
            } else {
                Button(String(localized: "Sign Out"), role: .destructive) {
                    Task { await signOut() }
                }
            }
        } message: {
            Text(signOutMessage)
        }
        .alert(
            String(localized: "This Device's Keys Weren't Erased"),
            // Only its buttons answer: an alert on iOS has no other way to close.
            isPresented: Binding(get: { keysPrompt.isAsking }, set: { _ in })
        ) {
            Button(String(localized: "Try Again")) { keysPrompt.settle(.retry) }
            Button(String(localized: "Sign Out Anyway"), role: .destructive) { keysPrompt.settle(.signOutAnyway) }
            Button(String(localized: "Cancel"), role: .cancel) { keysPrompt.settle(.cancel) }
        } message: {
            Text(String(
                format: String(localized: "%@ If you sign out anyway, the keys stay on this device until another account signs in here."),
                keysPrompt.reason ?? ""
            ))
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
        NavigationLink(String(localized: "End-to-End Encryption")) {
            AccountEncryptionPage()
        }
        .accessibilityIdentifier("account-encryption")
        Button(String(localized: "Sign Out"), role: .destructive) {
            Task { await askToSignOut() }
        }
        .disabled(account.isBusy || isCheckingKeys || isErasingKeys || isUploadingTeamChanges)
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

    // Nil, edits that could not be read, counts as some: discarding may lose them.
    private var hasTeamChanges: Bool {
        teamChanges.map { !$0.isEmpty } ?? true
    }

    // The Mac's sentences (AccountSignOutConfirmation), for this device.
    private var signOutMessage: String {
        var sentences: [String] = []
        if let teamChanges, !teamChanges.isEmpty {
            if let uploadProblem {
                sentences.append(String(format: String(localized: "The upload did not finish. %@"), uploadProblem.message))
            }
            sentences.append(String(
                format: String(localized: "These changes are not uploaded yet and are lost if you discard them: %@."),
                teamChanges.formatted(.list(type: .and))
            ))
        } else if teamChanges == nil {
            if let uploadProblem {
                sentences.append(String(format: String(localized: "The upload did not finish. %@"), uploadProblem.message))
            }
            sentences.append(String(localized: "TablePro couldn't list the Team Library changes not uploaded yet. Discarding loses any there are."))
        }
        if signOutErasesKeys {
            sentences.append(String(localized: "This device's end-to-end keys are erased. After you sign in again, approve it from another device or use your recovery key."))
        }
        return sentences.joined(separator: " ")
    }

    // Whether this device holds keys and which Team Library edits are not sent are read first, so the question can say
    // what Sign Out erases and loses.
    private func askToSignOut() async {
        signOutSession = account.snapshot.sessionID
        isCheckingKeys = true
        signOutErasesKeys = await appState.keysSignOut(askAfterFailure: keysPrompt.ask).holdsKeys()
        teamChanges = await appState.teamLibrary.unsentNames()
        uploadProblem = nil
        isCheckingKeys = false
        confirmsSignOut = true
    }

    // What the upload leaves is asked about again; all sent, the sign-out goes on.
    private func uploadThenSignOut() async {
        let session = signOutSession
        guard account.snapshot.sessionID == session, account.isSignedIn else { return }
        isUploadingTeamChanges = true
        let (left, problem) = await appState.teamLibrary.upload()
        isUploadingTeamChanges = false
        guard account.snapshot.sessionID == session, account.isSignedIn else { return }
        if left?.isEmpty == true {
            await signOut()
            return
        }
        teamChanges = left
        uploadProblem = problem
        confirmsSignOut = true
    }

    // The keys go before the sign-in (core ADR 0056, Sign Out). Kept signed in when the person cancels after the keys
    // could not be erased, or when another sign-in took this one's place meanwhile. Once signed out, the account's Team
    // Library data is deleted, verified.
    private func signOut() async {
        let session = signOutSession
        guard session != nil, account.snapshot.sessionID == session else { return }
        let keys = appState.keysSignOut(askAfterFailure: keysPrompt.ask)
        isErasingKeys = true
        let erased = await keys.signOut({ account.snapshot.sessionID == session })
        isErasingKeys = false
        guard erased else { return }
        let deleted = await appState.teamLibrary.signOut(session: session) { await account.signOut() }
        guard deleted == false else { return }
        failure = String(localized: "TablePro couldn't delete the Team Library data of the account you signed out of. Team Library stays off until it can.")
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
