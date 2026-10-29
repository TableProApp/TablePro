//
//  FeatureAccessTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct FeatureAccessTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entitlement(features: Set<String>, expiresIn: TimeInterval = 3_600, licensed: Bool = true) -> Entitlement {
        Entitlement(
            token: "token",
            accountID: "acct_test",
            deviceID: "dev_test",
            machineID: "mid",
            features: features,
            licenses: licensed
                ? [EntitlementLicense(id: "lic", plan: "starter", cycle: "lifetime", source: "order",
                                      status: "active", renewsAt: nil, endsAt: nil, team: nil)]
                : [],
            email: "ada@m16.example",
            name: nil,
            issuedAt: now.addingTimeInterval(-60),
            notBefore: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(expiresIn),
            isOffline: false
        )
    }

    private static func resolve(_ state: AccountState, feature: ProFeature = .iCloudSync) -> ProFeatureAccess {
        FeatureAccess.resolve(feature, state: state, now: now)
    }

    @Test("The raw values are the server's feature codes")
    func rawValuesAreFeatureCodes() {
        #expect(ProFeature.allCases.map { $0.rawValue }.sorted() == [
            "compare_sync", "data_rewind", "encrypted_export", "env_var_references", "icloud_sync",
            "linked_folders", "query_insights", "result_charts", "team_catalog", "team_library"
        ])
    }

    @Test("A valid entitlement unlocks exactly the codes it carries")
    func validEntitlementGatesByCode() {
        let state = AccountState(isSignedIn: true, entitlement: Self.entitlement(features: ["icloud_sync"]))
        #expect(Self.resolve(state, feature: .iCloudSync) == .available)
        #expect(Self.resolve(state, feature: .teamLibrary) == .notIncluded)
    }

    @Test("A free account's entitlement carries no codes and locks every feature as not included")
    func freeAccountIsNotIncluded() {
        let state = AccountState(isSignedIn: true, entitlement: Self.entitlement(features: [], licensed: false))
        for feature in ProFeature.allCases {
            #expect(Self.resolve(state, feature: feature) == .notIncluded)
        }
    }

    @Test("No session and no entitlement is signed out")
    func nothingIsSignedOut() {
        #expect(Self.resolve(AccountState()) == .signedOut)
    }

    @Test("An entitlement past its exp that carried the code is expired, signed in or not")
    func lapsedEntitlementIsExpired() {
        let lapsed = Self.entitlement(features: ["icloud_sync"], expiresIn: -1)
        #expect(Self.resolve(AccountState(isSignedIn: true, entitlement: lapsed)) == .expired)
        #expect(Self.resolve(AccountState(isSignedIn: false, entitlement: lapsed)) == .expired)
    }

    @Test("Signed in without a valid entitlement, after a failed refresh, is refreshFailed")
    func failedRefreshIsRefreshFailed() {
        let state = AccountState(isSignedIn: true, refresh: .failed(.network("offline")))
        #expect(Self.resolve(state) == .refreshFailed)
    }

    @Test("A device over the limit stays on the free tier")
    func deviceLimitIsNotIncluded() {
        let state = AccountState(isSignedIn: true, refresh: .deviceLimitReached([]))
        #expect(Self.resolve(state) == .notIncluded)
    }

    @Test("An offline file works without a session")
    func offlineFileWorksSignedOut() {
        let state = AccountState(isSignedIn: false, entitlement: Self.entitlement(features: ["icloud_sync"]))
        #expect(Self.resolve(state) == .available)
    }

    @Test("A license an older build activated keeps its tier's features until it lapses")
    func legacyPayloadKeepsWorking() throws {
        let payload = LicensePayloadData(
            billingCycle: nil, licenseKey: "KEY", email: "ada@m16.example", status: "active",
            expiresAt: nil, issuedAt: "2027-01-01T00:00:00Z", tier: "starter"
        )
        let legacy = try #require(LegacyEntitlement(payload: payload))
        let state = AccountState(legacy: legacy)
        let inGrace = try #require(legacy.issuedAt).addingTimeInterval(86_400)
        #expect(FeatureAccess.resolve(.iCloudSync, state: state, now: inGrace) == .available)
        #expect(FeatureAccess.resolve(.teamLibrary, state: state, now: inGrace) == .notIncluded)

        let pastGrace = try #require(legacy.issuedAt).addingTimeInterval(LegacyEntitlement.gracePeriod + 1)
        #expect(FeatureAccess.resolve(.iCloudSync, state: state, now: pastGrace) == .expired)
    }

    @Test("A payload that is not active, or ran past its expiry, grants nothing")
    func legacyPayloadLapses() throws {
        let suspended = LicensePayloadData(
            billingCycle: nil, licenseKey: "KEY", email: "a@m16.example", status: "suspended",
            expiresAt: nil, issuedAt: "2026-01-01T00:00:00Z", tier: "team"
        )
        #expect(LegacyEntitlement(payload: suspended) == nil)

        let ended = LicensePayloadData(
            billingCycle: "yearly", licenseKey: "KEY", email: "a@m16.example", status: "active",
            expiresAt: "2026-01-02T00:00:00.000000Z", issuedAt: "2026-01-01T00:00:00Z", tier: "team"
        )
        let legacy = try #require(LegacyEntitlement(payload: ended))
        #expect(legacy.features == LegacyEntitlement.teamFeatures)
        #expect(!legacy.isValid(at: Date(timeIntervalSince1970: 1_767_400_000)))
    }

    @Test("Anyone holding a license, even a lapsed one, is a supporter")
    func supportAudience() {
        #expect(FeatureAccess.resolveSupportAudience(state: AccountState()) == .prospect)
        let free = AccountState(isSignedIn: true, entitlement: Self.entitlement(features: [], licensed: false))
        #expect(FeatureAccess.resolveSupportAudience(state: free) == .prospect)
        let lapsed = AccountState(entitlement: Self.entitlement(features: ["icloud_sync"], expiresIn: -1))
        #expect(FeatureAccess.resolveSupportAudience(state: lapsed) == .supporter)
    }

    @Test("Past the device limit the gates point at Settings instead of a purchase")
    @MainActor
    func pastDeviceLimit() {
        let access = FeatureAccess(state: AccountState(isSignedIn: true, refresh: .deviceLimitReached([])), now: { Self.now })
        #expect(access.isPastDeviceLimit)
        #expect(access.check(.iCloudSync) == .notIncluded)

        access.update(AccountState(isSignedIn: true, refresh: .failed(.network("offline"))))
        #expect(!access.isPastDeviceLimit)
    }
}
