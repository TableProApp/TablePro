//
//  SignInPrompt.swift
//  TablePro
//

import Foundation

// Shows the sign-in window once, to a new install and to an existing one after the update. A Mac that is signed in,
// or holds a license key the exchange signs in with, never sees it (clients.md, First launch).
@MainActor
internal struct SignInPrompt {
    let defaults: UserDefaults
    let isUITestSandbox: Bool
    let uiTestRequestsPrompt: Bool
    let isUserSession: () -> Bool
    let welcomeSheetPending: () -> Bool
    let isSignedIn: () -> Bool
    let hasStoredLicenseKey: () -> Bool
    let present: () -> Void

    static var live: SignInPrompt {
        let environment = AppStorageEnvironment.shared
        return SignInPrompt(
            defaults: environment.defaults,
            isUITestSandbox: environment.isIsolated,
            uiTestRequestsPrompt: UITestLaunchEnvironment.requestsSignInPrompt,
            isUserSession: { AppActivationPolicyController.shared.origin == .user },
            welcomeSheetPending: {
                WelcomeSheetGate.shouldPresent(
                    hasSeen: AppSettingsStorage.shared.hasSeenWelcomeSheet(),
                    isUITestSandbox: environment.isIsolated,
                    uiTestRequestsSheet: UITestLaunchEnvironment.requestsWelcomeSheet
                )
            },
            isSignedIn: { AccountServices.shared.session.isSignedIn },
            hasStoredLicenseKey: { AccountServices.shared.storedLicenseKey != nil },
            present: { SignInWindowController.present(purpose: .firstLaunch) }
        )
    }

    // After launch, and again when the welcome sheet a new install sees first is closed.
    func presentIfNeeded() {
        guard !defaults.bool(forKey: PreferenceKeys.signInPromptShown.name) else { return }
        guard !isUITestSandbox || uiTestRequestsPrompt else { return }
        // A machine-started process (an intent, MCP) waits for the person's own launch.
        guard isUserSession(), !welcomeSheetPending() else { return }
        defaults.set(true, forKey: PreferenceKeys.signInPromptShown.name)
        guard !isSignedIn(), !hasStoredLicenseKey() else { return }
        present()
    }
}
