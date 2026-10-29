//
//  SignInModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct SignInModelTests {
    private struct FailingAuthenticator: WebAuthenticating {
        let error: AccountError

        func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
            throw error
        }
    }

    @Test("Signing in from the window ends signed in, with the account and its plan")
    func signInSucceeds() async throws {
        let fixture = try AccountFixture()
        let model = SignInModel(services: fixture.services)

        await model.signIn(using: FakeAuthenticator(server: fixture.server))

        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Starter, Lifetime"))
        #expect(fixture.access.state.isSignedIn)
    }

    @Test("An account without licenses is on Free")
    func signInWithoutLicenses() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.licenses = [] }
        let model = SignInModel(services: fixture.services)

        await model.signIn(using: FakeAuthenticator(server: fixture.server))

        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Free"))
    }

    @Test("Closing the sign-in sheet leaves the window as it was, without an error")
    func canceledSignIn() async throws {
        let fixture = try AccountFixture()
        let model = SignInModel(services: fixture.services)

        await model.signIn(using: FailingAuthenticator(error: .canceled))

        #expect(model.phase == .ready)
        #expect(!fixture.access.state.isSignedIn)
    }

    @Test("A sign-in the network stopped says so and can be tried again")
    func failedSignIn() async throws {
        let fixture = try AccountFixture()
        let model = SignInModel(services: fixture.services)
        let error = AccountError.network("offline")

        await model.signIn(using: FailingAuthenticator(error: error))

        #expect(model.phase == .failed(try #require(error.friendlyDescription)))

        await model.signIn(using: FakeAuthenticator(server: fixture.server))
        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Starter, Lifetime"))
    }

    @Test("Past the device limit the window opens the device limit sheet once, and Not Now keeps it closed")
    func deviceLimit() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.deviceLimitReached = true }
        let model = SignInModel(services: fixture.services)

        await model.signIn(using: FakeAuthenticator(server: fixture.server))

        #expect(model.phase == .deviceLimit)
        #expect(model.presentsDeviceLimit)

        model.presentsDeviceLimit = false
        model.settle(presentsSheet: false)
        #expect(model.phase == .deviceLimit)
        #expect(!model.presentsDeviceLimit)
    }

    @Test("Removing a device in the sheet leaves the window signed in with the plan")
    func deviceLimitResolved() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.deviceLimitReached = true }
        let model = SignInModel(services: fixture.services)
        await model.signIn(using: FakeAuthenticator(server: fixture.server))

        try await fixture.services.removeDevice("dev_other")
        model.settle(presentsSheet: false)

        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Starter, Lifetime"))
    }
}
