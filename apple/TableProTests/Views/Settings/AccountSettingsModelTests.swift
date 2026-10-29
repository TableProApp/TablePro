//
//  AccountSettingsModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct AccountSettingsModelTests {
    @Test("Signed in, the pane loads the account's teams and devices")
    func reloadLoadsTeamsAndDevices() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set {
            $0.memberships = [FakeAccountServer.membership(teamID: "team_acme", name: "Acme", role: "member", hasSeat: false)]
        }
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)

        await model.reload()

        #expect(model.profile.value?.memberships == [
            AccountMembership(teamID: "team_acme", teamName: "Acme", role: "member", hasSeat: false)
        ])
        #expect(model.devices.value?.map { $0.id } == [FakeAccountServer.deviceID])
        #expect(model.content.devices?.first?.isThisMac == true)
        #expect(model.content.teams?.first?.hasSeat == false)
    }

    @Test("A reload that fails keeps the teams and devices it loaded before and says why")
    func failedReloadKeepsData() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        await model.reload()
        await fixture.server.set { $0.isOffline = true }

        await model.reload()

        #expect(model.devices.value?.count == 1)
        #expect(model.devices.failure != nil)
        #expect(model.profile.value != nil)
        #expect(model.profile.failure != nil)
    }

    @Test("Signing out empties the teams and devices")
    func signOutForgetsLoadedData() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        await model.reload()

        await model.signOut()
        try await waitUntil { model.devices.value == nil }

        #expect(model.profile.value == nil)
        #expect(model.content.identity == .signedOut)
    }

    @Test("Removing a device removes it from the account and lists the devices again")
    func removeDevice() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set {
            $0.devices.append(FakeAccountServer.device(id: "dev_old", name: "Old Mac", machineID: String(repeating: "1", count: 64)))
        }
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        await model.reload()
        let row = try #require(model.content.devices?.first { $0.id == "dev_old" })

        await model.removeDevice(row)

        #expect(await fixture.server.requests.contains { $0.method == "DELETE" && $0.path == "/devices/dev_old" })
        #expect(model.devices.value?.map { $0.id } == [FakeAccountServer.deviceID])
        #expect(model.actionFailure == nil)
    }

    @Test("A device whose offline file is still valid cannot be removed, and the pane says why")
    func removeDeviceWithOfflineFile() async throws {
        let fixture = try AccountFixture()
        let until = Date().addingTimeInterval(30 * 24 * 60 * 60).formatted(.iso8601)
        await fixture.server.set {
            $0.devices.append(FakeAccountServer.device(
                id: "dev_air", name: "Air-gapped", machineID: String(repeating: "2", count: 64), offlineUntil: until
            ))
        }
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        await model.reload()
        let row = try #require(model.devices.value?.first { $0.id == "dev_air" })
        #expect(model.content.devices?.first { $0.id == "dev_air" }?.canRemove == false)

        await model.removeDevice(.init(
            id: row.id, name: row.name, system: "", lastSeenAt: row.lastSeenAt, isThisMac: false, offlineUntil: nil
        ))

        #expect(model.actionFailure?.message == AccountError.server(status: 409, code: "offline_file_active").deviceRemovalDescription)
        #expect(model.devices.value?.contains { $0.id == "dev_air" } == true)
    }

    @Test("Use License Key replaces an interactive session, revokes it and deletes the stored key it used")
    func useStoredLicenseKey() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        let interactiveToken = try #require(Self.refreshToken(in: fixture.keychain))
        let model = AccountSettingsModel(services: fixture.services)
        #expect(fixture.services.storedLicenseKey == FakeAccountServer.validKey)

        let failure = await model.useLicenseKey(" \(FakeAccountServer.validKey) ")

        #expect(failure == nil)
        let exchange = try #require(await fixture.server.requests(to: "/oauth/token")
            .first { $0.form["grant_type"] == OAuthTokenClient.tokenExchangeGrant })
        #expect(exchange.form["subject_token"] == FakeAccountServer.validKey)
        #expect(await fixture.server.requests(to: "/oauth/revoke").first?.form["token"] == interactiveToken)
        #expect(Self.refreshToken(in: fixture.keychain) != interactiveToken)
        #expect(!fixture.hasLegacyLicense)
        #expect(try await fixture.services.session.accessToken().isFromLicenseKey)
        #expect(fixture.access.isAvailable(.iCloudSync))
    }

    @Test("A key the server refuses keeps the session that was there and the key stored on this Mac")
    func refusedLicenseKey() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        let interactiveToken = Self.refreshToken(in: fixture.keychain)
        let model = AccountSettingsModel(services: fixture.services)

        let failure = await model.useLicenseKey("ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")

        #expect(failure == AccountError.oauth("invalid_grant", description: nil).licenseKeyDescription)
        #expect(Self.refreshToken(in: fixture.keychain) == interactiveToken)
        #expect(await fixture.server.requests(to: "/oauth/revoke").isEmpty)
        #expect(fixture.hasLegacyLicense)
        #expect(fixture.access.isAvailable(.iCloudSync))
    }

    @Test("Signing in past the device limit opens the device limit sheet")
    func signInPastTheDeviceLimit() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.deviceLimitReached = true }
        let model = AccountSettingsModel(services: fixture.services)

        await model.signIn(using: FakeAuthenticator(server: fixture.server))

        #expect(model.presentsDeviceLimit)
        #expect(model.content.notices == [.deviceLimit])
    }

    @Test("An offline file made for another machine is refused with a reason")
    func offlineFileForAnotherMachine() async throws {
        let fixture = try AccountFixture()
        let directory = fixture.entitlementFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-000000000000.jwt")
        let token = await fixture.server.signedEntitlement(machineID: String(repeating: "0", count: 64), offline: true)
        try Data(token.utf8).write(to: file)
        let model = AccountSettingsModel(services: fixture.services)

        await model.importOfflineFile(at: file)

        #expect(model.actionFailure?.message == AccountError.entitlementRejected(.machine).offlineFileDescription)
        #expect(model.content.identity == .signedOut)
    }

    @Test("A valid offline file shows its account and plan without a session")
    func offlineFileImport() async throws {
        let fixture = try AccountFixture()
        let directory = fixture.entitlementFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-abababababab.jwt")
        try Data(await fixture.server.signedEntitlement(offline: true).utf8).write(to: file)
        let model = AccountSettingsModel(services: fixture.services)

        await model.importOfflineFile(at: file)

        #expect(model.actionFailure == nil)
        #expect(model.content.identity == .account(name: "Ada", email: "ada@m16.example", isSignedIn: false))
        #expect(model.content.verification?.isOfflineFile == true)
        #expect(model.content.plans.first?.title == "Starter")
        #expect(model.content.plans.first?.status == .lifetime)
    }

    private static func refreshToken(in keychain: InMemoryKeychain) -> String? {
        guard case .found(let token) = keychain.readStringResult(forKey: AccountSession.refreshTokenKey) else { return nil }
        return token
    }
}
