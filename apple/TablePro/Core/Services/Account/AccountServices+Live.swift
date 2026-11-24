//
//  AccountServices+Live.swift
//  TablePro
//

import Foundation
import TableProHTTP

extension AccountServices {
    static func live() -> AccountServices {
        let environment = AppStorageEnvironment.shared
        let backend = PendingCoreAccountBackend(machineID: MachineIdentity.shared.machineID)
        return AccountServices(
            backend: backend,
            transport: AccountAPI.transport(session: liveSession()),
            storedKey: StoredLicenseKey(keychain: environment.keychain, defaults: environment.defaults),
            access: .shared
        )
    }

    // A request carries the bearer, and URLSession resends a 307's headers and body to wherever the redirect points.
    nonisolated static func liveSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }
}

// Stands in until the core's account FFI lands in this branch.
private final class PendingCoreAccountBackend: AccountBackend {
    let machineID: String

    init(machineID: String) {
        self.machineID = machineID
    }

    func status() -> AccountSnapshot { AccountSnapshot() }
    func featureAccess(_ feature: ProFeature) -> ProFeatureAccess { .signedOut }
    func server() -> AccountServer { .production }
    func license() -> AccountServerLicense? { nil }
    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) { throw .signedOut }
    func signOut() async throws(AccountError) {}
    func refresh() async throws(AccountError) { throw .signedOut }
    func refreshPastDeviceLimit() async throws(AccountError) -> Bool { false }
    func useLicenseKey(_ key: String) async throws(AccountError) { throw .signedOut }
    func importOfflineFile(at url: URL) async throws(AccountError) { throw .signedOut }
    func chooseServer(_ url: URL?) async throws(AccountError) { throw .signedOut }
    func profile() async throws(AccountError) -> AccountProfile { throw .signedOut }
    func devices() async throws(AccountError) -> [AccountDevice] { throw .signedOut }
    func removeDevice(_ id: String) async throws(AccountError) { throw .signedOut }
    func accessToken() async throws(AccountError) -> String { throw .signedOut }
    func accessTokenRejected(_ token: String) async {}
}
