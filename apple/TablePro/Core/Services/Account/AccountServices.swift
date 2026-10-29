//
//  AccountServices.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProCloudAPI

internal enum AccountEvent: Equatable, Sendable {
    enum SignInMethod: String, Sendable {
        case interactive
        case licenseKey = "license_key"
        case migration
    }

    enum SignOutCause: Equatable, Sendable {
        case user
        case refreshRefused
        case deviceRevoked
    }

    case signedIn(accountID: String, method: SignInMethod)
    case signedOut(SignOutCause)
}

internal enum LegacyMigrationOutcome: Equatable, Sendable {
    case nothingToMigrate
    // An interactive sign-in owns this Mac's session, so the key is neither exchanged nor deleted.
    case keptWhileSignedIn
    case migrated
    case keyRejected
    case retryLater(AccountError)
}

// Wires the session, the device registry and the entitlement store, and keeps FeatureAccess current.
@MainActor
internal final class AccountServices {
    static let shared = AccountServices.live()

    static let refreshInterval: Duration = .seconds(24 * 60 * 60)
    static let retryInterval: Duration = .seconds(60 * 60)

    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountServices")

    let configuration: AccountConfiguration
    let session: AccountSession
    let devices: DeviceRegistry
    let access: FeatureAccess
    let api: any APIProtocol
    let events = PassthroughSubject<AccountEvent, Never>()
    private let entitlements: EntitlementStore
    private let legacy: LegacyLicenseStore
    private let machine: MachineDescription
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    private var entitlement: Entitlement?
    private var legacyEntitlement: LegacyEntitlement?
    private var refreshTask: Task<EntitlementRefreshState, Never>?
    private var checkTask: Task<Bool, Never>?
    private var scheduleTask: Task<Void, Never>?
    // Bumped by sign-out, so a refresh still out at that moment adopts nothing it brings back.
    private var sessionGeneration = 0

    init(
        configuration: AccountConfiguration,
        machine: MachineDescription,
        transport: any ClientTransport,
        send: @escaping AccountHTTPSend,
        keychain: any KeychainStoring,
        entitlementFile: URL,
        legacy: LegacyLicenseStore,
        access: FeatureAccess,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let refusals = RefusalRelay()
        self.configuration = configuration
        self.machine = machine
        self.session = AccountSession(
            client: OAuthTokenClient(configuration: configuration, send: send),
            keychain: keychain,
            now: now,
            onRefused: { Task { @MainActor in refusals.services?.sessionWasRefused() } }
        )
        self.api = AccountAPI.client(configuration: configuration, transport: transport, session: session)
        self.devices = DeviceRegistry(api: api, machine: machine)
        self.entitlements = EntitlementStore(
            fileURL: entitlementFile,
            verifier: EntitlementVerifier(publicKeys: configuration.entitlementKeys),
            machine: machine,
            now: now
        )
        self.legacy = legacy
        self.access = access
        self.clock = clock
        self.now = now
        refusals.services = self
    }

