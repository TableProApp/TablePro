//
//  SignInPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct SignInPromptTests {
    private final class Recorder {
        var presented = 0
    }

    private static func prompt(
        _ defaults: UserDefaults,
        recorder: Recorder,
        isUITestSandbox: Bool = false,
        uiTestRequestsPrompt: Bool = false,
        isUserSession: Bool = true,
        welcomeSheetPending: Bool = false,
        isSignedIn: Bool = false,
        hasStoredLicenseKey: Bool = false
    ) -> SignInPrompt {
        SignInPrompt(
            defaults: defaults,
            isUITestSandbox: isUITestSandbox,
            uiTestRequestsPrompt: uiTestRequestsPrompt,
            isUserSession: { isUserSession },
            welcomeSheetPending: { welcomeSheetPending },
            isSignedIn: { isSignedIn },
            hasStoredLicenseKey: { hasStoredLicenseKey },
            present: { recorder.presented += 1 }
        )
    }

    @Test("A Mac that never saw it gets the sign-in window once")
    func showsOnce() throws {
        let defaults = try EphemeralDefaults()
        let recorder = Recorder()

        Self.prompt(defaults.defaults, recorder: recorder).presentIfNeeded()
        Self.prompt(defaults.defaults, recorder: recorder).presentIfNeeded()

        #expect(recorder.presented == 1)
    }

    @Test("A Mac signed in already, or holding a key the exchange signs in with, never sees it")
    func skippedWhenSignedInOrHoldingAKey() throws {
        let defaults = try EphemeralDefaults()
        let recorder = Recorder()

        Self.prompt(defaults.defaults, recorder: recorder, hasStoredLicenseKey: true).presentIfNeeded()
        Self.prompt(defaults.defaults, recorder: recorder).presentIfNeeded()

        #expect(recorder.presented == 0, "Skipping it counts as its one showing")

        let signedIn = try EphemeralDefaults()
        Self.prompt(signedIn.defaults, recorder: recorder, isSignedIn: true).presentIfNeeded()
        Self.prompt(signedIn.defaults, recorder: recorder).presentIfNeeded()
        #expect(recorder.presented == 0)
    }

    @Test("A new install sees the welcome sheet first, and the sign-in window when it closes")
    func waitsForTheWelcomeSheet() throws {
        let defaults = try EphemeralDefaults()
        let recorder = Recorder()

        Self.prompt(defaults.defaults, recorder: recorder, welcomeSheetPending: true).presentIfNeeded()
        #expect(recorder.presented == 0)

        Self.prompt(defaults.defaults, recorder: recorder).presentIfNeeded()
        #expect(recorder.presented == 1)
    }

    @Test("A process an intent or MCP started waits for the person's own launch")
    func waitsForAUserSession() throws {
        let defaults = try EphemeralDefaults()
        let recorder = Recorder()

        Self.prompt(defaults.defaults, recorder: recorder, isUserSession: false).presentIfNeeded()
        #expect(recorder.presented == 0)

        Self.prompt(defaults.defaults, recorder: recorder).presentIfNeeded()
        #expect(recorder.presented == 1)
    }

    @Test("Under the UI test sandbox it shows only when the test asks for it")
    func uiTestSandbox() throws {
        let defaults = try EphemeralDefaults()
        let recorder = Recorder()

        Self.prompt(defaults.defaults, recorder: recorder, isUITestSandbox: true).presentIfNeeded()
        #expect(recorder.presented == 0)

        Self.prompt(defaults.defaults, recorder: recorder, isUITestSandbox: true, uiTestRequestsPrompt: true).presentIfNeeded()
        #expect(recorder.presented == 1)
    }
}
