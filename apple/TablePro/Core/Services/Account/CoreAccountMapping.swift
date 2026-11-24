//
//  CoreAccountMapping.swift
//  TablePro
//

import Foundation
import TableProFFI

// The core's account records and errors in the app's terms. Codes are the core's stable `code()` strings
// (core/crates/account/src/{account_error,server,license}.rs).
internal enum CoreAccountMapping {
    enum Operation {
        case signIn
        case licenseKey
        case offlineFile
        case other
    }

    static func snapshot(_ status: AccountStatusInfo) -> AccountSnapshot {
        AccountSnapshot(
            state: state(status.state),
            accountID: status.accountId,
            email: status.email,
            name: status.name,
            features: Set(status.features),
            licenses: status.licenses.map(license),
            expiresAt: status.entitlementExpiresAtSecs.map(date),
            isOfflineFile: status.offlineFile,
            problem: status.problem.map(problem),
            remembered: status.remembered
        )
    }

    static func access(_ tag: FeatureAccessTag) -> ProFeatureAccess {
        switch tag {
        case .available: .available
        case .signedOut: .signedOut
        // Past the device limit the gates say so from the refresh state, as for a plan without the feature.
        case .notIncluded, .deviceLimitReached: .notIncluded
        case .expired: .expired
        case .refreshFailed: .refreshFailed
        }
    }

    // A Debug run's development stack is a local tablepro.app: plans, shares and the rest work as there.
    static func server(_ info: ServerInfo, isDevelopmentStack: Bool = false) -> AccountServer? {
        guard let api = URL(string: info.apiOrigin) else { return nil }
        return AccountServer(
            apiOrigin: api,
            accountOrigin: info.accountOrigin.flatMap(URL.init(string:)) ?? api,
            host: info.host,
            isProduction: info.isProduction || isDevelopmentStack,
            isManaged: info.isManaged,
            othersAllowed: info.othersAllowed
        )
    }

    static func license(_ info: ServerLicenseInfo) -> AccountServerLicense {
        let state: AccountServerLicense.State = switch info.state {
        case .active: .active
        case .grace: .grace
        case .lapsed: .lapsed
        }
        return AccountServerLicense(
            seats: Int(info.seats),
            isTrial: info.licenseType == "trial",
            expiresAt: info.expiresAtSecs.map(date),
            graceEndsAt: info.graceEndsAtSecs.map(date),
            state: state
        )
    }

    static func device(_ info: DeviceInfo) -> AccountDevice {
        AccountDevice(
            id: info.id,
            isThisMac: info.isThisMachine,
            name: info.name,
            platform: info.platform,
            osVersion: info.osVersion,
            lastSeenAt: date(info.lastSeenAtSecs),
            holdsLicense: info.licensedAtSecs != nil,
            offlineUntil: info.offlineUntilSecs.map(date)
        )
    }

    static func profile(_ info: ProfileInfo) -> AccountProfile {
        AccountProfile(
            email: info.email,
            name: info.name,
            memberships: info.teams.map {
                AccountMembership(teamID: $0.team.id, teamName: $0.team.name, role: $0.role, hasSeat: $0.hasSeat)
            }
        )
    }

    static func cause(_ tag: SignOutCauseTag) -> AccountSignOutCause {
        switch tag {
        case .requested: .user
        case .refused: .refreshRefused
        case .deviceRevoked: .deviceRevoked
        case .serverChanged: .serverChanged
        }
    }

    // Past the device limit the core keeps the sign-in and puts the limit in its status, where the device sheet reads
    // it, so the sign-in stands.
    static func signInError(_ error: CoreError, during operation: Operation) -> AccountError? {
        if case .Failed(let info) = error, info.code == "account.device_limit_reached" {
            return nil
        }
        return self.error(error, during: operation)
    }

    static func error(_ error: CoreError, during operation: Operation) -> AccountError {
        guard case .Failed(let info) = error else { return .canceled }
        switch info.code {
        case "account.sign_in_canceled":
            return .canceled
        case "account.signed_out":
            return .signedOut
        case "account.device_revoked":
            return .server(status: 403, code: "device_revoked")
        case "account.unreachable", "account.sign_in_timed_out", "account.browser":
            return .network(info.message)
        case "account.rate_limited":
            return .server(status: 429, code: "rate_limited")
        // The OAuth error the server sent: invalid_grant refuses a license key, access_denied is the person declining.
        case "account.sign_in_refused":
            let fallback = operation == .licenseKey ? "invalid_grant" : "access_denied"
            return .oauth(oauthError(info.message) ?? fallback, description: nil)
        case "account.server_invalid", "account.server_insecure":
            return .companyServer(.invalidAddress)
        case "account.server_not_tablepro", "account.server_mismatch":
            return .companyServer(.notATableProServer)
        case "account.server_managed":
            return .companyServer(.managed)
        case "account.server_unsupported":
            return .companyServer(.unsupported)
        case "account.license_not_installed":
            return .companyServer(.licenseMissing)
        case "account.license_other_server", "account.license_untrusted", "account.license_invalid",
             "account.license_not_yet_valid":
            return .companyServer(.licenseInvalid)
        case "account.offline_file_unreadable", "account.offline_file_too_large":
            return .offlineFileRejected(.unreadable)
        case "account.other_account":
            return .offlineFileRejected(.otherAccount)
        case "account.entitlement":
            return operation == .offlineFile ? .offlineFileRejected(offlineProblem(info.message)) : .invalidResponse
        case "account.protocol":
            return .invalidResponse
        default:
            // A refusal the core does not word on its own carries the server's problem code.
            if let code = info.server?.code {
                return .server(status: 0, code: code)
            }
            return .network(info.message)
        }
    }

    // The core puts the OAuth error code only in its message, "the sign-in was refused: <error>"
    // (core/crates/account/src/account_error.rs).
    private static func oauthError(_ message: String) -> String? {
        guard let range = message.range(of: "refused: ") else { return nil }
        let code = message[range.upperBound...].prefix { $0.isLetter || $0 == "_" }
        return code.isEmpty ? nil : String(code)
    }

    // The core words an entitlement the file holds only in English, for the log; the app's wording picks a reason.
    private static func offlineProblem(_ message: String) -> AccountError.OfflineFileProblem {
        if message.contains("another machine") { return .otherMachine }
        if message.contains("expired") { return .expired }
        if message.contains("not valid before") { return .notYetValid }
        return .unreadable
    }

    private static func state(_ tag: AccountStateTag) -> AccountSnapshot.State {
        switch tag {
        case .signedOut: .signedOut
        case .signedIn: .signedIn
        case .offline: .offline
        }
    }

    private static func problem(_ tag: EntitlementProblemTag) -> AccountSnapshot.Problem {
        switch tag {
        case .expired:
            return .expired
        case .refreshFailed(let code):
            return .refreshFailed(code == "account.unreachable" ? .network(code) : .server(status: 0, code: code))
        case .deviceLimitReached(let devices):
            return .deviceLimitReached(devices.map(device))
        }
    }

    private static func license(_ info: LicenseInfo) -> EntitlementLicense {
        EntitlementLicense(
            id: info.id,
            plan: info.plan,
            cycle: info.cycle,
            source: info.source,
            status: info.status,
            renewsAt: info.renewsAtSecs.map(date),
            endsAt: info.endsAtSecs.map(date),
            team: info.team.map { EntitlementLicense.Team(id: $0.id, name: $0.name) }
        )
    }

    private static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
