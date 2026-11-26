import Foundation
import os
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

// The core's account as AccountModel reaches it, with what each call did.
private final class ScriptedAccountBackend: AccountBackend, @unchecked Sendable {
    private struct State {
        var snapshot = AccountSnapshot()
        var server = AccountServer.production
        var chosen: [URL?] = []
        var signIns = 0
        var refreshesPastLimit = 0
        var signInError: AccountError?
        var policies: [ManagedPolicyArg] = []
    }

    let machineID = String(repeating: "5f", count: 32)
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isRestored: Bool { true }
    func waitUntilRestored() async {}

    var signIns: Int { state.withLock { $0.signIns } }
    var chosen: [URL?] { state.withLock { $0.chosen } }
    var refreshesPastLimit: Int { state.withLock { $0.refreshesPastLimit } }
    var policies: [ManagedPolicyArg] { state.withLock { $0.policies } }

    func set(_ snapshot: AccountSnapshot) {
        state.withLock { $0.snapshot = snapshot }
    }

    func failSignIn(with error: AccountError) {
        state.withLock { $0.signInError = error }
    }

    func status() -> AccountSnapshot { state.withLock { $0.snapshot } }
    func featureAccess(code: String) -> ProFeatureAccess { .signedOut }
    func server() -> AccountServer { state.withLock { $0.server } }
    func license() -> AccountServerLicense? { nil }

    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) {
        let failure = state.withLock { state -> AccountError? in
            state.signIns += 1
            guard state.signInError == nil else { return state.signInError }
            state.snapshot = AccountSnapshot(state: .signedIn, accountID: "acct", email: "ada@example.com")
            return nil
        }
        if let failure { throw failure }
    }

    func signOut() async throws(AccountError) {
        state.withLock { $0.snapshot = AccountSnapshot() }
    }

    func refresh() async throws(AccountError) {}

    func refreshPastDeviceLimit() async throws(AccountError) -> Bool {
        state.withLock { $0.refreshesPastLimit += 1 }
        return true
    }

    func useLicenseKey(_ key: String) async throws(AccountError) {}
    func importOfflineFile(at url: URL) async throws(AccountError) {}

    func chooseServer(_ url: URL?) async throws(AccountError) {
        state.withLock { $0.chosen.append(url) }
    }

    func profile() async throws(AccountError) -> AccountProfile {
        AccountProfile(email: "ada@example.com", name: nil, memberships: [])
    }

    func devices() async throws(AccountError) -> [AccountDevice] { [] }
    func removeDevice(_ id: String) async throws(AccountError) {}

    func accessToken() async throws(AccountError) -> AccountAccessToken {
        throw .signedOut
    }

    func accessTokenRejected(_ token: String) async {}

    func applyPolicy(_ policy: ManagedPolicyArg) async {
        state.withLock { $0.policies.append(policy) }
    }

    func allowsTableProRequests() async -> Bool { true }
}

@MainActor
private struct NoPage: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        throw .canceled
    }
}

@MainActor
struct AccountModelTests {
    private func opened(_ backend: ScriptedAccountBackend) -> AccountModel {
        let account = AccountModel { _, _ in backend }
        account.openIfNeeded()
        return account
    }

    @Test("Opening reads what the core restored")
    func opensAndPublishes() {
        let backend = ScriptedAccountBackend()
        backend.set(AccountSnapshot(state: .signedIn, accountID: "acct", email: "ada@example.com"))

        let account = opened(backend)

        #expect(account.availability == .open)
        #expect(account.isRestored)
        #expect(account.isSignedIn)
        #expect(account.snapshot.email == "ada@example.com")
    }

    @Test("A Keychain locked before the first unlock leaves the account to the next activation")
    func lockedWaitsForUnlock() {
        let backend = ScriptedAccountBackend()
        var locked = true
        let account = AccountModel { _, _ throws(AccountKeychainFailure) in
            if locked { throw .locked }
            return backend
        }

        account.openIfNeeded()
        #expect(account.availability == .waitingForUnlock)

        locked = false
        account.sceneBecameActive()
        #expect(account.availability == .open)
    }

