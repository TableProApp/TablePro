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

    @Test("active starter license grants a starter feature")
    func activeStarterGrantsStarterFeature() {
        let access = LicenseManager.resolveAccess(status: .active, tier: .starter, requiredTier: .starter)
        #expect(access == .available)
    }

    @Test("active starter license is blocked from a team feature")
    func activeStarterBlockedFromTeamFeature() {
        let access = LicenseManager.resolveAccess(status: .active, tier: .starter, requiredTier: .team)
        #expect(access == .requiresUpgrade(.team))
    }

    @Test("active team license grants a team feature")
    func activeTeamGrantsTeamFeature() {
        let access = LicenseManager.resolveAccess(status: .active, tier: .team, requiredTier: .team)
        #expect(access == .available)
    }

    @Test("active team license grants a starter feature")
    func activeTeamGrantsStarterFeature() {
        let access = LicenseManager.resolveAccess(status: .active, tier: .team, requiredTier: .starter)
        #expect(access == .available)
    }

    @Test("expired license reports expired regardless of tier")
    func expiredReportsExpired() {
        let access = LicenseManager.resolveAccess(status: .expired, tier: .team, requiredTier: .starter)
        #expect(access == .expired)
    }

    @Test("validation failure reports validationFailed")
    func validationFailureReported() {
        let access = LicenseManager.resolveAccess(status: .validationFailed, tier: .team, requiredTier: .team)
        #expect(access == .validationFailed)
    }

    @Test("unlicensed and other inactive statuses report unlicensed")
    func inactiveStatusesReportUnlicensed() {
        #expect(LicenseManager.resolveAccess(status: .unlicensed, tier: .starter, requiredTier: .starter) == .unlicensed)
        #expect(LicenseManager.resolveAccess(status: .suspended, tier: .team, requiredTier: .team) == .unlicensed)
        #expect(LicenseManager.resolveAccess(status: .deactivated, tier: .team, requiredTier: .team) == .unlicensed)
    }

    @Test("an unrecognized future tier grants team features when active")
    func unknownTierGrantsTeamFeature() {
        let access = LicenseManager.resolveAccess(status: .active, tier: LicenseTier(rawValue: "enterprise"), requiredTier: .team)
        #expect(access == .available)
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
        #expect(ProFeature.teamCatalog.requiredTier == .team)
    }
}
