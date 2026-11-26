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

    case signedIn(accountID: String, method: SignInMethod)
    case signedOut(AccountSignOutCause)
}

internal enum LegacyMigrationOutcome: Equatable, Sendable {
    case nothingToMigrate
    // A session owns this Mac, so the key is neither exchanged nor deleted.
    case keptWhileSignedIn
    // Refused before, or its session signed out: kept for Use License Key…, not exchanged on its own.
    case keptAside
    case migrated
    case keyRejected
    case retryLater(AccountError)
}

// The core's account (core/docs/decisions/0044-sync-through-one-service-run-by-us-or-on-premises.md) seen from the
// app: it publishes FeatureAccess, and the Swift Team Library and share clients take their bearer and server from it.
@MainActor
internal final class AccountServices: AccountBackendListener {
    static let shared = AccountServices.live()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountServices")
    // A stored key the network kept from its exchange is tried again this often, until it goes through.
    static let migrationRetryInterval: Duration = .seconds(60 * 60)

    let access: FeatureAccess
    let api: any APIProtocol
    let shares: any ShareService
    let events = PassthroughSubject<AccountEvent, Never>()
    private let backend: any AccountBackend
    // The account the sync service opens with; nil for a backend that has none.
    let syncAccount: (any SyncAccountProviding)?
    private let transport: any ClientTransport
    private let storedKey: StoredLicenseKey
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    private var isStarted = false
    private var checkTask: Task<Bool, Never>?
    private var expiryTask: Task<Void, Never>?
    private var migrationRetryTask: Task<Void, Never>?
    private var policyCancellable: AnyCancellable?
    private var policyTask: Task<Void, Never>?
    private var verifiedAt: Date?
    // Whether subscribers know of a session, so a sign-out reaches them once, whether the core's listener or the
    // call that caused it gets here first.
    private var announcedSession = false

    init(
        backend: any AccountBackend,
        syncAccount: (any SyncAccountProviding)? = nil,
        transport: any ClientTransport,
        storedKey: StoredLicenseKey,
        access: FeatureAccess,
        sharedLinkServer: URL = AccountServer.production.apiBaseURL,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.syncAccount = syncAccount
        self.transport = transport
        self.storedKey = storedKey
        self.access = access
        self.clock = clock
        self.now = now
        self.api = AccountAPI.client(backend: backend, transport: transport)
        // Shared links live on tablepro.app, or a Debug run's development stack: a share sheet left open across a
        // switch to a company server sends that server nothing.
        self.shares = CloudShareService(
            api: AccountAPI.client(backend: backend, transport: transport, onlyTo: sharedLinkServer),
            publicAPI: AccountAPI.publicClient(serverURL: sharedLinkServer, transport: transport),
            createRequest: ShareCreateRequest(
                serverURL: sharedLinkServer,
                transport: transport,
                middlewares: [AccountBearerMiddleware(backend: backend, onlyTo: sharedLinkServer)]
            ),
            allowsReading: { [backend] in await backend.allowsTableProRequests() }
        )
    }

    var machineID: String {
        backend.machineID
    }

    // A client whose calls go to this server under this sign-in only: under any other, a call reads as signed out and
    // is never sent.
    func api(pinnedTo server: AccountServer, session: String) -> any APIProtocol {
        AccountAPI.client(backend: backend, transport: transport, onlyTo: server.apiBaseURL, session: session)
    }

    var server: AccountServer {
        access.state.server
    }

    var portal: AccountPortal {
        AccountPortal(server: server)
    }

    var isSignedIn: Bool {
        access.state.isSignedIn
    }

    // The core runs its own refresh schedule; this publishes what it restored and exchanges a stored license key.
    // Each reading of the managed values goes to the core in order; one the setup already carried changes nothing.
    func start(policyChanges: AnyPublisher<ManagedPolicySnapshot, Never>? = nil) {
        guard !isStarted else { return }
        isStarted = true
        loadStoredState()
        Task { await checkNow() }
        let changes = policyChanges ?? ManagedPolicyCenter.shared.$snapshot.eraseToAnyPublisher()
        // Every reading reaches the core, so one that stops the server is never skipped for a later one.
        let (readings, reader) = AsyncStream.makeStream(of: ManagedPolicySnapshot.self)
        policyCancellable = changes.sink { reader.yield($0) }
        policyTask = Task { [backend] in
            for await policy in readings {
                await backend.applyPolicy(policy.coreArgument)
            }
        }
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        migrationRetryTask?.cancel()
        migrationRetryTask = nil
        policyCancellable = nil
        policyTask?.cancel()
        policyTask = nil
    }