    @Test("A Keychain that refuses for good leaves the account unavailable, and it is not asked again")
    func failedStaysUnavailable() {
        var opens = 0
        let account = AccountModel { _, _ throws(AccountKeychainFailure) in
            opens += 1
            throw .failed("Keychain error -34018")
        }

        account.openIfNeeded()
        account.sceneBecameActive()

        #expect(account.availability == .unavailable)
        #expect(opens == 1)
    }

    @Test("Sign in goes through the authenticator it is given and publishes the account")
    func signIn() async throws {
        let backend = ScriptedAccountBackend()
        let account = opened(backend)

        try await account.signIn(using: NoPage())

        #expect(backend.signIns == 1)
        #expect(account.isSignedIn)
        #expect(!account.isBusy)
    }

    @Test("Signed in, another sign-in or another server goes through Sign Out first")
    func signedInRefusesASwitch() async {
        let backend = ScriptedAccountBackend()
        backend.set(AccountSnapshot(state: .signedIn, accountID: "acct"))
        let account = opened(backend)

        await #expect(throws: AccountError.signOutFirst) { try await account.signIn(using: NoPage()) }
        await #expect(throws: AccountError.signOutFirst) {
            try await account.chooseServer(URL(string: "https://tablepro.example.com"))
        }
        #expect(backend.signIns == 0)
        #expect(backend.chosen.isEmpty)
    }

    @Test("A canceled sign-in leaves the account signed out")
    func canceledSignIn() async {
        let backend = ScriptedAccountBackend()
        backend.failSignIn(with: .canceled)
        let account = opened(backend)

        await #expect(throws: AccountError.canceled) { try await account.signIn(using: NoPage()) }
        #expect(!account.isSignedIn)
        #expect(!account.isBusy)
    }

    @Test("A sign-out the person did not ask for is kept to show, and a sign-in clears it")
    func involuntarySignOut() async throws {
        let backend = ScriptedAccountBackend()
        backend.set(AccountSnapshot(state: .signedIn, accountID: "acct"))
        let account = opened(backend)

        backend.set(AccountSnapshot())
        account.accountStatusChanged(signedOutBy: .deviceRevoked)
        #expect(account.involuntarySignOut == .deviceRevoked)

        try await account.signIn(using: NoPage())
        #expect(account.involuntarySignOut == nil)
    }

    @Test("Back in the foreground past the device limit, it asks again whether a slot was freed")
    func pastDeviceLimitRefreshesOnActivation() async throws {
        let backend = ScriptedAccountBackend()
        backend.set(AccountSnapshot(state: .signedIn, accountID: "acct", problem: .deviceLimitReached([])))
        let account = opened(backend)

        account.sceneBecameActive()

        try await waitUntil { backend.refreshesPastLimit == 1 }
        #expect(account.isPastDeviceLimit)
    }

    @Test("New values from the organization reach the core in order, and the same values do not again")
    func valuesReachTheCore() async throws {
        let backend = ScriptedAccountBackend()
        var opened: [ManagedAppConfiguration] = []
        let account = AccountModel { _, managed in
            opened.append(managed)
            return backend
        }
        account.openIfNeeded()
        let held = ManagedAppConfiguration(accountServerURL: "https://tablepro.example.com", allowOtherAccountServers: false)
        let released = ManagedAppConfiguration(usageDataAllowed: false)

        account.apply(held)
        account.apply(held)
        account.apply(released)

        try await waitUntil { backend.policies.count == 2 }
        #expect(backend.policies == [held.coreArgument, released.coreArgument])
        #expect(opened == [.unmanaged])
    }

    @Test("An account opened after new values came opens with them")
    func laterOpenTakesTheValues() {
        var opened: [ManagedAppConfiguration] = []
        let account = AccountModel { _, managed throws(AccountKeychainFailure) in
            opened.append(managed)
            throw .locked
        }
        let held = ManagedAppConfiguration(accountServerURL: "https://tablepro.example.com", allowOtherAccountServers: false)

        account.apply(held)
        account.openIfNeeded()

        #expect(opened == [held])
    }
}
