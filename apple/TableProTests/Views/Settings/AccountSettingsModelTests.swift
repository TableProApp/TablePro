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
        #expect(model.content.devices?.first?.isThisDevice == true)
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
        let model = AccountSettingsModel(
            services: fixture.services, teamLibrary: { Self.idleTeamLibrary(fixture) }, askSignOut: { _ in .discard }
        )
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
            id: row.id, name: row.name, system: "", lastSeenAt: row.lastSeenAt, isThisDevice: false, offlineUntil: nil
        ))

        #expect(model.actionFailure?.message == AccountError.server(status: 409, code: "offline_file_active").deviceRemovalDescription)
        #expect(model.devices.value?.contains { $0.id == "dev_air" } == true)
    }

    @Test("Use License Key is refused while signed in; signed out it signs in and deletes the stored key it used")
    func useStoredLicenseKey() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        let model = AccountSettingsModel(services: fixture.services)
        #expect(fixture.services.storedLicenseKey == FakeAccountServer.validKey)

        let refused = await model.useLicenseKey(" \(FakeAccountServer.validKey) ")
        #expect(refused == AccountError.signOutFirst.licenseKeyDescription)
        #expect(fixture.hasLegacyLicense)
        await fixture.services.signOut()
        let failure = await model.useLicenseKey(" \(FakeAccountServer.validKey) ")

        #expect(failure == nil)
        #expect(!fixture.hasLegacyLicense)
        #expect(fixture.access.state.isSignedIn)
        #expect(fixture.access.isAvailable(.iCloudSync))
    }

    @Test("A key the server refuses leaves the Mac signed out and the key stored on it")
    func refusedLicenseKey() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        let model = AccountSettingsModel(services: fixture.services)

        let failure = await model.useLicenseKey("ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")

        #expect(failure == AccountError.oauth("invalid_grant", description: nil).licenseKeyDescription)
        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.hasLegacyLicense)
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
        let file = try FakeAccountBackend.offlineFile(
            in: Self.directory(), machineID: String(repeating: "0", count: 64), expiresAt: Date().addingTimeInterval(86_400)
        )
        let model = AccountSettingsModel(services: fixture.services)

        await model.importOfflineFile(at: file)

        #expect(model.actionFailure?.message == AccountError.offlineFileRejected(.otherMachine).offlineFileDescription)
        #expect(model.content.identity == .signedOut)
    }

    @Test("A valid offline file shows its account and plan without a session")
    func offlineFileImport() async throws {
        let fixture = try AccountFixture()
        let file = try FakeAccountBackend.offlineFile(
            in: Self.directory(), machineID: FakeAccountServer.machine.machineID, expiresAt: Date().addingTimeInterval(86_400)
        )
        let model = AccountSettingsModel(services: fixture.services)

        await model.importOfflineFile(at: file)

        #expect(model.actionFailure == nil)
        #expect(model.content.identity == .account(name: "Ada", email: "ada@m16.example", isSignedIn: false))
        #expect(model.content.verification?.isOfflineFile == true)
        #expect(model.content.plans.first?.title == "Pro")
        #expect(model.content.plans.first?.status == .lifetime)
    }

    @Test("An offline file imported while signed in keeps the sign-in and still reads as a file")
    func offlineFileImportWhileSignedIn() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let file = try FakeAccountBackend.offlineFile(
            in: Self.directory(), machineID: FakeAccountServer.machine.machineID, expiresAt: Date().addingTimeInterval(86_400)
        )
        let model = AccountSettingsModel(services: fixture.services)

        await model.importOfflineFile(at: file)

        #expect(model.actionFailure == nil)
        #expect(fixture.access.state.isSignedIn)
        #expect(model.content.verification?.isOfflineFile == true)
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
        let model = AccountSettingsModel(
            services: fixture.services, loader: loads.loader,
            teamLibrary: { Self.idleTeamLibrary(fixture) }, askSignOut: { _ in .discard }
        )

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

    @Test("Sign Out lists the edits the team has not taken; Cancel keeps the session and the edits")
    func signOutConfirmationNamesUnsentTeamChanges() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        let prompt = ScriptedSignOutPrompt([.cancel])
        let model = AccountSettingsModel(services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: prompt.ask)

        await model.signOut()

        #expect(prompt.asked == [AccountSignOutConfirmation(teamChanges: ["Orders"], removesOfflineFile: false)])
        #expect(prompt.asked.first?.discardsSomething == true)
        #expect(fixture.account.services.isSignedIn)
        #expect(engine.deletes == 0)
        #expect(engine.discards.isEmpty)
    }

    @Test("Upload and Sign Out runs a pass first and signs out once the team took everything; a failed one asks again with why")
    func uploadThenSignOut() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        engine.answerPasses(with: TeamConflictFixture.failure("sync.network"))
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        var asks = 0
        let prompt = ScriptedSignOutPrompt([.upload, .upload]) {
            asks += 1
            if asks == 2 { engine.answerPasses(with: nil) }
        }
        let model = AccountSettingsModel(services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: prompt.ask)

        await model.signOut()

        let failures = prompt.asked.map { $0.uploadFailure }
        #expect(failures == [nil, .offline])
        #expect(prompt.asked.last?.teamChanges == ["Orders"])
        #expect(engine.passes == 2)
        #expect(!fixture.account.services.isSignedIn)
        #expect(engine.deletes == 1, "The account's Team Library data goes once it signed out")
        #expect(model.actionFailure == nil)
    }

    @Test("Discard and Sign Out sends nothing and deletes the account's Team Library data once signed out")
    func discardThenSignOut() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        let model = AccountSettingsModel(
            services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: ScriptedSignOutPrompt([.discard]).ask
        )

        await model.signOut()

        #expect(!fixture.account.services.isSignedIn)
        #expect(engine.passes == 0)
        #expect(engine.deletes == 1)
        #expect(fixture.discarded.isEmpty)
    }

    @Test("A delete that fails after Sign Out says the data is still on this Mac")
    func failedDeleteIsReported() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.failDeletes(with: TeamConflictFixture.failure("sync.team_library.delete_failed"))
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        let model = AccountSettingsModel(
            services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: ScriptedSignOutPrompt([.discard]).ask
        )

        await model.signOut()

        #expect(!fixture.account.services.isSignedIn)
        #expect(model.actionFailure?.title == String(localized: "Team Library data is still on this Mac"))
    }

    @Test("Signed out another way while Sign Out asks: the question closes and the data stays with the account")
    func involuntarySignOutClosesTheQuestion() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        let prompt = ScriptedSignOutPrompt([], waitsUntilClosed: true)
        let model = AccountSettingsModel(
            services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: prompt.ask,
            closeSignOutQuestion: prompt.close
        )
        let signingOut = Task { await model.signOut() }
        try await waitUntil { prompt.asked.count == 1 }

        try await fixture.refuseRefresh()
        await signingOut.value

        #expect(prompt.closes == 1)
        #expect(!fixture.account.services.isSignedIn)
        #expect(fixture.engine.deletes == 0)
    }

    @Test("Signed out another way during Upload and Sign Out: nothing more is asked and the data stays with the account")
    func involuntarySignOutDuringUpload() async throws {
        let gate = AsyncGate()
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        engine.answerPasses(with: TeamConflictFixture.failure("sync.network"))
        engine.holdNextPass(at: gate)
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        let prompt = ScriptedSignOutPrompt([.upload, .upload])
        let model = AccountSettingsModel(services: fixture.account.services, teamLibrary: { fixture.library }, askSignOut: prompt.ask)
        let signingOut = Task { await model.signOut() }
        await gate.arrived(1)

        try await fixture.refuseRefresh()
        await gate.open()
        await signingOut.value

        #expect(prompt.asked.count == 1, "Nothing is asked of a sign-in that is gone")
        #expect(engine.deletes == 0)
        #expect(fixture.discarded.isEmpty)
    }

    // A Team Library that holds nothing, for an account fixture that has none.
    static func idleTeamLibrary(_ fixture: AccountFixture) -> TeamLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSettingsTests-\(UUID().uuidString)", isDirectory: true)
        return TeamLibrary(
            source: FakeTeamLibrarySource(FakeTeamLibraryEngine(teams: [])),
            account: fixture.services,
            legacy: TeamLibraryLegacyImport(
                flatDirectory: root.appendingPathComponent("TeamLibrary", isDirectory: true),
                legacyFile: root.appendingPathComponent("team_library.json"),
                cacheRoot: root.appendingPathComponent("TeamLibraryCache", isDirectory: true),
                defaults: fixture.defaults.defaults
            ),
            reportDiscarded: { _ in }
        )
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
        await model.refreshOnVisit()
        let checks = fixture.backend.refreshCount

        model.openPortal(fixture.services.portal.portalBilling)
        #expect(opened.urls == [fixture.services.portal.portalBilling])
        await model.refreshOnVisit()

        #expect(fixture.backend.refreshCount == checks + 1)
        #expect(loads.profile == 2)

        await model.refreshOnVisit()
        #expect(fixture.backend.refreshCount == checks + 1)
        #expect(loads.profile == 2)
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AccountSettingsModelTests-\(UUID().uuidString)")
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

// Sign Out's question, answered from a script; with `waitsUntilClosed` it waits until the model closes it.
@MainActor
final class ScriptedSignOutPrompt {
    private var answers: [AccountSignOutAnswer]
    private let waitsUntilClosed: Bool
    private let whileAsked: @MainActor () async -> Void
    private var waiting: CheckedContinuation<AccountSignOutAnswer, Never>?
    private(set) var asked: [AccountSignOutConfirmation] = []
    private(set) var closes = 0

    init(
        _ answers: [AccountSignOutAnswer],
        waitsUntilClosed: Bool = false,
        whileAsked: @escaping @MainActor () async -> Void = {}
    ) {
        self.answers = answers
        self.waitsUntilClosed = waitsUntilClosed
        self.whileAsked = whileAsked
    }

    func ask(_ confirmation: AccountSignOutConfirmation) async -> AccountSignOutAnswer {
        asked.append(confirmation)
        await whileAsked()
        guard waitsUntilClosed else { return answers.isEmpty ? .cancel : answers.removeFirst() }
        return await withCheckedContinuation { waiting = $0 }
    }

    func close() {
        closes += 1
        waiting?.resume(returning: .cancel)
        waiting = nil
    }
}
