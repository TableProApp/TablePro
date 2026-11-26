//
//  FeatureAccessTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct FeatureAccessTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entitlement(licensed: Bool = true) -> Entitlement {
        Entitlement(
            accountID: "acct_test",
            features: ["icloud_sync"],
            licenses: licensed
                ? [EntitlementLicense(id: "lic", plan: "starter", cycle: "lifetime", source: "order",
                                      status: "active", renewsAt: nil, endsAt: nil, team: nil)]
                : [],
            email: "ada@m16.example",
            name: nil,
            expiresAt: now.addingTimeInterval(3_600),
            isOffline: false
        )
    }

    @Test("The raw values are the server's feature codes")
    func rawValuesAreFeatureCodes() {
        #expect(ProFeature.allCases.map { $0.rawValue }.sorted() == [
            "compare_sync", "data_rewind", "encrypted_export", "env_var_references", "icloud_sync",
            "linked_folders", "query_insights", "result_charts", "service_sync", "team_catalog", "team_library"
        ])
    }

    @Test("Each gate is the core's answer for the feature")
    func gateIsTheCoresAnswer() {
        let state = AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement(),
            features: [.iCloudSync: .available, .teamLibrary: .notIncluded, .dataRewind: .expired]
        )
        #expect(FeatureAccess.resolve(.iCloudSync, state: state) == .available)
        #expect(FeatureAccess.resolve(.teamLibrary, state: state) == .notIncluded)
        #expect(FeatureAccess.resolve(.dataRewind, state: state) == .expired)
    }

    @Test("A feature the core gave no answer for reads as signed out, or as a failed check when signed in")
    func missingAnswer() {
        #expect(FeatureAccess.resolve(.iCloudSync, state: AccountState()) == .signedOut)
        #expect(FeatureAccess.resolve(.iCloudSync, state: AccountState(isSignedIn: true)) == .refreshFailed)
    }

    @Test("Anyone holding a license, even a lapsed one, is a supporter")
    func supporters() {
        #expect(FeatureAccess.resolveSupportAudience(state: AccountState(entitlement: Self.entitlement())) == .supporter)
        #expect(FeatureAccess.resolveSupportAudience(state: AccountState(entitlement: Self.entitlement(licensed: false))) == .prospect)
        #expect(FeatureAccess.resolveSupportAudience(state: AccountState()) == .prospect)
    }

    @Test("Someone on a company server is never asked to buy: the organization's license covers them")
    func companyServerIsCovered() {
        let state = AccountState(server: AccountSettingsContentTests.companyServer)
        #expect(FeatureAccess.resolveSupportAudience(state: state) == .supporter)
    }

    @Test("Past the device limit the gates point at Settings instead of a purchase")
    @MainActor
    func deviceLimit() {
        let access = FeatureAccess(state: AccountState(
            isSignedIn: true,
            refresh: .deviceLimitReached([]),
            features: [.iCloudSync: .notIncluded]
        ))
        #expect(access.isPastDeviceLimit)
        #expect(LicensePresentation.gate(for: .iCloudSync, state: access.state)?.action == .openAccountSettings(page: .accountDevices))
    }
}
