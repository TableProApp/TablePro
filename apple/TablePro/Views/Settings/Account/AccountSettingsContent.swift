//
//  AccountSettingsContent.swift
//  TablePro
//

import Foundation

// What Settings > Account shows for one account state (clients.md, Settings > Account).
internal struct AccountSettingsContent: Equatable {
    enum Identity: Equatable {
        case signedOut
        // A key from an older build that the exchange has not traded for a session yet.
        case licenseKey(isValid: Bool)
        // isSignedIn is false for a Mac that only holds an offline file.
        case account(name: String?, email: String?, isSignedIn: Bool)
    }

    enum PlanStatus: Equatable {
        case active
        case lifetime
        case endsOn(Date)
        case canceling(endsAt: Date?)
        case paymentProblem
    }

    struct PlanRow: Equatable, Identifiable {
        let id: String
        let title: String
        let owner: String
        let status: PlanStatus?
        let billing: URL?
    }

    enum Notice: Equatable, Identifiable {
        case deviceLimit
        case paymentProblem(PlanRow)
        case canceling(PlanRow, endsAt: Date?)
        case expiringSoon(expiresAt: Date, isOfflineFile: Bool)
        case expired(at: Date, isOfflineFile: Bool)
        case verificationFailed(message: String?)

        var id: String {
            switch self {
            case .deviceLimit: "device-limit"
            case .paymentProblem(let plan): "payment-\(plan.id)"
            case .canceling(let plan, _): "canceling-\(plan.id)"
            case .expiringSoon: "expiring"
            case .expired: "expired"
            case .verificationFailed: "verification-failed"
            }
        }
    }

    struct TeamRow: Equatable, Identifiable {
        let id: String
        let name: String
        let role: String?
        let hasSeat: Bool
        let manage: URL
    }

    struct DeviceRow: Equatable, Identifiable {
        let id: String
        let name: String
        let system: String
        let lastSeenAt: Date
        let isThisMac: Bool
        // Set while the device's offline file is valid, which keeps it from being removed.
        let offlineUntil: Date?

        var canRemove: Bool {
            !isThisMac && offlineUntil == nil
        }
    }

    struct Verification: Equatable {
        let verifiedAt: Date
        let validUntil: Date
        let isOfflineFile: Bool
        let isExpired: Bool
    }

    static let expiryWarning: TimeInterval = 3 * 24 * 60 * 60

    let identity: Identity
    let notices: [Notice]
    let showsPlan: Bool
    let plans: [PlanRow]
    let isFree: Bool
    let showsDevices: Bool
    let devices: [DeviceRow]?
    let teams: [TeamRow]?
    let verification: Verification?
    let canRefresh: Bool
    let machineID: String

    static func make(
        state: AccountState,
        profile: AccountProfile?,
        devices: [AccountDevice]?,
        hasLegacyLicense: Bool,
        machineID: String,
        configuration: AccountConfiguration,
        now: Date
    ) -> AccountSettingsContent {
        let entitlement = state.entitlement
        let isDeviceLimit: Bool
        if case .deviceLimitReached = state.refresh {
            isDeviceLimit = true
        } else {
            isDeviceLimit = false
        }
        let ownedTeams = Set((profile?.memberships ?? []).filter { $0.role == "owner" }.map(\.teamID))
        let plans = isDeviceLimit ? [] : (entitlement?.licenses ?? []).map {
            planRow($0, ownedTeams: ownedTeams, configuration: configuration)
        }
        let showsPlan = state.isSignedIn || entitlement != nil

        return AccountSettingsContent(
            identity: identity(state: state, profile: profile, now: now),
            notices: notices(state: state, plans: plans, isDeviceLimit: isDeviceLimit, now: now),
            showsPlan: showsPlan,
            plans: plans,
            isFree: showsPlan && !isDeviceLimit && entitlement != nil && plans.isEmpty,
            showsDevices: state.isSignedIn,
            devices: state.isSignedIn ? devices.map { deviceRows($0, machineID: machineID, now: now) } : nil,
            teams: state.isSignedIn ? profile.map { teamRows($0, configuration: configuration) } : nil,
            verification: entitlement.map {
                Verification(
                    verifiedAt: $0.issuedAt,
                    validUntil: $0.expiresAt,
                    isOfflineFile: $0.isOffline,
                    isExpired: !$0.isValid(at: now)
                )
            },
            canRefresh: state.isSignedIn || hasLegacyLicense,
            machineID: machineID
        )
    }

    private static func identity(state: AccountState, profile: AccountProfile?, now: Date) -> Identity {
        if state.isSignedIn || state.entitlement != nil {
            let email = profile?.email ?? state.entitlement?.email
            return .account(
                name: profile?.name ?? state.entitlement?.name,
                email: email?.isEmpty == false ? email : nil,
                isSignedIn: state.isSignedIn
            )
        }
        if let legacy = state.legacy {
            return .licenseKey(isValid: legacy.isValid(at: now))
        }
        return .signedOut
    }