    // Reads what is on disk, then migrates a stored license key and refreshes now and every 24 hours.
    func start() {
        guard scheduleTask == nil else { return }
        loadStoredState()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.checkNow()
                // Past the device limit, a slot freed in the portal or on another device unlocks this Mac within the hour.
                let delay = succeeded && !self.access.isPastDeviceLimit ? Self.refreshInterval : Self.retryInterval
                do {
                    try await self.clock.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    // Back from the portal's device page, where the user may have freed a slot.
    func applicationDidBecomeActive() {
        guard scheduleTask != nil, access.isPastDeviceLimit else { return }
        Task { await checkNow() }
    }

    func loadStoredState() {
        entitlement = entitlements.load()
        legacyEntitlement = legacy.entitlement()
        publish()
    }

    func signIn(using authenticator: some WebAuthenticating) async throws(AccountError) {
        let request = AuthorizationRequest.make(configuration: configuration, machine: machine)
        let callback = try await authenticator.authenticate(
            url: request.url,
            callbackScheme: AccountConfiguration.callbackScheme
        )
        try await session.completeSignIn(request, callback: callback)
        publish(refresh: .idle)
        await announceSignIn(.interactive)
        _ = await refreshEntitlement()
    }

    func signOut() async {
        let wasSignedIn = session.isSignedIn
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        await session.signOut()
        dropEntitlement()
        legacy.clear()
        legacyEntitlement = nil
        publish(refresh: .idle)
        if wasSignedIn {
            events.send(.signedOut(.user))
        }
    }

    @discardableResult
    func refreshEntitlement() async -> EntitlementRefreshState {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let outcome = await task.value
        if refreshTask == task {
            refreshTask = nil
        }
        return outcome
    }

    // The schedule, the gates' Try Again and Settings' Refresh: a stored key still waiting for its exchange is
    // retried before any entitlement refresh, which a Mac without a session could not run. One at a time.
    @discardableResult
    func checkNow() async -> Bool {
        if let checkTask {
            return await checkTask.value
        }
        let task = Task { await self.runScheduledWork() }
        checkTask = task
        let succeeded = await task.value
        if checkTask == task {
            checkTask = nil
        }
        return succeeded
    }

    var storedLicenseKey: String? {
        legacy.licenseKey()
    }

    var machineID: String {
        machine.machineID
    }

    // Use License Key…: the key's account replaces any session on this Mac, and a stored key it matches is deleted.
    func useLicenseKey(_ key: String) async throws(AccountError) -> EntitlementRefreshState {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacesSession = session.isSignedIn
        try await session.signIn(licenseKey: key, machine: machine)
        sessionGeneration += 1
        refreshTask = nil
        if replacesSession {
            dropEntitlement()
        }
        if key == legacy.licenseKey() {
            legacy.clear()
            legacyEntitlement = nil
        }
        publish(refresh: .idle)
        await announceSignIn(.licenseKey)
        _ = try await devices.register()
        return await refreshEntitlement()
    }

    func fetchProfile() async throws(AccountError) -> AccountProfile {
        try await AccountProfile.fetch(api: api)
    }

    func fetchDevices() async throws(AccountError) -> [AccountDevice] {
        try await devices.list().map(AccountDevice.init)
    }

    func migrateLegacyKeyIfNeeded() async -> LegacyMigrationOutcome {
        guard let key = legacy.licenseKey() else { return .nothingToMigrate }
        if session.isSignedIn {
            // Resumes this key's own exchange; a session from another key typed into Use License Key… leaves it stored.
            guard session.wasExchanged(from: key) else { return .keptWhileSignedIn }
        } else {
            do throws(AccountError) {
                try await session.signIn(licenseKey: key, machine: machine)
                await announceSignIn(.migration)
            } catch .oauth("invalid_grant", _) {
                Self.logger.notice("The stored license key was refused; removing it")
                legacy.clear()
                legacyEntitlement = nil
                publish()
                return .keyRejected
            } catch {
                Self.logger.warning("License key exchange failed, retrying later: \(error.publicLogShape, privacy: .public)")
                return .retryLater(error)
            }
        }
        do throws(AccountError) {
            // The exchange's tokens name the device already, so no refresh follows the registration.
            _ = try await devices.register()
        } catch {
            return .retryLater(error)
        }
        switch await refreshEntitlement() {
        case .succeeded, .deviceLimitReached:
            legacy.clear()
            legacyEntitlement = nil
            publish()
            return .migrated
        case .failed(let error):
            return .retryLater(error)
        case .idle:
            return .retryLater(.signedOut)
        }
    }

    func importOfflineFile(at url: URL) async throws(AccountError) {
        let imported = try entitlements.readOfflineFile(at: url)
        do {
            try entitlements.save(imported)
        } catch {
            throw .network(error.localizedDescription)
        }
        entitlement = imported
        publish()
    }

    func removeDevice(_ deviceID: String) async throws(AccountError) {
        try await devices.remove(deviceID: deviceID)
        _ = await refreshEntitlement()
    }

    // MARK: - Private

    private func runScheduledWork() async -> Bool {
        switch await migrateLegacyKeyIfNeeded() {
        case .retryLater:
            return false
        case .migrated, .keyRejected:
            return true
        case .nothingToMigrate, .keptWhileSignedIn:
            break
        }
        guard session.isSignedIn else {
            publish()
            return true
        }
        if case .failed = await refreshEntitlement() {
            return false
        }
        return true
    }

    private func performRefresh() async -> EntitlementRefreshState {
        let generation = sessionGeneration
        let fetched: Result<EntitlementFetchResult, AccountError>
        do throws(AccountError) {
            fetched = .success(try await fetchEntitlement())
        } catch {
            fetched = .failure(error)
        }
        guard generation == sessionGeneration else { return .idle }

        let outcome: EntitlementRefreshState
        switch fetched {
        case .success(.issued(let issued)):
            do {
                try entitlements.save(issued)
            } catch {
                Self.logger.error("Could not store the entitlement: \(error.publicLogShape, privacy: .public)")
            }
            entitlement = issued
            outcome = .succeeded(now())
        case .success(.deviceLimitReached(let holders)):
            outcome = .deviceLimitReached(holders)
        case .failure(let error) where error.problemCode == "device_revoked":
            Self.logger.notice("This device was removed from the account; signing out on this Mac")
            await session.discard()
            events.send(.signedOut(.deviceRevoked))
            outcome = .failed(error)
        case .failure(let error):
            Self.logger.warning("Entitlement refresh failed: \(error.publicLogShape, privacy: .public)")
            outcome = .failed(error)
        }
        publish(refresh: outcome)
        return outcome
    }

    private func fetchEntitlement() async throws(AccountError) -> EntitlementFetchResult {
        var token = try await session.accessToken()
        if token.deviceID == nil {
            _ = try await devices.register()
            token = try await session.refreshNow()
        }
        guard let deviceID = token.deviceID else { throw .invalidResponse }
        return try await entitlements.fetch(api: api, deviceID: deviceID)
    }

    private func announceSignIn(_ method: AccountEvent.SignInMethod) async {
        guard let accountID = await session.accountID else { return }
        events.send(.signedIn(accountID: accountID, method: method))
    }

    // Another call's refresh found the refresh token refused, and the session discarded it.
    private func sessionWasRefused() {
        events.send(.signedOut(.refreshRefused))
        publish()
    }

    private func dropEntitlement() {
        entitlements.clear()
        entitlement = nil
    }

    private func publish(refresh: EntitlementRefreshState? = nil) {
        var state = access.state
        state.isSignedIn = session.isSignedIn
        state.entitlement = entitlement
        state.legacy = legacyEntitlement
        if let refresh {
            state.refresh = refresh
        }
        access.update(state)
    }
}

// Lets the session, created before the services that own it, report a refused refresh token to them.
@MainActor
private final class RefusalRelay {
    weak var services: AccountServices?
}
