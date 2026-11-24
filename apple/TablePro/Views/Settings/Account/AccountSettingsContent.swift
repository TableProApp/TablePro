import Foundation

// What Settings > Account shows for one account state (clients.md, Settings > Account).
internal struct AccountSettingsContent: Equatable {
    enum Identity: Equatable {
        case signedOut
        // isSignedIn is false for a Mac that only holds an offline file.
        case account(name: String?, email: String?, isSignedIn: Bool)
    }

    enum PlanStatus: Equatable {
        case active
        case lifetime
        case renewsOn(Date)
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
        // Nil until this run of the app has heard from the server.
        let verifiedAt: Date?
        let validUntil: Date
        let isOfflineFile: Bool
        let isExpired: Bool
    }

    enum VerificationState: Equatable {
        case verified(at: Date?, until: Date)
        case offlineFile(until: Date)
        case expired(on: Date)
        case offlineFileExpired(on: Date)
        case notVerified
    }

    static let expiryWarning: TimeInterval = 3 * 24 * 60 * 60

    let identity: Identity
    let notices: [Notice]
    let showsPlan: Bool
    let plans: [PlanRow]
    let isFree: Bool
    let showsDevices: Bool
    let showsTeams: Bool
    let devices: [DeviceRow]?
    let teams: [TeamRow]?
    let verification: Verification?
    let canRefresh: Bool
    let machineID: String
    let server: AccountServer
    let serverLicense: AccountServerLicense?

    // tablepro.app sells plans and issues offline files; a company server's license is its administrator's.
    var sellsPlans: Bool {
        server.isProduction
    }

    static func make(
        state: AccountState,
        profile: AccountProfile?,
        devices: [AccountDevice]?,
        machineID: String,
        now: Date
    ) -> AccountSettingsContent {
        let entitlement = state.entitlement
        let isDeviceLimit = state.refresh.isDeviceLimit
        let portal = AccountPortal(server: state.server)
        let ownedTeams = Set((profile?.memberships ?? []).filter { $0.role == "owner" }.map(\.teamID))
        let plans = isDeviceLimit ? [] : (entitlement?.licenses ?? []).map {
            planRow($0, ownedTeams: ownedTeams, portal: portal, sellsPlans: state.server.isProduction)
        }
        let showsPlan = state.isSignedIn || entitlement != nil

        return AccountSettingsContent(
            identity: identity(state: state, profile: profile),
            notices: notices(state: state, plans: plans, isDeviceLimit: isDeviceLimit, now: now),
            showsPlan: showsPlan,
            plans: plans,
            isFree: showsPlan && !isDeviceLimit && entitlement != nil && plans.isEmpty && state.server.isProduction,
            showsDevices: state.isSignedIn,
            showsTeams: state.isSignedIn,
            devices: state.isSignedIn ? devices.map { deviceRows($0, now: now) } : nil,
            teams: state.isSignedIn ? profile.map { teamRows($0, portal: portal) } : nil,
            verification: entitlement.map {
                Verification(
                    verifiedAt: $0.isOffline ? nil : state.verifiedAt,
                    validUntil: $0.expiresAt,
                    isOfflineFile: $0.isOffline,
                    isExpired: !$0.isValid(at: now)
                )
            },
            canRefresh: state.isSignedIn,
            machineID: machineID,
            server: state.server,
            serverLicense: state.serverLicense
        )
    }

    var verificationState: VerificationState? {
        guard let verification else { return canRefresh ? .notVerified : nil }
        switch (verification.isOfflineFile, verification.isExpired) {
        case (false, false): return .verified(at: verification.verifiedAt, until: verification.validUntil)
        case (true, false): return .offlineFile(until: verification.validUntil)
        case (false, true): return .expired(on: verification.validUntil)
        case (true, true): return .offlineFileExpired(on: verification.validUntil)
        }
    }

    // A notice with Try Again already runs the check the verification row's Refresh would.
    var offersRetry: Bool {
        notices.contains { LicensePresentation.action(for: $0) == .retryValidation }
    }

    // Without GET /v2/me, so a team plan's payment notice offers no billing link here.
    static func notices(state: AccountState, now: Date) -> [Notice] {
        let isDeviceLimit = state.refresh.isDeviceLimit
        let portal = AccountPortal(server: state.server)
        let plans = isDeviceLimit ? [] : (state.entitlement?.licenses ?? []).map {
            planRow($0, ownedTeams: [], portal: portal, sellsPlans: state.server.isProduction)
        }
        return notices(state: state, plans: plans, isDeviceLimit: isDeviceLimit, now: now)
    }

