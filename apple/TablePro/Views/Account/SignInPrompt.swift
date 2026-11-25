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
    let setupGuidePending: () -> Bool
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
            setupGuidePending: { SetupGuidePresenter.shared.isPending },
            isSignedIn: { AccountServices.shared.session.isSignedIn },
            hasStoredLicenseKey: { AccountServices.shared.hasLicenseKeyToExchange },
            present: { SignInWindowController.present(purpose: .firstLaunch) }
        )
    }

    // After launch, and again once the setup guide closes or the launch decides against it.
    func presentIfNeeded() {
        guard !defaults.bool(forKey: PreferenceKeys.signInPromptShown.name) else { return }
        guard !isUITestSandbox || uiTestRequestsPrompt else { return }
        // A machine-started process (an intent, MCP) waits for the person's own launch.
        guard isUserSession(), !setupGuidePending() else { return }
        defaults.set(true, forKey: PreferenceKeys.signInPromptShown.name)
        guard !isSignedIn(), !hasStoredLicenseKey() else { return }
        present()
    }
}
