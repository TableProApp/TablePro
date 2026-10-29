//
//  AccountSettingsContentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AccountSettingsContentTests {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let day: TimeInterval = 24 * 60 * 60
    static let machineID = String(repeating: "ab", count: 32)
    static let configuration = AccountConfiguration(
        accountURL: URL(string: "http://account.localhost:5284")!,
        apiURL: URL(string: "http://api.localhost:5284")!,
        entitlementKeys: []
    )

    static func license(
        id: String = "lic_1",
        plan: String = "starter",
        cycle: String = "lifetime",
        source: String = "order",
        status: String = "active",
        endsAt: Date? = nil,
        team: EntitlementLicense.Team? = nil
    ) -> EntitlementLicense {
        EntitlementLicense(id: id, plan: plan, cycle: cycle, source: source, status: status, endsAt: endsAt, team: team)
    }

    static func entitlement(
        _ licenses: [EntitlementLicense] = [license()],
        issuedAt: Date = now.addingTimeInterval(-2 * 60 * 60),
        expiresAt: Date = now.addingTimeInterval(14 * day),
        isOffline: Bool = false
    ) -> Entitlement {
        Entitlement(
            token: "token", accountID: "acct_test", deviceID: "dev_this", machineID: machineID,
            features: ["icloud_sync"], licenses: licenses, email: "ada@m16.example", name: "Ada",
            issuedAt: issuedAt, notBefore: issuedAt, expiresAt: expiresAt, isOffline: isOffline
        )
    }

    static func make(
        _ state: AccountState,
        profile: AccountProfile? = nil,
        devices: [AccountDevice]? = nil,
        hasLegacyLicense: Bool = false
    ) -> AccountSettingsContent {
        AccountSettingsContent.make(
            state: state,
            profile: profile,
            devices: devices,
            hasLegacyLicense: hasLegacyLicense,
            machineID: machineID,
            configuration: configuration,
            now: now
        )
    }

    @Test("Signed out shows sign-in and the offline tools, and nothing about a plan, devices or teams")
    func signedOut() {
        let content = Self.make(AccountState())

        #expect(content.identity == .signedOut)
        #expect(!content.showsPlan)
        #expect(!content.showsDevices)
        #expect(content.teams == nil)
        #expect(content.notices.isEmpty)
        #expect(content.verification == nil)
        #expect(!content.canRefresh)
        #expect(content.machineID == Self.machineID)
    }

    @Test("A key from an older build that is not exchanged yet shows as a license key, and Refresh retries it")
    func pendingLicenseKey() throws {
        let payload = LicensePayloadData(
            billingCycle: nil, licenseKey: "KEY", email: "ada@m16.example", status: "active", expiresAt: nil,
            issuedAt: "2026-10-20T00:00:00Z", tier: "starter"
        )
        let legacy = try #require(LegacyEntitlement(payload: payload))
        let content = Self.make(AccountState(legacy: legacy), hasLegacyLicense: true)

        #expect(content.identity == .licenseKey(isValid: legacy.isValid(at: Self.now)))
        #expect(content.canRefresh)
    }

    @Test("A lifetime Starter license reads as Starter with a Lifetime status, owned personally, with the personal billing page")
    func starterLifetime() throws {
        let content = Self.make(AccountState(isSignedIn: true, entitlement: Self.entitlement(), refresh: .succeeded(Self.now)))

        #expect(content.identity == .account(name: "Ada", email: "ada@m16.example", isSignedIn: true))
        let plan = try #require(content.plans.first)
        #expect(plan.title == "Starter")
        #expect(plan.owner == "Personal")
        #expect(plan.status == .lifetime)
        #expect(plan.billing == URL(string: "http://account.localhost:5284/billing"))
        #expect(!content.isFree)
        #expect(content.notices.isEmpty)
        let verification = try #require(content.verification)
        #expect(verification.verifiedAt == Self.now.addingTimeInterval(-2 * 60 * 60))
        #expect(!verification.isExpired)
    }

    @Test("A subscription or an order shows its cycle and Billing…; a granted or migrated license shows neither")
    func cycleAndBillingBySource() throws {
        func plan(_ license: EntitlementLicense) throws -> AccountSettingsContent.PlanRow {
            let content = Self.make(AccountState(
                isSignedIn: true, entitlement: Self.entitlement([license]), refresh: .succeeded(Self.now)
            ))
            return try #require(content.plans.first)
        }
        let personalBilling = URL(string: "http://account.localhost:5284/billing")
        let endsAt = Self.now.addingTimeInterval(90 * Self.day)

        let subscription = try plan(Self.license(cycle: "yearly", source: "subscription"))
        #expect(subscription.title == "Starter, Yearly")
        #expect(subscription.status == .active)
        #expect(subscription.billing == personalBilling)

        let order = try plan(Self.license(cycle: "lifetime", source: "order"))
        #expect(order.title == "Starter")
        #expect(order.status == .lifetime)
        #expect(order.billing == personalBilling)

        let manual = try plan(Self.license(cycle: "lifetime", source: "manual"))
        #expect(manual.title == "Starter")
        #expect(manual.status == .active)
        #expect(manual.billing == nil)

        let manualWithEnd = try plan(Self.license(cycle: "yearly", source: "manual", endsAt: endsAt))
        #expect(manualWithEnd.title == "Starter")
        #expect(manualWithEnd.status == .endsOn(endsAt))
        #expect(manualWithEnd.billing == nil)

        let legacy = try plan(Self.license(plan: "team", cycle: "yearly", source: "legacy"))
        #expect(legacy.title == "Team")
        #expect(legacy.status == .active)
        #expect(legacy.billing == nil)

        let unknown = try plan(Self.license(cycle: "monthly", source: "voucher"))
        #expect(unknown.title == "Starter")
        #expect(unknown.billing == nil)
    }

    @Test("A signed-in account without licenses is on Free")
    func free() {
        let content = Self.make(AccountState(isSignedIn: true, entitlement: Self.entitlement([]), refresh: .succeeded(Self.now)))

        #expect(content.isFree)
        #expect(content.plans.isEmpty)
    }

    @Test("Teams list role and seat, and link the team's portal page; only an owner gets the team's billing")
    func teamMembership() throws {
        let team = EntitlementLicense.Team(id: "team_acme", name: "Acme")
        let profile = AccountProfile(email: "ada@m16.example", name: "Ada", memberships: [
            AccountMembership(teamID: "team_acme", teamName: "Acme", role: "member", hasSeat: true),
            AccountMembership(teamID: "team_beta", teamName: "Beta", role: "admin", hasSeat: false)
        ])
        let content = Self.make(
            AccountState(
                isSignedIn: true,
                entitlement: Self.entitlement([Self.license(plan: "team", cycle: "yearly", team: team)]),
                refresh: .succeeded(Self.now)
            ),
            profile: profile
        )

        #expect(content.teams == [
            .init(id: "team_acme", name: "Acme", role: "Member", hasSeat: true,
                  manage: URL(string: "http://account.localhost:5284/teams/team_acme")!),
            .init(id: "team_beta", name: "Beta", role: "Admin", hasSeat: false,
                  manage: URL(string: "http://account.localhost:5284/teams/team_beta")!)
        ])
        let plan = try #require(content.plans.first)
        #expect(plan.title == "Team, Yearly")
        #expect(plan.owner == "Acme")
        #expect(plan.status == .active)
        #expect(plan.billing == nil, "A member cannot change the team's billing")

        let owner = AccountProfile(email: "ada@m16.example", name: nil, memberships: [
            AccountMembership(teamID: "team_acme", teamName: "Acme", role: "owner", hasSeat: true)
        ])
        let owned = Self.make(
            AccountState(
                isSignedIn: true,
                entitlement: Self.entitlement([Self.license(plan: "team", cycle: "yearly", team: team)])
            ),
            profile: owner
        )
        #expect(owned.plans.first?.billing == URL(string: "http://account.localhost:5284/teams/team_acme/billing"))
    }

    @Test("A past due license shows a payment problem and asks to update the payment method")
    func pastDue() throws {
        let content = Self.make(AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement([Self.license(cycle: "monthly", status: "past_due")]),
            refresh: .succeeded(Self.now)
        ))

        let plan = try #require(content.plans.first)
        #expect(plan.status == .paymentProblem)
        #expect(content.notices == [.paymentProblem(plan)])
    }

    @Test("A canceling license says when it ends")
    func canceling() throws {
        let endsAt = Self.now.addingTimeInterval(10 * Self.day)
        let content = Self.make(AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement([Self.license(cycle: "yearly", status: "canceling", endsAt: endsAt)]),
            refresh: .succeeded(Self.now)
        ))

        let plan = try #require(content.plans.first)
        #expect(plan.status == .canceling(endsAt: endsAt))
        #expect(content.notices == [.canceling(plan, endsAt: endsAt)])
    }

    @Test("An entitlement expiring within 3 days warns while no refresh has succeeded, and not after one")
    func expiringSoon() {
        let expiresAt = Self.now.addingTimeInterval(2 * Self.day)
        let stale = Self.entitlement(issuedAt: Self.now.addingTimeInterval(-12 * Self.day), expiresAt: expiresAt)

        let failed = Self.make(AccountState(isSignedIn: true, entitlement: stale, refresh: .failed(.network("offline"))))
        #expect(failed.notices == [.expiringSoon(expiresAt: expiresAt, isOfflineFile: false)])

        let refreshed = Self.make(AccountState(isSignedIn: true, entitlement: stale, refresh: .succeeded(Self.now)))
        #expect(refreshed.notices.isEmpty)

        let later = Self.make(AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement(expiresAt: Self.now.addingTimeInterval(4 * Self.day)),
            refresh: .failed(.network("offline"))
        ))
        #expect(later.notices.isEmpty)
    }

    @Test("An offline file shows its account without a session and warns before it expires")
    func offlineFile() throws {
        let expiresAt = Self.now.addingTimeInterval(Self.day)
        let content = Self.make(AccountState(entitlement: Self.entitlement(expiresAt: expiresAt, isOffline: true)))

        #expect(content.identity == .account(name: "Ada", email: "ada@m16.example", isSignedIn: false))
        #expect(content.showsPlan)
        #expect(!content.showsDevices)
        #expect(!content.canRefresh)
        #expect(content.notices == [.expiringSoon(expiresAt: expiresAt, isOfflineFile: true)])
        #expect(try #require(content.verification).isOfflineFile)
    }

    @Test("A lapsed entitlement says when it expired")
    func expired() {
        let expiredAt = Self.now.addingTimeInterval(-Self.day)
        let content = Self.make(AccountState(
            isSignedIn: true,
            entitlement: Self.entitlement(issuedAt: Self.now.addingTimeInterval(-15 * Self.day), expiresAt: expiredAt),
            refresh: .failed(.network("offline"))
        ))

        #expect(content.notices == [.expired(at: expiredAt, isOfflineFile: false)])
        #expect(content.verification?.isExpired == true)
    }

    @Test("Signed in without any entitlement after a failed refresh says the plan could not be verified")
    func verificationFailed() {
        let content = Self.make(AccountState(isSignedIn: true, refresh: .failed(.network("offline"))))

        #expect(content.notices == [.verificationFailed(message: AccountError.network("offline").friendlyDescription)])
        #expect(content.plans.isEmpty)
        #expect(!content.isFree)
    }

    @Test("device_limit_reached hides the plan and offers to choose a device")
    func deviceLimit() {
        let content = Self.make(AccountState(isSignedIn: true, refresh: .deviceLimitReached([])))

        #expect(content.notices == [.deviceLimit])
        #expect(content.plans.isEmpty)
        #expect(!content.isFree)
    }

    @Test("Plans, cycles, statuses and roles the app does not know read as neutral text")
    func unknownCodes() throws {
        let profile = AccountProfile(email: "ada@m16.example", name: "Ada", memberships: [
            AccountMembership(teamID: "team_x", teamName: "X", role: "billing_manager", hasSeat: true)
        ])
        let content = Self.make(
            AccountState(
                isSignedIn: true,
                entitlement: Self.entitlement([Self.license(plan: "enterprise", cycle: "quarterly", status: "paused")]),
                refresh: .succeeded(Self.now)
            ),
            profile: profile
        )

        let plan = try #require(content.plans.first)
        #expect(plan.title == "Paid plan")
        #expect(plan.status == nil)
        #expect(content.notices.isEmpty)
        #expect(content.teams?.first?.role == nil)
        #expect(content.teams?.first?.hasSeat == true)
    }

    @Test("Devices put this Mac first, then by last seen, and a live offline file keeps a device from removal")
    func devices() throws {
        func device(_ id: String, machineID: String, lastSeen: TimeInterval, offlineUntil: Date? = nil) -> AccountDevice {
            AccountDevice(
                id: id, machineID: machineID, name: id, platform: "linux", osVersion: "Fedora 43",
                lastSeenAt: Self.now.addingTimeInterval(lastSeen), holdsLicense: true, offlineUntil: offlineUntil
            )
        }
        let content = Self.make(
            AccountState(isSignedIn: true, entitlement: Self.entitlement(), refresh: .succeeded(Self.now)),
            devices: [
                device("old", machineID: "1", lastSeen: -3 * Self.day),
                device("offline", machineID: "2", lastSeen: -Self.day, offlineUntil: Self.now.addingTimeInterval(30 * Self.day)),
                device("lapsed", machineID: "3", lastSeen: -2 * Self.day, offlineUntil: Self.now.addingTimeInterval(-Self.day)),
                device("this", machineID: Self.machineID, lastSeen: 0)
            ]
        )

        let rows = try #require(content.devices)
        #expect(rows.map { $0.id } == ["this", "offline", "lapsed", "old"])
        #expect(rows.map { $0.canRemove } == [false, false, true, true])
        #expect(rows[1].offlineUntil == Self.now.addingTimeInterval(30 * Self.day))
        #expect(rows[2].offlineUntil == nil)
        #expect(rows[3].system == "Fedora 43")
    }

    @Test("A Mac's system reads as macOS and its version")
    func systemNames() {
        #expect(AccountCodes.systemName(platform: "macos", osVersion: "26.1") == "macOS 26.1")
        #expect(AccountCodes.systemName(platform: "linux", osVersion: "") == "Linux")
        #expect(AccountCodes.systemName(platform: "windows", osVersion: "11") == "11")
    }
}
