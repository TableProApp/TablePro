//
//  AccountServicesTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport
import Testing

@MainActor
struct AccountServicesTests {
    @Test("Sign-in registers this Mac, refreshes so the token names it, then fetches and stores the entitlement")
    func signInRegistersRefreshesAndFetches() async throws {
        let fixture = try AccountFixture()

        try await fixture.signIn()

        let paths = await fixture.server.requests.map { "\($0.method) \($0.path) \($0.form["grant_type"] ?? "")" }
        #expect(paths == [
            "POST /oauth/token authorization_code",
            "POST /devices ",
            "POST /oauth/token refresh_token",
            "POST /devices/\(FakeAccountServer.deviceID)/entitlement "
        ])
        let registration = try #require(await fixture.server.requests(to: "/devices").first)
        #expect(registration.json == [
            "machine_id": FakeAccountServer.machine.machineID, "platform": "macos", "name": "Test Mac",
            "app_version": "2.0.0", "os_version": "26.1"
        ])
        #expect(registration.authorization?.hasPrefix("Bearer ") == true)
        let entitlementRequest = try #require(
            await fixture.server.requests(to: "/devices/\(FakeAccountServer.deviceID)/entitlement").first
        )
        #expect(entitlementRequest.json == ["app_version": "2.0.0", "os_version": "26.1"])

        #expect(fixture.access.state.isSignedIn)
        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(fixture.access.check(.teamLibrary) == .notIncluded)
        #expect(fixture.access.state.entitlement?.email == "ada@m16.example")
        #expect(FileManager.default.fileExists(atPath: fixture.entitlementFile.path))
    }

    @Test("A stored entitlement is read back on launch, offline, and keeps its features until it expires")
    func storedEntitlementSurvivesRelaunchOffline() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        await fixture.server.set { $0.isOffline = true }

        let relaunched = FeatureAccess()
        let state = AccountState(
            isSignedIn: true,
            entitlement: EntitlementStore(
                fileURL: fixture.entitlementFile,
                verifier: EntitlementVerifier(publicKeys: [fixture.server.publicKey]),
                machine: FakeAccountServer.machine,
                now: { Date() }
            ).load()
        )
        relaunched.update(state)
        #expect(relaunched.isAvailable(.iCloudSync))

        let outcome = await fixture.services.refreshEntitlement()
        guard case .failed(.network) = outcome else {
            Issue.record("Expected a network failure, got \(outcome)")
            return
        }
        #expect(fixture.access.isAvailable(.iCloudSync), "A failed refresh never drops a valid token")
    }

    @Test("Stored state loads from disk and the Keychain with no network call")
    func storedStateLoadsWithoutNetwork() async throws {
        let fixture = try AccountFixture()
        try FileManager.default.createDirectory(at: fixture.entitlementFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(await fixture.server.signedEntitlement().utf8).write(to: fixture.entitlementFile)
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey, tier: "team")

        fixture.services.loadStoredState()

        #expect(await fixture.server.requests.isEmpty)
        #expect(fixture.access.state.entitlement?.email == "ada@m16.example")
        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(fixture.access.isAvailable(.teamLibrary), "The legacy Team payload still counts until it is migrated")
    }

    @Test("A stored entitlement whose signature no longer verifies is dropped")
    func tamperedEntitlementIsDropped() throws {
        let fixture = try AccountFixture()
        let otherKey = Curve25519.Signing.PrivateKey()
        let forged = FakeAccountServer.sign(claims: [
            "aud": "tablepro-app", "sub": "acct_test", "iat": 0, "nbf": 0, "exp": 4_000_000_000,
            "dev": "dev_x", "mid": FakeAccountServer.machine.machineID, "features": ["icloud_sync"]
        ], key: otherKey, header: [
            "alg": "EdDSA", "kid": EntitlementVerifier.keyID(of: fixture.server.publicKey), "typ": "tablepro-entitlement+jwt"
        ])
        try FileManager.default.createDirectory(at: fixture.entitlementFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(forged.utf8).write(to: fixture.entitlementFile)

        fixture.services.loadStoredState()

        #expect(fixture.access.state.entitlement == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.entitlementFile.path))
    }

    @Test("A 401 refreshes the access token once and sends the request again with the new one")
    func unauthorizedRefreshesAndRetries() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let before = await fixture.server.requests.count
        await fixture.server.set { $0.unauthorizedOnce = true }

        let outcome = await fixture.services.refreshEntitlement()

        guard case .succeeded = outcome else {
            Issue.record("Expected a refreshed entitlement, got \(outcome)")
            return
        }
        let calls = await Array(fixture.server.requests.dropFirst(before))
        let entitlementPath = "/devices/\(FakeAccountServer.deviceID)/entitlement"
        #expect(calls.map { "\($0.method) \($0.path) \($0.form["grant_type"] ?? "")" } == [
            "POST \(entitlementPath) ",
            "POST /oauth/token refresh_token",
            "POST \(entitlementPath) "
        ])
        #expect(calls.first?.authorization != calls.last?.authorization)
        #expect(calls.last?.json == ["app_version": "2.0.0", "os_version": "26.1"])
    }

    @Test("The schedule refreshes 24 hours after a success and an hour after a failure")
    func scheduleRefreshes() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let entitlementPath = "/devices/\(FakeAccountServer.deviceID)/entitlement"
        defer { fixture.services.stop() }

        fixture.services.start()
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.server.requests(to: entitlementPath).count == 2)

        fixture.clock.advance(by: AccountServices.refreshInterval - .seconds(1))
        #expect(fixture.clock.pendingSleeperCount == 1)
        await fixture.server.set { $0.isOffline = true }
        fixture.clock.advance(by: .seconds(1))
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.server.requests(to: entitlementPath).count == 3)
        guard case .failed = fixture.access.state.refresh else {
            Issue.record("Expected a failed refresh, got \(fixture.access.state.refresh)")
            return
        }

        await fixture.server.set { $0.isOffline = false }
        fixture.clock.advance(by: AccountServices.retryInterval - .seconds(1))
        #expect(fixture.clock.pendingSleeperCount == 1)
        fixture.clock.advance(by: .seconds(1))
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.server.requests(to: entitlementPath).count == 4)
        guard case .succeeded = fixture.access.state.refresh else {
            Issue.record("Expected a refreshed entitlement, got \(fixture.access.state.refresh)")
            return
        }
    }

    @Test("device_limit_reached leaves the app on the free tier and keeps the devices that hold the slots")
    func deviceLimitReached() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set { $0.deviceLimitReached = true }

        try await fixture.signIn()

        guard case .deviceLimitReached(let holders) = fixture.access.state.refresh else {
            Issue.record("Expected device_limit_reached, got \(fixture.access.state.refresh)")
            return
        }
        #expect(holders.map { $0.name } == ["Workstation"])
        #expect(fixture.access.check(.iCloudSync) == .notIncluded)
    }

    @Test("A removed device signs this Mac out and keeps its entitlement until it expires")
    func revokedDeviceSignsOut() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        await fixture.server.set { $0.deviceRevoked = true }

        await fixture.services.refreshEntitlement()

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.access.isAvailable(.iCloudSync))
    }

    @Test("Sign-out revokes, forgets the entitlement and leaves every feature signed out")
    func signOutClearsEverything() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()

        await fixture.services.signOut()

        #expect(await fixture.server.requests(to: "/oauth/revoke").count == 1)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: fixture.entitlementFile.path))
    }

    @Test("A refresh that answers after sign-out stores nothing and leaves the features signed out")
    func signOutDuringRefresh() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        let gate = AsyncGate()
        await fixture.server.set { $0.entitlementGate = gate }

        let refresh = Task { await fixture.services.refreshEntitlement() }
        await gate.arrived(1)
        await fixture.services.signOut()
        await gate.open()
        _ = await refresh.value

        #expect(!fixture.access.state.isSignedIn)
        #expect(fixture.access.state.entitlement == nil)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: fixture.entitlementFile.path))
    }

    @Test("An offline file is checked like an online token and works without signing in")
    func offlineFileImport() async throws {
        let fixture = try AccountFixture()
        let directory = fixture.entitlementFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-abababababab.jwt")
        try Data(await fixture.server.signedEntitlement(offline: true).utf8).write(to: file)

        try await fixture.services.importOfflineFile(at: file)

        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(fixture.access.state.entitlement?.isOffline == true)
    }

    @Test("An offline file made for another machine is refused")
    func offlineFileForAnotherMachine() async throws {
        let fixture = try AccountFixture()
        let directory = fixture.entitlementFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tablepro-offline-000000000000.jwt")
        let token = await fixture.server.signedEntitlement(machineID: String(repeating: "0", count: 64), offline: true)
        try Data(token.utf8).write(to: file)

        await #expect(throws: AccountError.entitlementRejected(.machine)) {
            try await fixture.services.importOfflineFile(at: file)
        }
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
    }

    @Test("A stored license key is exchanged, the device registered without a refresh, then the key and payload deleted")
    func legacyKeyMigrates() async throws {
        let fixture = try AccountFixture()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)

        let outcome = await fixture.services.migrateLegacyKeyIfNeeded()

        #expect(outcome == .migrated)
        let paths = await fixture.server.requests.map { "\($0.method) \($0.path) \($0.form["grant_type"] ?? "")" }
        #expect(paths == [
            "POST /oauth/token \(OAuthTokenClient.tokenExchangeGrant)",
            "POST /devices ",
            "POST /devices/\(FakeAccountServer.deviceID)/entitlement "
        ])
        #expect(!fixture.hasLegacyLicense)
        #expect(fixture.access.state.isSignedIn)
        #expect(fixture.access.isAvailable(.iCloudSync))
    }

    @Test("The key in the signed payload is exchanged when the Keychain no longer holds one")
    func legacyKeyFromPayload() async throws {
        let fixture = try AccountFixture()
        try fixture.storeLegacyLicense(key: nil)

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .migrated)
        let exchange = try #require(await fixture.server.requests(to: "/oauth/token").first)
        #expect(exchange.form["subject_token"] == FakeAccountServer.validKey)
    }

    @Test("Without network the old payload keeps working and the key stays for a retry")
    func legacyKeyOffline() async throws {
        let fixture = try AccountFixture()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        await fixture.server.set { $0.isOffline = true }
        fixture.services.loadStoredState()

        let outcome = await fixture.services.migrateLegacyKeyIfNeeded()

        guard case .retryLater = outcome else {
            Issue.record("Expected a retry, got \(outcome)")
            return
        }
        #expect(fixture.hasLegacyLicense)
        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(fixture.access.check(.teamLibrary) == .notIncluded)

        await fixture.server.set { $0.isOffline = false }
        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .migrated)
        #expect(!fixture.hasLegacyLicense)
    }

    @Test("A key exchange whose registration failed finishes on the next run without a second exchange")
    func legacyKeyResumesAfterFailedRegistration() async throws {
        let fixture = try AccountFixture()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)
        await fixture.server.set { $0.refusesRegistration = true }

        guard case .retryLater = await fixture.services.migrateLegacyKeyIfNeeded() else {
            Issue.record("Expected a retry")
            return
        }
        #expect(fixture.hasLegacyLicense)

        await fixture.server.set { $0.refusesRegistration = false }
        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .migrated)
        let exchanges = await fixture.server.requests(to: "/oauth/token")
            .filter { $0.form["grant_type"] == OAuthTokenClient.tokenExchangeGrant }
        #expect(exchanges.count == 1)
        #expect(!fixture.hasLegacyLicense)
    }

    @Test("A key stored beside an interactive sign-in is neither exchanged nor deleted")
    func legacyKeyBesideInteractiveSession() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()
        try fixture.storeLegacyLicense(key: FakeAccountServer.validKey)

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keptWhileSignedIn)

        let exchanges = await fixture.server.requests(to: "/oauth/token")
            .filter { $0.form["grant_type"] == OAuthTokenClient.tokenExchangeGrant }
        #expect(exchanges.isEmpty)
        #expect(fixture.hasLegacyLicense)
    }

    @Test("A key the server refuses is deleted and the app is signed out")
    func legacyKeyRejected() async throws {
        let fixture = try AccountFixture()
        try fixture.storeLegacyLicense(key: "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")
        fixture.services.loadStoredState()

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .keyRejected)
        #expect(!fixture.hasLegacyLicense)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
    }

    @Test("A payload whose signature fails grants nothing and is never exchanged")
    func unverifiedPayloadIsIgnored() async throws {
        struct Forged: Error {}
        let fixture = try AccountFixture(verifyLegacy: { _ in throw Forged() })
        try fixture.storeLegacyLicense(key: nil)
        fixture.services.loadStoredState()

        #expect(await fixture.services.migrateLegacyKeyIfNeeded() == .nothingToMigrate)
        #expect(fixture.access.check(.iCloudSync) == .signedOut)
    }
}
