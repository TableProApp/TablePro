import Foundation
import os
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
    }

    let machineID = String(repeating: "5f", count: 32)
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isRestored: Bool { true }
    func waitUntilRestored() async {}

    var signIns: Int { state.withLock { $0.signIns } }
    var chosen: [URL?] { state.withLock { $0.chosen } }
    var refreshesPastLimit: Int { state.withLock { $0.refreshesPastLimit } }

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

    @Test("New server values from the organization open the account again with them, and other values do not")
    func serverValuesReopen() async throws {
        var opened: [ManagedAppConfiguration] = []
        let account = AccountModel { _, managed in
            opened.append(managed)
            return ScriptedAccountBackend()
        }
        account.openIfNeeded()

        account.apply(ManagedAppConfiguration(usageDataAllowed: false))
        let held = ManagedAppConfiguration(accountServerURL: "https://tablepro.example.com", allowOtherAccountServers: false)
        account.apply(held)

        try await waitUntil { opened.count == 2 }
        #expect(opened == [.unmanaged, held])
        #expect(account.availability == .open)
    }

    @Test("A sign-in or a refresh in flight finishes before new server values open the account again")
    func reopenWaitsForEveryCall() async throws {
        let gate = AsyncGate()
        let backend = GatedAccountBackend(gate: gate)
        var opens = 0
        let account = AccountModel { _, _ in
            opens += 1
            return backend
        }
        account.openIfNeeded()

        let signingIn = Task { try await account.signIn(using: NoPage()) }
        let refreshing = Task { try await account.refresh() }
        await gate.arrived(2)
        account.apply(ManagedAppConfiguration(accountServerURL: "https://tablepro.example.com"))
        #expect(opens == 1)

        await gate.open()
        try await signingIn.value
        try await refreshing.value
        try await waitUntil { opens == 2 }
        #expect(!account.isBusy)
    }
}

// Holds a sign-in at the person's page, and a refresh on the network, until the test lets them come back.
private final class GatedAccountBackend: AccountBackend, @unchecked Sendable {
    private let gate: AsyncGate
    let machineID = ""

    init(gate: AsyncGate) {
        self.gate = gate
    }

    var isRestored: Bool { true }
    func waitUntilRestored() async {}
    func status() -> AccountSnapshot { AccountSnapshot() }
    func featureAccess(code: String) -> ProFeatureAccess { .signedOut }
    func server() -> AccountServer { .production }
    func license() -> AccountServerLicense? { nil }
    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) { await gate.wait() }
    func signOut() async throws(AccountError) {}
    func refresh() async throws(AccountError) { await gate.wait() }
    func refreshPastDeviceLimit() async throws(AccountError) -> Bool { false }
    func useLicenseKey(_ key: String) async throws(AccountError) {}
    func importOfflineFile(at url: URL) async throws(AccountError) {}
    func chooseServer(_ url: URL?) async throws(AccountError) {}
    func profile() async throws(AccountError) -> AccountProfile { AccountProfile(email: "", name: nil, memberships: []) }
    func devices() async throws(AccountError) -> [AccountDevice] { [] }
    func removeDevice(_ id: String) async throws(AccountError) {}
    func accessToken() async throws(AccountError) -> AccountAccessToken { throw .signedOut }
    func accessTokenRejected(_ token: String) async {}
}
