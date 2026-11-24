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

        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Pro, Lifetime"))
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
        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Pro, Lifetime"))
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

        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: "Pro, Lifetime"))
    }

    // MARK: - Use a Company Server

    @Test("Use a Company Server runs discovery on the address, then signs in to that server")
    func companyServerSignIn() async throws {
        let fixture = try AccountFixture()
        let model = SignInModel(services: fixture.services)
        model.showCompanyServer()
        model.companyServerAddress = "tablepro.example.com"

        await model.signInToCompanyServer(using: FakeAuthenticator(server: fixture.server))

        #expect(model.server.host == "tablepro.example.com")
        #expect(!model.entersCompanyServer)
        #expect(model.phase == .signedIn(email: "ada@m16.example", plan: nil), "A company server sells no plan to name")
        #expect(fixture.access.state.isSignedIn)
    }

    @Test("An address that is not a TablePro server says so and keeps the form open")
    func companyServerRefused() async throws {
        let fixture = try AccountFixture()
        fixture.backend.refuse("wiki.example.com", with: .notATableProServer)
        let model = SignInModel(services: fixture.services)
        model.showCompanyServer()
        model.companyServerAddress = "https://wiki.example.com"

        await model.signInToCompanyServer(using: FakeAuthenticator(server: fixture.server))

        #expect(model.phase == .failed(AccountError.CompanyServerProblem.notATableProServer.description))
        #expect(model.entersCompanyServer)
        #expect(model.server.isProduction)
        #expect(!fixture.access.state.isSignedIn)
    }

    @Test("A malformed address is refused before anything is asked of the core")
    func malformedAddress() async throws {
        let fixture = try AccountFixture()
        let model = SignInModel(services: fixture.services)
        model.showCompanyServer()
        model.companyServerAddress = "http://tablepro.example.com"

        #expect(model.companyServerURL == nil)
        await model.signInToCompanyServer(using: FakeAuthenticator(server: fixture.server))

        #expect(model.phase == .failed(AccountError.CompanyServerProblem.invalidAddress.description))
        #expect(model.server.isProduction)
    }

    @Test("A server a configuration profile sets offers no other server, and its form never opens")
    func managedServerLocksTheChoice() throws {
        let fixture = try AccountFixture()
        fixture.backend.manage(AccountSettingsContentTests.companyServer)
        fixture.services.loadStoredState()

        let model = SignInModel(services: fixture.services, entersCompanyServer: true)
        model.showCompanyServer()

        #expect(!model.offersOtherServers)
        #expect(!model.entersCompanyServer)
        #expect(model.server.isManaged)
    }

    @Test("Back on tablepro.app after a company server, the window signs in there again")
    func backToTableProServer() async throws {
        let fixture = try AccountFixture()
        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)
        let model = SignInModel(services: fixture.services)
        #expect(!model.server.isProduction)

        await model.useTableProServer()

        #expect(model.server.isProduction)
        #expect(model.phase == .ready)
    }
}
