//
//  AccountServicesTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport
import Testing

@MainActor
struct AccountServicesTests {
    @Test("Sign-in through the core publishes the account, its plan and the core's gate for every feature")
    func signInPublishesTheCoresState() async throws {
        let fixture = try AccountFixture()

        try await fixture.signIn()

        #expect(fixture.access.state.isSignedIn)
        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(fixture.access.check(.teamLibrary) == .notIncluded)
        #expect(fixture.access.state.entitlement?.email == "ada@m16.example")
        #expect(fixture.access.state.entitlement?.licenses.map(\.plan) == ["starter"])
        #expect(fixture.access.state.server == .production)
        #expect(fixture.access.state.verifiedAt != nil)
        if case .succeeded = fixture.access.state.refresh {} else {
            Issue.record("Expected a succeeded refresh, got \(fixture.access.state.refresh)")
        }
    }

    @Test("Closing the browser sheet signs nothing in")
    func canceledSignIn() async throws {
        let fixture = try AccountFixture()

        await #expect(throws: AccountError.canceled) {
            try await fixture.services.signIn(using: CancelingAuthenticator())
        }

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
    }

    @Test("A failed refresh keeps the entitlement it holds and reports the failure")
    func failedRefreshKeepsTheEntitlement() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        await fixture.server.set { $0.isOffline = true }

        let outcome = await fixture.services.refreshEntitlement()

        guard case .failed(.network) = outcome else {
            Issue.record("Expected a network failure, got \(outcome)")
            return
        }
        #expect(fixture.access.isAvailable(.iCloudSync), "A failed refresh never drops a valid entitlement")
        guard case .failed(.network) = fixture.access.state.refresh else {
            Issue.record("Expected the failure published, got \(fixture.access.state.refresh)")
            return
        }
    }

    @Test("device_limit_reached leaves the app on the free tier and keeps the devices that hold the slots")
    func deviceLimit() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.deviceLimitReached = true }

        try await fixture.signIn()

        #expect(fixture.access.isPastDeviceLimit)
        #expect(fixture.access.check(.iCloudSync) == .notIncluded)
        guard case .deviceLimitReached(let holders) = fixture.access.state.refresh else {
            Issue.record("Expected the device limit, got \(fixture.access.state.refresh)")
            return
        }
        #expect(holders.map(\.name) == ["Workstation"])
    }

    @Test("Sign-out leaves every feature signed out, sends signed out by the person, and sets a stored key aside")
    func signOut() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        var events: [AccountEvent] = []
        let subscription = fixture.services.events.sink { events.append($0) }
        defer { subscription.cancel() }

        await fixture.services.signOut()

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.access.state.entitlement == nil)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
        #expect(events == [.signedOut(.user)])
        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keptAside)
    }

    @Test("A sign-out the core makes on its own reaches the app with its cause")
    func signOutCausesFromTheCore() async throws {
        for (setting, cause) in [(Self.refusesRefresh, AccountSignOutCause.refreshRefused), (Self.revokesDevice, .deviceRevoked)] {
            let fixture = try AccountFixture()
            try await fixture.signIn()
            var events: [AccountEvent] = []
            let subscription = fixture.services.events.sink { events.append($0) }
            await fixture.server.set(setting)

            await fixture.services.refreshEntitlement()
            subscription.cancel()

            #expect(!fixture.access.state.isSignedIn, "\(cause)")
            #expect(events == [.signedOut(cause)], "\(cause)")
        }
    }

    @Test("A key an older build stored is exchanged once through the core, then deleted with its payload")
    func storedKeyIsExchanged() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        var events: [AccountEvent] = []
        let subscription = fixture.services.events.sink { events.append($0) }
        defer { subscription.cancel() }

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .migrated)

        #expect(fixture.access.state.isSignedIn)
        #expect(!fixture.hasLegacyLicense)
        #expect(events == [.signedIn(accountID: "acct_test", method: .migration)])
        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .nothingToMigrate)
    }

    @Test("A key only the cached payload still holds is exchanged; one cached on another Mac is not")
    func payloadKeyIsExchanged() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyPayload(key: FakeAccountServer.validKey)
        #expect(fixture.services.storedLicenseKey == FakeAccountServer.validKey)

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .migrated)
        #expect(!fixture.hasLegacyLicense)

        let other = try AccountFixture()
        other.storeLegacyPayload(key: FakeAccountServer.validKey, cachedOn: String(repeating: "0", count: 64))
        #expect(other.services.storedLicenseKey == nil)
        #expect(await other.services.migrateLegacyKeyIfNeeded() == .nothingToMigrate)
    }

    @Test("A key the server refuses is set aside: offered by Use License Key…, never exchanged on its own again")
    func refusedKeyIsSetAside() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: "NOT-A-KEY")

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keyRejected)

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.services.storedLicenseKey == "NOT-A-KEY")
        #expect(!fixture.services.hasLicenseKeyToExchange)
        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keptAside)
    }

    @Test("Without network a stored key stays for the next check")
    func offlineKeepsTheKey() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        await fixture.server.set { $0.isOffline = true }

        guard case .retryLater(.network) = await fixture.services.migrateLegacyKeyIfNeeded() else {
            Issue.record("Expected a retry")
            return
        }
        #expect(fixture.hasLegacyLicense)
        #expect(fixture.services.hasLicenseKeyToExchange)
    }

    @Test("A key stored beside a session is neither exchanged nor deleted")
    func keyBesideSessionIsKept() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        fixture.storeLegacyLicense(key: FakeAccountServer.otherValidKey)

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keptWhileSignedIn)
        #expect(fixture.hasLegacyLicense)
    }

    @Test("Use License Key… signs in with the key's account and deletes the stored key it matches")
    func useLicenseKey() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        await fixture.services.signOut()

        _ = try await fixture.services.useLicenseKey(" \(FakeAccountServer.validKey)\n")

        #expect(fixture.access.state.isSignedIn)
        #expect(!fixture.hasLegacyLicense)
    }

    @Test("A check started while another runs joins it, so a stored key is exchanged once")
    func concurrentChecksJoin() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        var events: [AccountEvent] = []
        let subscription = fixture.services.events.sink { events.append($0) }
        defer { subscription.cancel() }

        async let first = fixture.services.checkNow()
        async let second = fixture.services.checkNow()
        _ = await (first, second)

        #expect(events == [.signedIn(accountID: "acct_test", method: .migration)])
    }

    @Test("A stored key waits for the core to read the last run's sign-in, which keeps it from the exchange")
    func migrationWaitsForTheRestore() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        fixture.backend.restoreLater(fixture.backend.status())
        fixture.services.loadStoredState()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)

        let migration = Task { await fixture.services.migrateLegacyKeyIfNeeded() }
        try await waitUntil { fixture.backend.isWaitingForRestore }
        fixture.backend.finishRestore()

        #expect(await migration.value == .keptWhileSignedIn)
        #expect(fixture.keychain.readStringResult(forKey: StoredLicenseKey.keychainKey) == .found(FakeAccountServer.validKey))
    }

    @Test("A stored key the network kept from its exchange is tried again an hour later")
    func migrationRetriesHourly() async throws {
        let fixture = try AccountFixture()
        fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        await fixture.server.set { $0.isOffline = true }
        fixture.services.start()
        try await waitUntil { fixture.clock.pendingSleeperCount > 0 }
        #expect(!fixture.access.state.isSignedIn)

        await fixture.server.set { $0.isOffline = false }
        fixture.clock.advance(by: AccountServices.migrationRetryInterval)

        try await waitUntil { fixture.access.state.isSignedIn }
        #expect(fixture.keychain.readStringResult(forKey: StoredLicenseKey.keychainKey) == .notFound)
        fixture.services.stop()
    }

    @Test("The gate follows the entitlement's expiry without another call to the core")
    func gateLapsesAtExpiry() async throws {
        let clock = TestNow(Date(timeIntervalSince1970: 1_800_000_000))
        let fixture = try AccountFixture(now: { clock.value })
        try await fixture.signIn()
        #expect(fixture.access.isAvailable(.iCloudSync))

        await fixture.clock.waitUntilSleeping()
        clock.value = clock.value.addingTimeInterval(15 * 24 * 60 * 60)
        fixture.clock.advance(by: .seconds(15 * 24 * 60 * 60))

        try await waitUntil { fixture.access.check(.iCloudSync) == .expired }
    }

    @Test("Past a company license's grace the gate keeps only the Team Library, without another call to the core")
    func gateFollowsTheLicenseGrace() async throws {
        let clock = TestNow(Date(timeIntervalSince1970: 1_800_000_000))
        let fixture = try AccountFixture(now: { clock.value })
        await fixture.server.set { $0.features = ["icloud_sync", "team_library"] }
        fixture.backend.installLicense(AccountServerLicense(
            seats: 25, isTrial: false, expiresAt: clock.value.addingTimeInterval(24 * 60 * 60),
            graceEndsAt: clock.value.addingTimeInterval(3 * 24 * 60 * 60), state: .active
        ))
        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)
        try await fixture.signIn()
        #expect(fixture.access.isAvailable(.iCloudSync))

        await fixture.clock.waitUntilSleeping()
        clock.value = clock.value.addingTimeInterval(3 * 24 * 60 * 60)
        fixture.clock.advance(by: .seconds(3 * 24 * 60 * 60))

        try await waitUntil { fixture.access.check(.iCloudSync) == .expired }
        #expect(fixture.access.isAvailable(.teamLibrary))
    }

    // MARK: - Company server

    @Test("Choosing a company server publishes it and signs out of the server left, with that cause")
    func chooseCompanyServer() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        var events: [AccountEvent] = []
        let subscription = fixture.services.events.sink { events.append($0) }
        defer { subscription.cancel() }

        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.access.state.server.host == "tablepro.example.com")
        #expect(!fixture.access.state.server.isProduction)
        #expect(fixture.services.portal.accountURL.host == "tablepro.example.com")
        #expect(events == [.signedOut(.serverChanged)])
    }

    @Test("A managed server cannot be changed, and the refusal says the organization manages it")
    func managedServerIsLocked() async throws {
        let fixture = try AccountFixture()
        let managed = AccountServer(
            apiOrigin: URL(string: "https://tablepro.corp.example")!,
            accountOrigin: URL(string: "https://tablepro.corp.example")!,
            host: "tablepro.corp.example",
            isProduction: false,
            isManaged: true,
            othersAllowed: false
        )
        fixture.backend.manage(managed)
        fixture.services.loadStoredState()

        await #expect(throws: AccountError.companyServer(.managed)) {
            try await fixture.services.chooseServer(nil)
        }
        #expect(fixture.access.state.server == managed)
    }

    @Test("A company server's license is published with the server")
    func companyServerLicense() async throws {
        let fixture = try AccountFixture()
        let license = AccountServerLicense(
            seats: 25, isTrial: false, expiresAt: Date(timeIntervalSince1970: 1_900_000_000), graceEndsAt: nil, state: .active
        )
        fixture.backend.installLicense(license)

        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)

        #expect(fixture.access.state.serverLicense == license)
    }

    // MARK: - The bearer

    @Test("The Swift clients send the core's access token to the server the core signs in to")
    func clientsUseTheCoresBearerAndServer() async throws {
        let fixture = try AccountFixture()
        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)
        try await fixture.signIn()

        _ = try await fixture.services.api.getMe()

        let request = try #require(await fixture.server.requests(to: "/me").last)
        #expect(request.baseURL == URL(string: "https://tablepro.example.com/v2"))
        let token = try #require(request.authorization?.replacingOccurrences(of: "Bearer ", with: ""))
        #expect(Self.claims(of: token)["sub"] as? String == "acct_test")
    }

    @Test("A 401 tells the core its token was refused and sends the request again with a new one")
    func unauthorizedRetriesOnce() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        await fixture.server.set { $0.unauthorizedOnce = true }

        _ = try await fixture.services.api.getMe()

        let calls = await fixture.server.requests(to: "/me")
        #expect(calls.count == 2)
        let refused = try #require(calls.first?.authorization?.replacingOccurrences(of: "Bearer ", with: ""))
        #expect(fixture.backend.tokensRejected == [refused])
        #expect(calls.first?.authorization != calls.last?.authorization)
    }

    @Test("A 401 that comes back after a switch to another server is not sent again, to either server")
    func unauthorizedAfterServerSwitchIsNotRetried() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        await fixture.server.set { $0.unauthorizedOnce = true }
        fixture.backend.onTokenRejected = { backend in
            backend.switchServerKeepingTheSession(to: FakeAccountBackend.companyServer)
        }

        await #expect(throws: (any Error).self) {
            _ = try await fixture.services.api.getMe()
        }

        let calls = await fixture.server.requests(to: "/me")
        #expect(calls.count == 1)
        #expect(calls.first?.baseURL == AccountServer.production.apiBaseURL)
    }

    @Test("Shared links stay on tablepro.app: signed in to a company server, a share is refused before anything is sent")
    func sharesNeverReachACompanyServer() async throws {
        let fixture = try AccountFixture()
        try await fixture.services.chooseServer(URL(string: "https://tablepro.example.com")!)
        try await fixture.signIn()
        let draft = ShareDraft(
            kind: .query, sql: "SELECT 1", title: "Q", note: nil, dialect: "PostgreSQL", expiry: .sevenDays,
            hidesSQL: false, allowsDownload: nil, password: "secret", teamID: nil, snapshot: nil
        )

        await #expect(throws: ShareFailure.signedOut) { try await fixture.services.shares.limits() }
        await #expect(throws: ShareFailure.signedOut) { try await fixture.services.shares.create(draft) }
        await #expect(throws: ShareFailure.signedOut) { try await fixture.services.shares.liveLinks(teamID: nil) }

        #expect(await fixture.server.requests.filter { $0.path.hasPrefix("/shares") }.isEmpty)
    }

    @Test("Signed out, the Swift clients send nothing")
    func signedOutSendsNothing() async throws {
        let fixture = try AccountFixture()

        await #expect(throws: (any Error).self) {
            _ = try await fixture.services.api.getMe()
        }
        #expect(await fixture.server.requests.isEmpty)
    }

    // MARK: - Helpers

    private static let refusesRefresh: @Sendable (isolated FakeAccountServer) -> Void = { $0.refusesRefresh = true }
    private static let revokesDevice: @Sendable (isolated FakeAccountServer) -> Void = { $0.deviceRevoked = true }

    private static func claims(of token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }
}

@MainActor
private struct CancelingAuthenticator: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        throw .canceled
    }
}

private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var value: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
