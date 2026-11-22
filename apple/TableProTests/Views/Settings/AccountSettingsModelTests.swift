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
        #expect(model.content.plans.first?.title == "Pro")
        #expect(model.content.plans.first?.status == .lifetime)
    }

    @Test("A visit within a minute of the last load reuses it, and a later one loads again")
    func reloadIfStaleSkipsAFreshLoad() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let clock = TestNow()
        let loads = CountingLoads()
        let model = AccountSettingsModel(services: fixture.services, loader: loads.loader, now: { clock.date })

        await model.reloadIfStale()
        #expect(loads.profile == 1)
        #expect(loads.devices == 1)

        clock.date += AccountSettingsModel.freshness - 1
        await model.reloadIfStale()
        #expect(loads.profile == 1)

        clock.date += 2
        await model.reloadIfStale()
        #expect(loads.profile == 2)
        #expect(loads.devices == 2)
    }

    @Test("A load canceled before it answers records no failure, stops loading, and the next visit loads again")
    func canceledLoadRecordsNothing() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let gate = AsyncGate()
        let loads = CountingLoads()
        loads.profileGate = gate
        loads.profileFailure = .canceled
        let model = AccountSettingsModel(services: fixture.services, loader: loads.loader)

        let load = Task { await model.reload() }
        await gate.arrived(1)
        #expect(model.profile.isLoading)
        await gate.open()
        await load.value

        #expect(!model.profile.isLoading)
        #expect(model.profile.failure == nil)
        #expect(model.profile.value == nil)

        loads.profileFailure = nil
        await model.reloadIfStale()
        #expect(loads.profile == 2)
        #expect(model.profile.value != nil)
    }

    @Test("A result that answers after the account signed out lands nowhere")
    func lateResultFromAnOldAccountIsDropped() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let gate = AsyncGate()
        let loads = CountingLoads()
        loads.profileGate = gate
        let model = AccountSettingsModel(services: fixture.services, loader: loads.loader)

        let load = Task { await model.reload() }
        await gate.arrived(1)
        await model.signOut()
        try await waitUntil { !model.profile.isLoading }
        await gate.open()
        await load.value

        #expect(model.profile.value == nil)
        #expect(model.devices.value == nil)
        #expect(model.content.identity == .signedOut)
    }

    @Test("Sign Out… asks first and names the team edits a sign-out discards; Cancel keeps the session")
    func signOutConfirmationNamesUnsentTeamChanges() async throws {
        let fixture = try await TeamLibraryFixture()
        await fixture.sync.sync()
        await fixture.library { $0.pushFaults = [503] }
        let result = try await fixture.sync.publishSavedQueries(
            favorites: [TeamLibraryFixture.favorite(name: "Orders")],
            folders: [],
            to: TeamLibraryFixture.team
        )
        #expect(result == .queued(.server))
        let sync = fixture.sync
        let model = AccountSettingsModel(services: fixture.account.services, hasUnsentTeamChanges: { sync.hasUnsentChanges })

        model.requestSignOut()

        #expect(model.confirmsSignOut)
        #expect(model.signOutConfirmation == AccountSignOutConfirmation(discardsTeamChanges: true, removesOfflineFile: false))
        #expect(model.signOutConfirmation?.discardsSomething == true)
        model.cancelSignOut()
        #expect(!model.confirmsSignOut)
        #expect(fixture.account.services.session.isSignedIn)

        #expect(await fixture.sync.sync() == .synced)
        #expect(!fixture.sync.hasUnsentChanges)
        model.requestSignOut()
        #expect(model.signOutConfirmation?.discardsSomething == false)
    }

    @Test("Signing out with an imported offline file says the file goes, and it does")
    func signOutRemovesTheOfflineFile() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let directory = fixture.entitlementFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-abababababab.jwt")
        try Data(await fixture.server.signedEntitlement(offline: true).utf8).write(to: file)
        let model = AccountSettingsModel(services: fixture.services, hasUnsentTeamChanges: { false })
        await model.importOfflineFile(at: file)

        model.requestSignOut()
        #expect(model.signOutConfirmation == AccountSignOutConfirmation(discardsTeamChanges: false, removesOfflineFile: true))
        await model.signOut()

        #expect(!model.confirmsSignOut)
        #expect(!FileManager.default.fileExists(atPath: fixture.entitlementFile.path))
        #expect(model.content.identity == .signedOut)
    }

    @Test("Confirming a device removal clears the pending removal the dialog showed")
    func pendingRemovalLivesOnTheModel() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set {
            $0.devices.append(FakeAccountServer.device(id: "dev_old", name: "Old Mac", machineID: String(repeating: "1", count: 64)))
        }
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        await model.reload()
        let row = try #require(model.content.devices?.first { $0.id == "dev_old" })

        model.pendingRemoval = row
        await model.removeDevice(row)

        #expect(model.pendingRemoval == nil)
        #expect(model.devices.value?.contains { $0.id == "dev_old" } == false)
    }

    @Test("Back from a portal page the account is checked again, even right after a load")
    func returnFromThePortalChecksTheAccount() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let opened = OpenedURLs()
        let loads = CountingLoads()
        let model = AccountSettingsModel(services: fixture.services, loader: loads.loader, openURL: { opened.urls.append($0) })
        let entitlementPath = "/devices/\(FakeAccountServer.deviceID)/entitlement"
        await model.refreshOnVisit()
        let checks = await fixture.server.requests(to: entitlementPath).count

        model.openPortal(fixture.services.configuration.portalBilling)
        #expect(opened.urls == [fixture.services.configuration.portalBilling])
        await model.refreshOnVisit()

        #expect(await fixture.server.requests(to: entitlementPath).count == checks + 1)
        #expect(loads.profile == 2)

        await model.refreshOnVisit()
        #expect(await fixture.server.requests(to: entitlementPath).count == checks + 1)
        #expect(loads.profile == 2)
    }

    private static func refreshToken(in keychain: InMemoryKeychain) -> String? {
        guard case .found(let token) = keychain.readStringResult(forKey: AccountSession.refreshTokenKey) else { return nil }
        return token
    }
}

@MainActor
private final class TestNow {
    var date = Date()
}

@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

@MainActor
private final class CountingLoads {
    var profile = 0
    var devices = 0
    var profileGate: AsyncGate?
    var profileFailure: AccountError?

    var loader: AccountSettingsModel.Loader {
        AccountSettingsModel.Loader(
            profile: { () async throws(AccountError) -> AccountProfile in
                self.profile += 1
                if let gate = self.profileGate {
                    await gate.wait()
                }
                if let failure = self.profileFailure {
                    throw failure
                }
                return AccountProfile(email: "ada@m16.example", name: "Ada", memberships: [])
            },
            devices: { () async throws(AccountError) -> [AccountDevice] in
                self.devices += 1
                return []
            }
        )
    }
}