    private static func identity(state: AccountState, profile: AccountProfile?) -> Identity {
        if state.isSignedIn || state.entitlement != nil {
            let email = profile?.email ?? state.entitlement?.email
            return .account(
                name: profile?.name ?? state.entitlement?.name,
                email: email?.isEmpty == false ? email : nil,
                isSignedIn: state.isSignedIn
            )
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
        portal: AccountPortal,
        sellsPlans: Bool
    ) -> PlanRow {
        let plan = AccountCodes.planName(license.plan)
        // The claim's cycle is the product's. Like the portal, only a license someone pays for shows it:
        // nothing bills one an admin granted or the migration brought over.
        let isBilled = license.source == "subscription" || license.source == "order"
        // A lifetime license says so in its status, so its title names the plan alone.
        let cycle = !isBilled || license.cycle == "lifetime" ? nil : AccountCodes.cycleName(license.cycle)
        let title = cycle.map { String(format: String(localized: "%@, %@"), plan, $0) } ?? plan
        let billing: URL?
        if !isBilled || !sellsPlans {
            billing = nil
        } else if let team = license.team {
            billing = ownedTeams.contains(team.id) ? portal.portalTeamBilling(team.id) : nil
        } else {
            billing = portal.portalBilling
        }
        return PlanRow(
            id: license.id,
            title: title,
            owner: license.team?.name ?? String(localized: "Personal"),
            status: status(of: license, isBilled: isBilled),
            billing: billing
        )
    }

    private static func status(of license: EntitlementLicense, isBilled: Bool) -> PlanStatus? {
        switch license.status {
        case "past_due":
            return .paymentProblem
        case "canceling":
            return .canceling(endsAt: license.endsAt)
        case "active":
            if let endsAt = license.endsAt {
                return .endsOn(endsAt)
            }
            if let renewsAt = license.renewsAt {
                return .renewsOn(renewsAt)
            }
            return isBilled && license.cycle == "lifetime" ? .lifetime : .active
        default:
            return nil
        }
    }

    private static func teamRows(_ profile: AccountProfile, portal: AccountPortal) -> [TeamRow] {
        profile.memberships.map { membership in
            TeamRow(
                id: membership.teamID,
                name: membership.teamName,
                role: AccountCodes.roleName(membership.role),
                hasSeat: membership.hasSeat,
                manage: portal.portalTeam(membership.teamID)
            )
        }
    }

    private static func deviceRows(_ devices: [AccountDevice], now: Date) -> [DeviceRow] {
        devices
            .map { device in
                DeviceRow(
                    id: device.id,
                    name: device.name,
                    system: AccountCodes.systemName(platform: device.platform, osVersion: device.osVersion),
                    lastSeenAt: device.lastSeenAt,
                    isThisMac: device.isThisMac,
                    offlineUntil: device.offlineFileValid(at: now) ? device.offlineUntil : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }
}

// The pane, the gates and Welcome read a state in the same words.
extension AccountSettingsContent.Notice {
    // A canceling plan is the person's own choice, so it informs rather than warns.
    var isInformational: Bool {
        if case .canceling = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .deviceLimit:
            return String(localized: "Device limit reached")
        case .paymentProblem:
            return String(localized: "Payment problem")
        case .canceling:
            return String(localized: "Your plan is canceling")
        case .expiringSoon(_, true):
            return String(localized: "Your offline file expires soon")
        case .expiringSoon:
            return String(localized: "Verify your plan soon")
        case .expired(_, true):
            return String(localized: "Your offline file has expired")
        case .expired, .verificationFailed:
            return String(localized: "Your plan could not be verified")
        }
    }

    var message: String {
        switch self {
        case .deviceLimit:
            return String(localized: "Your plan is in use on 3 other devices. Remove one to use it on this Mac. Until then, TablePro works on the Free plan here.")
        case .paymentProblem(let plan):
            if plan.billing == nil {
                return String(format: String(localized: "The last payment for %@ (%@) failed. The team's owner can update the payment method."), plan.title, plan.owner)
            }
            return String(format: String(localized: "The last payment for %@ failed. Update your payment method to keep your plan."), plan.title)
        case .canceling(let plan, let endsAt):
            guard let endsAt else {
                return String(format: String(localized: "%@ does not renew."), plan.title)
            }
            return String(
                format: String(localized: "%@ ends on %@ and does not renew."),
                plan.title,
                endsAt.formatted(date: .abbreviated, time: .omitted)
            )
        case .expiringSoon(let expiresAt, let isOfflineFile):
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            return isOfflineFile
                ? String(format: String(localized: "It expires on %@. Create a new one in your account and import it."), date)
                : String(format: String(localized: "TablePro has not reached the server for a while. Connect to the internet before %@ to keep your paid features."), date)
        case .expired(let at, let isOfflineFile):
            let date = at.formatted(date: .abbreviated, time: .omitted)
            return isOfflineFile
                ? String(format: String(localized: "It expired on %@. Create a new one in your account and import it."), date)
                : String(format: String(localized: "The last check expired on %@. Connect to the internet and refresh."), date)
        case .verificationFailed(let message):
            return message ?? String(localized: "Connect to the internet to verify your license.")
        }
    }
}

private extension EntitlementRefreshState {
    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    var isDeviceLimit: Bool {
        if case .deviceLimitReached = self { return true }
        return false
    }
}

// Codes a newer server adds read as neutral text, never as a failure.
internal enum AccountCodes {
    static func planName(_ code: String) -> String {
        switch code {
        case "starter": String(localized: "Pro")
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
