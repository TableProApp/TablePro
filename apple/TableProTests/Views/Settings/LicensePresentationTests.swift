//
//  LicensePresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct LicensePresentationTests {
    private static let now = AccountSettingsContentTests.now
    private static let day = AccountSettingsContentTests.day

    private static func entitlement(
        features: Set<String> = Set(ProFeature.allCases.map(\.rawValue)),
        licenses: [EntitlementLicense] = [AccountSettingsContentTests.license()],
        expiresAt: Date = now.addingTimeInterval(14 * day),
        isOffline: Bool = false
    ) -> Entitlement {
        Entitlement(
            token: "token", accountID: "acct_test", deviceID: "dev_this", machineID: AccountSettingsContentTests.machineID,
            features: features, licenses: licenses, email: "ada@m16.example", name: "Ada",
            issuedAt: now.addingTimeInterval(-20 * day), notBefore: now.addingTimeInterval(-20 * day),
            expiresAt: expiresAt, isOffline: isOffline
        )
    }

    private static func gate(_ feature: ProFeature, _ state: AccountState) -> LicenseNotice? {
        LicensePresentation.gate(for: feature, state: state, now: now)
    }

    private static func paneNotices(_ state: AccountState) -> [AccountSettingsContent.Notice] {
        AccountSettingsContentTests.make(state).notices
    }

    private static func welcomeLine(_ state: AccountState) -> LicenseNotice? {
        LicensePresentation.welcomeLine(state: state, configuration: AccountSettingsContentTests.configuration, now: now)
    }

    private static func legacy(expiresAt: String?, issuedAt: String) throws -> LegacyEntitlement {
        let payload = LicensePayloadData(
            billingCycle: nil, licenseKey: "KEY", email: "ada@m16.example", status: "active",
            expiresAt: expiresAt, issuedAt: issuedAt, tier: "starter"
        )
        return try #require(LegacyEntitlement(payload: payload))
    }

    // MARK: - Gates

    @Test("An available feature has no gate")
    func availableHasNoGate() {
        let state = AccountState(isSignedIn: true, entitlement: Self.entitlement())
        #expect(Self.gate(.compareSync, state) == nil)
    }

    @Test("Signed out names a paid plan and offers sign-in, with the purchase beside it")
    func signedOutGate() {
        let gate = Self.gate(.linkedFolders, AccountState())
        #expect(gate?.title == ProFeature.linkedFolders.paidPlanRequirement)
        #expect(gate?.message == ProFeature.linkedFolders.featureDescription)
        #expect(gate?.action == .signIn)
        #expect(gate?.alternative == .purchase)
    }

    @Test("An account without the feature is offered the upgrade")
    func upgradeGate() {
        let free = AccountState(isSignedIn: true, entitlement: Self.entitlement(features: [], licenses: []))
        let gate = Self.gate(.teamLibrary, free)
        #expect(gate?.title == ProFeature.teamLibrary.paidPlanRequirement)
        #expect(gate?.action == .upgrade)
        #expect(gate?.alternative == nil)
    }

    @Test("Past the device limit the gate opens Settings instead of selling the plan this account holds")
    func deviceLimitGate() {
        let gate = Self.gate(.compareSync, AccountState(isSignedIn: true, refresh: .deviceLimitReached([])))
        #expect(gate?.action == .openAccountSettings)
        #expect(gate?.title != ProFeature.compareSync.paidPlanRequirement)
    }

    @Test("A lapsed check reads as Settings > Account says it and offers the check")
    func lapsedEntitlementMatchesThePane() throws {
        let state = AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(-Self.day)),
            refresh: .failed(.network("offline"))
        )
        let pane = try #require(Self.paneNotices(state).first)

        #expect(Self.gate(.dataRewind, state) == LicensePresentation.notice(pane))
        #expect(Self.gate(.dataRewind, state)?.action == .retryValidation)
    }

    @Test("A lapsed offline file sends the person to Settings, where the file is imported")
    func lapsedOfflineFileOpensSettings() {
        let state = AccountState(entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(-Self.day), isOffline: true))
        let gate = Self.gate(.iCloudSync, state)
        #expect(gate?.title == AccountSettingsContent.Notice.expired(at: .now, isOfflineFile: true).title)
        #expect(gate?.action == .openAccountSettings)
    }

    @Test("Signed in with no entitlement after a failed refresh reads as the pane's failed check")
    func refreshFailedGate() {
        let gate = Self.gate(.queryInsights, AccountState(isSignedIn: true, refresh: .failed(.network("offline"))))
        #expect(gate?.title == AccountSettingsContent.Notice.verificationFailed(message: nil).title)
        #expect(gate?.action == .retryValidation)
    }

    @Test("A paying customer this Mac could not check is never sent to the pricing page", arguments: ProFeature.allCases)
    func payingCustomerIsNeverAskedToBuy(_ feature: ProFeature) {
        let states = [
            AccountState(isSignedIn: true, entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(-1))),
            AccountState(isSignedIn: true, refresh: .failed(.network("offline"))),
            AccountState(isSignedIn: true, refresh: .deviceLimitReached([])),
        ]
        for state in states {
            let gate = Self.gate(feature, state)
            #expect(gate != nil)
            #expect(gate?.action?.opensPricing == false)
            #expect(gate?.alternative == nil)
        }
    }

    @Test("A key from an older build past its end date is asked to renew; one only past its 30 days is checked")
    func legacyGates() throws {
        let ended = try Self.legacy(expiresAt: "2026-01-02T00:00:00Z", issuedAt: "2026-01-01T00:00:00Z")
        #expect(Self.gate(.iCloudSync, AccountState(legacy: ended))?.action == .renew)

        let unchecked = try Self.legacy(expiresAt: nil, issuedAt: "2026-01-01T00:00:00Z")
        #expect(Self.gate(.iCloudSync, AccountState(legacy: unchecked))?.action == .retryValidation)
    }

    // MARK: - Welcome line

    @Test("Welcome says nothing about a working plan, a free account or a key an older build left")
    func welcomeQuietWhenNothingIsNeeded() throws {
        #expect(Self.welcomeLine(AccountState(isSignedIn: true, entitlement: Self.entitlement())) == nil)
        #expect(Self.welcomeLine(AccountState(isSignedIn: true, entitlement: Self.entitlement(features: [], licenses: []))) == nil)
        let legacy = try Self.legacy(expiresAt: nil, issuedAt: "2026-10-30T00:00:00Z")
        #expect(Self.welcomeLine(AccountState(legacy: legacy)) == nil)
    }

    @Test("Welcome offers sign-in to a Mac with no account")
    func welcomeOffersSignIn() {
        #expect(Self.welcomeLine(AccountState())?.action == .signIn)
    }

    @Test("Welcome carries the pane's notice, the expiry warning and a failed check included")
    func welcomeCarriesThePaneNotice() throws {
        let states = [
            AccountState(isSignedIn: true, entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(Self.day))),
            AccountState(isSignedIn: true, entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(-Self.day))),
            AccountState(isSignedIn: true, refresh: .failed(.network("offline"))),
            AccountState(isSignedIn: true, refresh: .deviceLimitReached([])),
            AccountState(isSignedIn: true, entitlement: Self.entitlement(licenses: [AccountSettingsContentTests.license(status: "past_due")])),
        ]
        for state in states {
            let pane = try #require(Self.paneNotices(state).first)
            #expect(Self.welcomeLine(state) == LicensePresentation.notice(pane))
        }
    }

    @Test("A plan the person is canceling stays in Settings")
    func welcomeSkipsCanceling() {
        let canceling = AccountSettingsContentTests.license(status: "canceling", endsAt: Self.now.addingTimeInterval(30 * Self.day))
        let state = AccountState(isSignedIn: true, entitlement: Self.entitlement(licenses: [canceling]), refresh: .succeeded(Self.now))
        #expect(!Self.paneNotices(state).isEmpty)
        #expect(Self.welcomeLine(state) == nil)
    }

    // MARK: - Check failure

    @Test("Only a failed check has a reason to show")
    func checkFailureMessage() {
        #expect(LicensePresentation.checkFailureMessage(.failed(.network("offline"))) == AccountError.network("offline").friendlyDescription)
        #expect(LicensePresentation.checkFailureMessage(.succeeded(Self.now)) == nil)
        #expect(LicensePresentation.checkFailureMessage(.idle) == nil)
    }
}