    private static func notices(state: AccountState, plans: [PlanRow], isDeviceLimit: Bool, now: Date) -> [Notice] {
        if isDeviceLimit {
            return [.deviceLimit]
        }
        var notices: [Notice] = []
        for plan in plans {
            switch plan.status {
            case .paymentProblem:
                notices.append(.paymentProblem(plan))
            case .canceling(let endsAt):
                notices.append(.canceling(plan, endsAt: endsAt))
            default:
                break
            }
        }
        guard let entitlement = state.entitlement else {
            if state.isSignedIn, case .failed(let error) = state.refresh {
                notices.append(.verificationFailed(message: error.friendlyDescription))
            }
            return notices
        }
        if !entitlement.isValid(at: now) {
            notices.append(.expired(at: entitlement.expiresAt, isOfflineFile: entitlement.isOffline))
        } else if entitlement.expiresAt.timeIntervalSince(now) <= expiryWarning, !state.refresh.isSucceeded {
            notices.append(.expiringSoon(expiresAt: entitlement.expiresAt, isOfflineFile: entitlement.isOffline))
        }
        return notices
    }

    private static func planRow(
        _ license: EntitlementLicense,
        ownedTeams: Set<String>,
        configuration: AccountConfiguration
    ) -> PlanRow {
        let plan = AccountCodes.planName(license.plan)
        // A lifetime license says so in its status, so its title names the plan alone.
        let cycle = license.cycle == "lifetime" ? nil : AccountCodes.cycleName(license.cycle)
        let title = cycle.map { String(format: String(localized: "%@, %@"), plan, $0) } ?? plan
        let billing: URL?
        if let team = license.team {
            billing = ownedTeams.contains(team.id) ? configuration.portalTeamBilling(team.id) : nil
        } else {
            billing = configuration.portalBilling
        }
        return PlanRow(
            id: license.id,
            title: title,
            owner: license.team?.name ?? String(localized: "Personal"),
            status: status(of: license),
            billing: billing
        )
    }

    private static func status(of license: EntitlementLicense) -> PlanStatus? {
        switch license.status {
        case "past_due":
            return .paymentProblem
        case "canceling":
            return .canceling(endsAt: license.endsAt)
        case "active":
            if let endsAt = license.endsAt {
                return .endsOn(endsAt)
            }
            return license.cycle == "lifetime" ? .lifetime : .active
        default:
            return nil
        }
    }

    private static func teamRows(_ profile: AccountProfile, configuration: AccountConfiguration) -> [TeamRow] {
        profile.memberships.map { membership in
            TeamRow(
                id: membership.teamID,
                name: membership.teamName,
                role: AccountCodes.roleName(membership.role),
                hasSeat: membership.hasSeat,
                manage: configuration.portalTeam(membership.teamID)
            )
        }
    }

    private static func deviceRows(_ devices: [AccountDevice], machineID: String, now: Date) -> [DeviceRow] {
        devices
            .map { device in
                DeviceRow(
                    id: device.id,
                    name: device.name,
                    system: AccountCodes.systemName(platform: device.platform, osVersion: device.osVersion),
                    lastSeenAt: device.lastSeenAt,
                    isThisMac: device.machineID == machineID,
                    offlineUntil: device.offlineFileValid(at: now) ? device.offlineUntil : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }
}

private extension EntitlementRefreshState {
    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

// Codes a newer server adds read as neutral text, never as a failure.
internal enum AccountCodes {
    static func planName(_ code: String) -> String {
        switch code {
        case "starter": String(localized: "Starter")
        case "team": String(localized: "Team")
        default: String(localized: "Paid plan")
        }
    }

    static func cycleName(_ code: String) -> String? {
        switch code {
        case "monthly": String(localized: "Monthly")
        case "yearly": String(localized: "Yearly")
        case "lifetime": String(localized: "Lifetime")
        default: nil
        }
    }

    static func roleName(_ code: String) -> String? {
        switch code {
        case "owner": String(localized: "Owner")
        case "admin": String(localized: "Admin")
        case "member": String(localized: "Member")
        default: nil
        }
    }

    // A Linux app reports its distribution as the OS version ("Fedora 43").
    static func systemName(platform: String, osVersion: String) -> String {
        switch platform {
        case "macos":
            return osVersion.isEmpty ? "macOS" : String(format: String(localized: "macOS %@"), osVersion)
        case "linux":
            return osVersion.isEmpty ? "Linux" : osVersion
        default:
            return osVersion
        }
    }
}
