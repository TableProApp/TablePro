//
//  LicenseTierTests.swift
//  TablePro
//
//  Tests for LicenseTier and tier-aware feature gating
//

import Foundation
@testable import TablePro
import Testing

@Suite("LicenseTier")
struct LicenseTierTests {
    // MARK: - Parsing

    @Test("init(rawValue:) maps known tiers")
    func initMapsKnownTiers() {
        #expect(LicenseTier(rawValue: "starter") == .starter)
        #expect(LicenseTier(rawValue: "team") == .team)
    }

    @Test("init(rawValue:) is case insensitive")
    func initIsCaseInsensitive() {
        #expect(LicenseTier(rawValue: "STARTER") == .starter)
        #expect(LicenseTier(rawValue: "Team") == .team)
    }

    @Test("init(rawValue:) maps an unrecognized tier to unknown")
    func initMapsUnknownTier() {
        #expect(LicenseTier(rawValue: "enterprise") == .unknown("enterprise"))
    }

    @Test("An empty or blank tier is treated as starter, not a super-tier")
    func emptyTierIsStarter() {
        #expect(LicenseTier(rawValue: "") == .starter)
        #expect(LicenseTier(rawValue: "   ") == .starter)
        #expect(LicenseTier(rawValue: "").unlocks(.team) == false)
    }

    // MARK: - unlocks

    @Test("starter unlocks only starter features")
    func starterUnlocksStarterOnly() {
        #expect(LicenseTier.starter.unlocks(.starter) == true)
        #expect(LicenseTier.starter.unlocks(.team) == false)
    }

    @Test("team unlocks both starter and team features")
    func teamUnlocksEverything() {
        #expect(LicenseTier.team.unlocks(.starter) == true)
        #expect(LicenseTier.team.unlocks(.team) == true)
    }

    @Test("an unrecognized future tier unlocks every known feature")
    func unknownTierUnlocksEverything() {
        let future = LicenseTier(rawValue: "enterprise")
        #expect(future.unlocks(.starter) == true)
        #expect(future.unlocks(.team) == true)
    }

    // MARK: - resolveAccess

    /// This fork ships every feature unlocked, so the grid that used to map status and tier onto an
    /// access decision has one answer. These cases are the ones that used to be refusals: an
    /// expired license, a failed validation, a starter tier reaching for a team feature, and no
    /// license at all. Each of them is what a user of this build now gets instead.
    @Test(
        "Every status and tier combination grants access",
        arguments: [
            (LicenseStatus.active, LicenseTier.starter, LicenseTier.team),
            (.expired, .team, .starter),
            (.validationFailed, .team, .team),
            (.unlicensed, .starter, .starter),
            (.suspended, .team, .team),
            (.deactivated, .team, .team),
        ]
    )
    func everyCombinationGrantsAccess(status: LicenseStatus, tier: LicenseTier, required: LicenseTier) {
        #expect(LicenseManager.resolveAccess(status: status, tier: tier, requiredTier: required) == .available)
    }

    @Test("Every pro feature is available")
    func everyFeatureIsAvailable() {
        for feature in ProFeature.allCases {
            #expect(
                LicenseManager.resolveAccess(
                    status: .unlicensed,
                    tier: .starter,
                    requiredTier: feature.requiredTier
                ) == .available,
                Comment(rawValue: "\(feature) is gated")
            )
        }
    }

    // MARK: - ProFeature required tiers

    // MARK: - Invite code detection

    @Test("A dashed license key is recognized as a license key, not an invite code")
    func recognizesLicenseKeyFormat() {
        #expect(LicenseManager.isLicenseKey("ABCDE-FGHIJ-KLMNO-PQRST-UVWXY") == true)
        #expect(LicenseManager.isLicenseKey("abcde-fghij-klmno-pqrst-uvwxy") == true)
    }

    @Test("A random invite token is not treated as a license key")
    func recognizesInviteCode() {
        #expect(LicenseManager.isLicenseKey("aB3xZ9qK7mN2pL5rT8wY1cV4dF6gH0jS") == false)
        #expect(LicenseManager.isLicenseKey("ABCDE-FGHIJ") == false)
        #expect(LicenseManager.isLicenseKey("") == false)
    }

    @Test("Pro features require the starter tier; Team features require the team tier")
    func featureRequiredTiers() {
        #expect(ProFeature.iCloudSync.requiredTier == .starter)
        #expect(ProFeature.encryptedExport.requiredTier == .starter)
        #expect(ProFeature.envVarReferences.requiredTier == .starter)
        #expect(ProFeature.linkedFolders.requiredTier == .starter)
        #expect(ProFeature.queryInsights.requiredTier == .starter)
        #expect(ProFeature.resultCharts.requiredTier == .starter)
        #expect(ProFeature.compareSync.requiredTier == .starter)
        #expect(ProFeature.dataRewind.requiredTier == .starter)
        #expect(ProFeature.teamCatalog.requiredTier == .team)
        #expect(ProFeature.teamLibrary.requiredTier == .team)
    }
}
