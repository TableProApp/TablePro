//
//  CoreAccountBackend.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The core's AccountService (core/docs/decisions/0047-the-apple-apps-sign-in-through-the-core.md). It opens on a task
// at launch; until then the account reads as signed out, and a call waits for it.
internal final class CoreAccountBackend: AccountBackend, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreAccountBackend")

    let machineID: String
    private let authenticator = CoreWebAuthenticator()
    private let listenerBridge = CoreAccountListener()
    private let opened = OSAllocatedUnfairLock<AccountService?>(initialState: nil)
    private let opening: Task<AccountService?, Never>

    init(setup: AccountCoreSetup, machine: MachineDescription, keychain: AccountKeychain) {
        machineID = setup.machineID
        let config = Self.config(setup, machine: machine)
        let (authenticator, listener, opened) = (authenticator, listenerBridge, opened)
        opening = Task.detached(priority: .userInitiated) {
            do {
                let core = try Core(
                    config: HostConfig(clientVersion: machine.appVersion, storageDir: nil),
                    secrets: KeychainHostSecrets(keychain: keychain)
                )
                let service = try await core.openAccount(
                    config: config,
                    browser: NoLoopbackBrowser(),
                    webAuthenticator: authenticator,
                    listener: listener
                )
                opened.withLock { $0 = service }
                await listener.notify(signedOutBy: nil)
                return service
            } catch {
                Self.logger.error("The account did not open: \(error.publicLogShape, privacy: .public)")
                return nil
            }
        }
    }

    @MainActor
    func setListener(_ listener: any AccountBackendListener) {
        listenerBridge.target = listener
    }

    private static func config(_ setup: AccountCoreSetup, machine: MachineDescription) -> AccountConfig {
        let stack = setup.developmentStack
        return AccountConfig(
            accountUrl: stack?.accountURL,
            apiUrl: stack?.apiURL,
            entitlementKeys: stack?.entitlementKeys ?? [],
            deviceName: machine.name,
            appVersion: machine.appVersion,
            osVersion: machine.osVersion,
            accountFile: setup.accountFile.path,
            callbackFinished: "",
            callbackUnknown: "",
            machineGuid: nil,
            client: .macos,
            machineId: setup.machineID,
            managedServerUrl: setup.managedServerURL,
            allowOtherServers: setup.allowOtherServers,
            legacyEntitlementFile: setup.legacyEntitlementFile.path,
            licenseKeys: stack?.licenseKeys ?? []
        )
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

    func featureAccess(_ feature: ProFeature) -> ProFeatureAccess {
        guard let service else { return .signedOut }
        return CoreAccountMapping.access(service.featureAccess(feature: feature.rawValue))
    }

    func server() -> AccountServer {
        guard let service else { return .production }
        return CoreAccountMapping.server(service.server()) ?? .production
    }

    func license() -> AccountServerLicense? {
        service?.license().map(CoreAccountMapping.license)
    }

    // MARK: - Calls

    func signIn(using authenticator: any WebAuthenticating) async throws(AccountError) {
        let service = try await awaitService()
        self.authenticator.use(authenticator)
        defer { self.authenticator.use(nil) }
        try await Self.call(.signIn) { try await service.signIn(cancel: nil) }
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
        try await Self.call(.licenseKey) { try await service.useLicenseKey(key: key) }
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
        return AccountAccessToken(token: access.token, apiBaseURL: base)
    }

    func accessTokenRejected(_ token: String) async {
        guard let service = await opening.value else { return }
        await service.accessTokenRejected(token: token)
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
}

// The core calls the callbacks below on threads it lets block; each hops to the main actor and waits there.

// Shows the sign-in page in the window that asked for it, and returns the app.tablepro: redirect.
private final class CoreWebAuthenticator: HostWebAuthenticator, @unchecked Sendable {
    private let current = OSAllocatedUnfairLock<(any WebAuthenticating)?>(initialState: nil)

    func use(_ authenticator: (any WebAuthenticating)?) {
        current.withLock { $0 = authenticator }
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

// The Mac signs in through its web authenticator; the core asks the loopback browser only of a client that has none.
private final class NoLoopbackBrowser: HostBrowser, @unchecked Sendable {
    func openUrl(url: String) throws {
        throw HostBrowserError.Failed(detail: "the Mac signs in through its web authenticator")
    }
}

private final class CoreAccountListener: AccountListener, @unchecked Sendable {
    // Set once at launch and read only in notify, both on the main actor.
    nonisolated(unsafe) weak var target: (any AccountBackendListener)?

    func statusChanged() {
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

private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
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