    func allowsTableProRequests() async -> Bool {
        await backend.allowsTableProRequests()
    }

    // Back from the portal's device page, where the person may have freed a slot.
    func applicationDidBecomeActive() {
        guard isStarted, access.isPastDeviceLimit else { return }
        Task {
            do throws(AccountError) {
                _ = try await backend.refreshPastDeviceLimit()
            } catch {
                Self.logger.warning("Refresh past the device limit failed: \(error.publicLogShape, privacy: .public)")
            }
            publish()
        }
    }

    func loadStoredState() {
        publish()
    }

    // Until the core has restored the last sign-in the Mac may still be signed in, so a switch waits for that.
    private func isSignedOutOnceRestored() async -> Bool {
        await waitUntilRestored()
        return !isSignedIn
    }

    // For launch work a feature gates: it reads what the core restored, published.
    func waitUntilRestored() async {
        await backend.waitUntilRestored()
        publish()
    }

    // Signed in, another sign-in would switch accounts in this process; that goes through Sign Out instead.
    func signIn(using authenticator: some WebAuthenticating) async throws(AccountError) {
        guard await isSignedOutOnceRestored() else { throw .signOutFirst }
        try await backend.signIn(using: authenticator)
        verifiedAt = now()
        publish()
        announceSignIn(.interactive)
    }

    func signOut() async {
        do throws(AccountError) {
            try await backend.signOut()
        } catch {
            Self.logger.warning("The server was not told of the sign-out: \(error.publicLogShape, privacy: .public)")
        }
        storedKey.setAside()
        verifiedAt = nil
        publish()
        announceSignOut(.user)
    }

    // Nil drops the choice, for a configuration profile's default or else tablepro.app. The core signs out of the
    // server it leaves.
    func chooseServer(_ url: URL?) async throws(AccountError) {
        guard await isSignedOutOnceRestored() else { throw .signOutFirst }
        try await backend.chooseServer(url)
        verifiedAt = nil
        publish()
        if !isSignedIn {
            announceSignOut(.serverChanged)
        }
    }

    @discardableResult
    func refreshEntitlement() async -> EntitlementRefreshState {
        do throws(AccountError) {
            try await backend.refresh()
        } catch {
            Self.logger.warning("Entitlement refresh failed: \(error.publicLogShape, privacy: .public)")
            publish()
            if case .deviceLimitReached = access.state.refresh {
                return access.state.refresh
            }
            return .failed(error)
        }
        verifiedAt = now()
        publish()
        return access.state.refresh
    }

    // The gates' Try Again and Settings' Refresh: a stored key still waiting for its exchange goes first, since a
    // Mac without a session has nothing to refresh. One at a time.
    @discardableResult
    func checkNow() async -> Bool {
        if let checkTask {
            return await checkTask.value
        }
        let task = Task { await self.runCheck() }
        checkTask = task
        let succeeded = await task.value
        if checkTask == task {
            checkTask = nil
        }
        return succeeded
    }

    // Prefills Use License Key…: a key an older build stored.
    var storedLicenseKey: String? {
        storedKey.value()
    }

    var hasLicenseKeyToExchange: Bool {
        storedKey.value() != nil && !storedKey.isSetAside()
    }

    // Use License Key…, signed out only: a stored key it matches is deleted once the Keychain holds the sign-in.
    @discardableResult
    func useLicenseKey(_ key: String) async throws(AccountError) -> EntitlementRefreshState {
        guard await isSignedOutOnceRestored() else { throw .signOutFirst }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try await backend.useLicenseKey(key)
        if key == storedKey.value() {
            clearStoredKeyIfRemembered()
        }
        verifiedAt = now()
        publish()
        announceSignIn(.licenseKey)
        return access.state.refresh
    }

    func migrateLegacyKeyIfNeeded() async -> LegacyMigrationOutcome {
        guard let key = storedKey.value() else { return .nothingToMigrate }
        guard !storedKey.isSetAside() else { return .keptAside }
        // An exchange replaces the session, so the core must have read the last run's first.
        await backend.waitUntilRestored()
        publish()
        guard !isSignedIn else { return .keptWhileSignedIn }
        do throws(AccountError) {
            try await backend.useLicenseKey(key)
        } catch .oauth("invalid_grant", _) {
            Self.logger.notice("The stored license key was refused; keeping it aside")
            storedKey.setAside()
            publish()
            return .keyRejected
        } catch {
            Self.logger.warning("License key exchange failed, retrying later: \(error.publicLogShape, privacy: .public)")
            publish()
            return .retryLater(error)
        }
        clearStoredKeyIfRemembered()
        verifiedAt = now()
        publish()
        announceSignIn(.migration)
        return .migrated
    }

