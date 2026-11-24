//
//  AccountBackend.swift
//  TablePro
//

import Foundation

// The server the account signs in to, as the core resolved it: a managed value, else the person's choice, else
// tablepro.app (core/docs/decisions/0044-sync-through-one-service-run-by-us-or-on-premises.md, App configuration).
internal struct AccountServer: Equatable, Sendable {
    let apiOrigin: URL
    let accountOrigin: URL
    let host: String
    let isProduction: Bool
    let isManaged: Bool
    let othersAllowed: Bool

    static let production = AccountServer(
        apiOrigin: URL(string: "https://api.tablepro.app")!,
        accountOrigin: URL(string: "https://account.tablepro.app")!,
        host: "tablepro.app",
        isProduction: true,
        isManaged: false,
        othersAllowed: true
    )

    var apiBaseURL: URL {
        apiOrigin.appendingPathComponent("v2")
    }
}

internal enum AccountSignOutCause: Equatable, Sendable {
    case user
    case refreshRefused
    case deviceRevoked
    case serverChanged
}

// What the core holds about the account, read on its listener's thread and published on the main actor.
internal struct AccountSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case signedOut
        case signedIn
        // An imported offline file on a Mac that is not signed in.
        case offline
    }

    enum Problem: Equatable, Sendable {
        case expired
        case refreshFailed(AccountError)
        case deviceLimitReached([AccountDevice])
    }

    var state: State = .signedOut
    var accountID: String?
    var email: String?
    var name: String?
    var features: Set<String> = []
    var licenses: [EntitlementLicense] = []
    var expiresAt: Date?
    // From an offline file, which a signed-in Mac can import too.
    var isOfflineFile = false
    var problem: Problem?
    // False when the Keychain refused the refresh token: the next launch starts signed out.
    var remembered = false
}

// The license a company server installed, as the core verified it.
internal struct AccountServerLicense: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case active
        // Past its end and inside the grace: everything still works.
        case grace
        // Past the grace: Team Library pulls, and the server takes no pushes.
        case lapsed
    }

    let seats: Int
    let isTrial: Bool
    // Nil for a perpetual license.
    let expiresAt: Date?
    let graceEndsAt: Date?
    let state: State
}

// A bearer with the /v2 base of the server that issued it, read together so neither is another server's.
internal struct AccountAccessToken: Equatable, Sendable {
    let token: String
    let apiBaseURL: URL
}

@MainActor
internal protocol AccountBackendListener: AnyObject {
    func accountStatusChanged(signedOutBy cause: AccountSignOutCause?)
}

// The core's AccountService seen from Swift, so the app and its tests share one adapter: TableProFFI in the app,
// a fake over FakeAccountServer in the tests.
internal protocol AccountBackend: AnyObject, Sendable {
    var machineID: String { get }
    // False until the account has read what the last run kept; until then it reads as signed out.
    var isRestored: Bool { get }
    func waitUntilRestored() async

    func status() -> AccountSnapshot
    func featureAccess(_ feature: ProFeature) -> ProFeatureAccess
    func server() -> AccountServer
    func license() -> AccountServerLicense?

    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError)
    func signOut() async throws(AccountError)
    func refresh() async throws(AccountError)
    func refreshPastDeviceLimit() async throws(AccountError) -> Bool
    func useLicenseKey(_ key: String) async throws(AccountError)
    func importOfflineFile(at url: URL) async throws(AccountError)
    // Nil drops the choice, for a configuration profile's default or else tablepro.app. Discovery runs first, and the
    // old server's sign-in ends.
    func chooseServer(_ url: URL?) async throws(AccountError)

    func profile() async throws(AccountError) -> AccountProfile
    func devices() async throws(AccountError) -> [AccountDevice]
    func removeDevice(_ id: String) async throws(AccountError)

    // The bearer the Swift Team Library and share clients send, and where to.
    func accessToken() async throws(AccountError) -> AccountAccessToken
    func accessTokenRejected(_ token: String) async
}
