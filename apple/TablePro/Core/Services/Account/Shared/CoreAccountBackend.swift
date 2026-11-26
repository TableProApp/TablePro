//
//  CoreAccountBackend.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The account a sync service opens with, on the core that holds the app's stores (core ADR 0054).
nonisolated internal protocol SyncAccountProviding: AnyObject, Sendable {
    // Nil when the account did not open.
    func accountService() async -> AccountService?
}

// The core's AccountService (core/docs/decisions/0047-the-apple-apps-sign-in-through-the-core.md). It opens on a task
// at launch and restores the last run's sign-in after that; until then the account reads as signed out, and a call
// waits for the open.
nonisolated internal final class CoreAccountBackend: AccountBackend, SyncAccountProviding, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreAccountBackend")

    let machineID: String
    private let isDevelopmentStack: Bool
    private let authenticator = CoreWebAuthenticator()
    private let restored = RestoredLatch()
    private let listenerBridge: CoreAccountListener
    private let opened = OSAllocatedUnfairLock<AccountService?>(initialState: nil)
    private let opening: Task<AccountService?, Never>

    // Each app's own config: its client, machine ID, files and managed values.
    init(config: AccountConfig, appVersion: String, keychain: any AccountTokenKeychain) {
        machineID = config.machineId ?? ""
        isDevelopmentStack = config.apiUrl != nil
        listenerBridge = CoreAccountListener(restored: restored)
        let (authenticator, listener, opened, restored) = (authenticator, listenerBridge, opened, restored)
        opening = Task.detached(priority: .userInitiated) {
            do {
                let core = try Core(
                    config: HostConfig(clientVersion: appVersion, storageDir: nil),
                    secrets: KeychainHostSecrets(keychain: keychain)
                )
                let service = try await core.openAccount(
                    config: config,
                    browser: NoLoopbackBrowser(),
                    webAuthenticator: authenticator,
                    listener: listener
                )
                opened.withLock { $0 = service }
                restored.mark(.opened)
                await listener.notify(signedOutBy: nil)
                return service
            } catch {
                Self.logger.error(
                    "The account did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)"
                )
                restored.mark(.opened)
                restored.mark(.restored)
                await listener.notify(signedOutBy: nil)
                return nil
            }
        }
    }

    var isRestored: Bool {
        restored.isOpen
    }

    func waitUntilRestored() async {
        await restored.wait()
    }

    @MainActor
    func setListener(_ listener: any AccountBackendListener) {
        listenerBridge.target = listener
    }

    private var service: AccountService? {
        opened.withLock { $0 }
    }

    private func awaitService() async throws(AccountError) -> AccountService {
        guard let service = await opening.value else { throw .network("the account did not open") }
        return service
    }

    // MARK: - Reads

    func status() -> AccountSnapshot {
        guard let service else { return AccountSnapshot() }
        return CoreAccountMapping.snapshot(service.status())
    }

    func featureAccess(code: String) -> ProFeatureAccess {
        guard let service else { return .signedOut }
        return CoreAccountMapping.access(service.featureAccess(feature: code))
    }

    func server() -> AccountServer {
        guard let service else { return .production }
        return CoreAccountMapping.server(service.server(), isDevelopmentStack: isDevelopmentStack) ?? .production
    }

    func license() -> AccountServerLicense? {
        service?.license().map(CoreAccountMapping.license)
    }

    // MARK: - Calls

    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) {
        let service = try await awaitService()
        self.authenticator.use(authenticator)
        defer { self.authenticator.use(nil) }
        try await Self.signingIn(service, .signIn) { try await service.signIn(cancel: nil) }
    }

    func signOut() async throws(AccountError) {
        let service = try await awaitService()
        try await Self.call(.other) { try await service.signOut() }
    }

    func refresh() async throws(AccountError) {
        let service = try await awaitService()
        try await Self.call(.other) { try await service.refresh() }
    }

    func refreshPastDeviceLimit() async throws(AccountError) -> Bool {
        let service = try await awaitService()
        return try await Self.call(.other) { try await service.refreshPastDeviceLimit() }
    }

    func useLicenseKey(_ key: String) async throws(AccountError) {
        let service = try await awaitService()
        try await Self.signingIn(service, .licenseKey) { try await service.useLicenseKey(key: key) }
    }

    func importOfflineFile(at url: URL) async throws(AccountError) {
        let service = try await awaitService()
        try await Self.call(.offlineFile) { try await service.importOfflineFile(path: url.path) }
    }

    func chooseServer(_ url: URL?) async throws(AccountError) {
        let service = try await awaitService()
        try await Self.call(.other) { try await service.chooseServer(url: url?.absoluteString) }
    }

    func profile() async throws(AccountError) -> AccountProfile {
        let service = try await awaitService()
        return CoreAccountMapping.profile(try await Self.call(.other) { try await service.profile() })
    }

    func devices() async throws(AccountError) -> [AccountDevice] {
        let service = try await awaitService()
        return try await Self.call(.other) { try await service.devices() }.map(CoreAccountMapping.device)
    }

    func removeDevice(_ id: String) async throws(AccountError) {
        let service = try await awaitService()
        try await Self.call(.other) { try await service.removeDevice(deviceId: id) }
    }

    func accessToken() async throws(AccountError) -> AccountAccessToken {
        let service = try await awaitService()
        let access = try await Self.call(.other) { try await service.accessToken() }
        guard let base = URL(string: access.apiUrl) else { throw .invalidResponse }
        return AccountAccessToken(token: access.token, apiBaseURL: base, sessionID: access.sessionId)
    }

    func accessTokenRejected(_ token: String) async {
        guard let service = await opening.value else { return }
        await service.accessTokenRejected(token: token)
    }

    func applyPolicy(_ policy: ManagedPolicyArg) async {
        guard let service = await opening.value else { return }
        service.applyPolicy(policy: policy)
    }

    func accountService() async -> AccountService? {
        await opening.value
    }

    // An account that did not open holds no values to allow anything by.
    func allowsTableProRequests() async -> Bool {
        guard let service = await opening.value else { return false }
        return service.allowsTableproRequests()
    }

    private static func call<T>(
        _ operation: CoreAccountMapping.Operation,
        _ body: () async throws -> T
    ) async throws(AccountError) -> T {
        do {
            return try await body()
        } catch let error as CoreError {
            throw CoreAccountMapping.error(error, during: operation)
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    // A sign-in the core kept stands though what followed it failed: the device registration or the first
    // entitlement, whose problem the status then carries.
    private static func signingIn(
        _ service: AccountService,
        _ operation: CoreAccountMapping.Operation,
        _ body: () async throws -> Void
    ) async throws(AccountError) {
        let before = service.status()
        do {
            try await body()
        } catch let error as CoreError {
            guard let failure = CoreAccountMapping.signInError(error, during: operation) else { return }
            if CoreAccountMapping.keptSignIn(before: before, after: service.status()) {
                logger.notice(
                    "Signed in; what followed failed: \(LogRedaction.publicDescription(of: failure), privacy: .public)"
                )
                return
            }
            throw failure
        } catch {
            throw .network(error.localizedDescription)
        }
    }
}

// The core calls the callbacks below on threads it lets block; each hops to the main actor and waits there.

// Shows the sign-in page in the window that asked for it, and returns the app.tablepro: redirect.
nonisolated private final class CoreWebAuthenticator: HostWebAuthenticator, @unchecked Sendable {
    private let current = OSAllocatedUnfairLock<(any WebAuthenticating)?>(initialState: nil)

    func use(_ authenticator: (any WebAuthenticating)?) {
        current.withLock { $0 = authenticator }
    }

    func cancel() {
        let authenticator = current.withLock { $0 }
        Task { @MainActor in authenticator?.cancel() }
    }

    func authenticate(url: String, callbackScheme: String) throws -> String {
        guard let target = URL(string: url), let authenticator = current.withLock({ $0 }) else {
            throw HostBrowserError.Failed(detail: "no sign-in window is open")
        }
        let result = BlockingResult<Result<URL, AccountError>>()
        Task { @MainActor in
            do throws(AccountError) {
                result.finish(.success(try await authenticator.authenticate(url: target, callbackScheme: callbackScheme)))
            } catch {
                result.finish(.failure(error))
            }
        }
        switch result.wait() {
        case .success(let callback)?:
            return callback.absoluteString
        case .failure(.canceled)?:
            throw HostBrowserError.Cancelled
        case .failure(let error)?:
            throw HostBrowserError.Failed(detail: String(describing: error))
        case nil:
            throw HostBrowserError.Failed(detail: "the sign-in window gave no answer")
        }
    }
}

// The Apple apps sign in through their web authenticator; the core asks the loopback browser only of a client that has
// none.
nonisolated private final class NoLoopbackBrowser: HostBrowser, @unchecked Sendable {
    func openUrl(url: String) throws {
        throw HostBrowserError.Failed(detail: "the app signs in through its web authenticator")
    }
}

nonisolated private final class CoreAccountListener: AccountListener, @unchecked Sendable {
    // Set once at launch and read only in notify, both on the main actor.
    nonisolated(unsafe) weak var target: (any AccountBackendListener)?
    private let restored: RestoredLatch

    init(restored: RestoredLatch) {
        self.restored = restored
    }

    // Each of the core's restore paths ends by publishing a status, and nothing publishes one before it, so the first
    // change is the restored account.
    func statusChanged() {
        restored.mark(.restored)
        Task { await notify(signedOutBy: nil) }
    }

    func signedOut(cause: SignOutCauseTag) {
        let mapped = CoreAccountMapping.cause(cause)
        Task { await notify(signedOutBy: mapped) }
    }

    @MainActor
    func notify(signedOutBy cause: AccountSignOutCause?) {
        target?.accountStatusChanged(signedOutBy: cause)
    }
}

// The core can publish the restored status before openAccount returns the service that reads it, so both count.
nonisolated private final class RestoredLatch: Sendable {
    enum Step {
        case opened
        case restored
    }

    private struct State {
        var opened = false
        var restored = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var isOpen: Bool { opened && restored }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    func mark(_ step: Step) {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isOpen else { return [] }
            switch step {
            case .opened: state.opened = true
            case .restored: state.restored = true
            }
            guard state.isOpen else { return [] }
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                state.waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

nonisolated private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)

    func finish(_ result: Value) {
        value.withLock { $0 = result }
        semaphore.signal()
    }

    func wait() -> Value? {
        semaphore.wait()
        return value.withLock { $0 }
    }
}