    func fetchProfile() async throws(AccountError) -> AccountProfile {
        try await backend.profile()
    }

    func fetchDevices() async throws(AccountError) -> [AccountDevice] {
        try await backend.devices()
    }

    func removeDevice(_ deviceID: String) async throws(AccountError) {
        try await backend.removeDevice(deviceID)
        _ = await refreshEntitlement()
    }

    func importOfflineFile(at url: URL) async throws(AccountError) {
        try await backend.importOfflineFile(at: url)
        publish()
    }

    // MARK: - AccountBackendListener

    // A sign-out the person asked for is announced by the call that made it.
    func accountStatusChanged(signedOutBy cause: AccountSignOutCause?) {
        if cause != nil {
            verifiedAt = nil
        }
        publish()
        guard let cause, cause != .user, !isSignedIn else { return }
        Self.logger.notice("Signed out on this Mac: \(String(describing: cause), privacy: .public)")
        announceSignOut(cause)
    }

    // MARK: - Private

    private func runCheck() async -> Bool {
        switch await migrateLegacyKeyIfNeeded() {
        case .retryLater:
            scheduleMigrationRetry()
            return false
        case .migrated, .keyRejected:
            return true
        case .nothingToMigrate, .keptWhileSignedIn, .keptAside:
            break
        }
        guard isSignedIn else {
            publish()
            return true
        }
        if case .failed = await refreshEntitlement() {
            return false
        }
        return true
    }

    // A sign-in the Keychain refused ends with this run, and the key is what signs the next one in again. One it kept
    // comes back on tablepro.app, the only server a key signs in to, with or without account.json.
    private func clearStoredKeyIfRemembered() {
        guard backend.status().remembered else {
            Self.logger.warning("The Keychain did not keep the sign-in; keeping the stored license key")
            return
        }
        storedKey.clear()
    }

    // The core never sees a stored key, so its refresh schedule cannot retry the exchange.
    private func scheduleMigrationRetry() {
        guard isStarted, migrationRetryTask == nil else { return }
        migrationRetryTask = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: Self.migrationRetryInterval)) != nil else { return }
            self?.migrationRetryTask = nil
            await self?.checkNow()
        }
    }

    private func announceSignIn(_ method: AccountEvent.SignInMethod) {
        guard let accountID = access.state.entitlement?.accountID ?? backend.status().accountID else { return }
        announcedSession = true
        events.send(.signedIn(accountID: accountID, method: method))
    }

    private func announceSignOut(_ cause: AccountSignOutCause) {
        guard announcedSession else { return }
        announcedSession = false
        events.send(.signedOut(cause))
    }

    private func publish() {
        // Read before the snapshot: once the restore is marked, the snapshot read after it holds what it restored.
        let isRestored = backend.isRestored
        let snapshot = backend.status()
        let entitlement = Entitlement(snapshot)
        var features: [ProFeature: ProFeatureAccess] = [:]
        for feature in ProFeature.allCases {
            features[feature] = backend.featureAccess(code: feature.rawValue)
        }
        let refresh: EntitlementRefreshState
        switch snapshot.problem {
        case .deviceLimitReached(let holders):
            refresh = .deviceLimitReached(holders)
        case .refreshFailed(let error):
            refresh = .failed(error)
        case .expired, nil:
            refresh = snapshot.state == .signedIn ? verifiedAt.map(EntitlementRefreshState.succeeded) ?? .idle : .idle
        }
        if snapshot.state == .signedIn {
            announcedSession = true
        }
        let license = backend.license()
        access.update(AccountState(
            isSignedIn: snapshot.state == .signedIn,
            entitlement: entitlement,
            refresh: refresh,
            server: backend.server(),
            serverLicense: license,
            features: features,
            verifiedAt: verifiedAt,
            isRestored: isRestored,
            sessionID: snapshot.sessionID
        ))
        let current = now()
        let boundaries = [entitlement?.expiresAt, license?.expiresAt, license?.graceEndsAt].compactMap { $0 }
        scheduleExpiry(boundaries.filter { $0 > current }.min())
    }

    // The gate reads what the core answered at the last publish, so one is due when the entitlement lapses, and
    // when a company server's license enters its grace or leaves it.
    private func scheduleExpiry(_ expiresAt: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiresAt else { return }
        let delay = expiresAt.timeIntervalSince(now())
        guard delay > 0 else { return }
        expiryTask = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: .seconds(delay + 1))) != nil else { return }
            self?.publish()
        }
    }
}
