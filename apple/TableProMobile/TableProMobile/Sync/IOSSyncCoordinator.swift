import CloudKit
import Combine
import Foundation
import Observation
import os
import TableProFFI
import TableProSyncTransport

// iCloud on the core engine (core ADR 0054, The Apple apps on the engine). The engine syncs every record type iCloud
// carries; this decides whether iCloud runs on this device, tells the engine the provider, and asks for a pass at
// launch, on activation, when the network returns, on a CloudKit notice and when the person asks. The transport is open
// only while iCloud runs, so a switch the person or the organization turns off sends nothing more, an upload in flight
// included.
@MainActor @Observable
final class IOSSyncCoordinator {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    // While CloudKit's notices reach the device they bring other devices' changes, so an activation only covers a lost
    // one. The same rule as the Mac's.
    nonisolated static let activationInterval: Duration = .seconds(60)
    nonisolated static let pushFallbackInterval: Duration = .seconds(15 * 60)

    private(set) var status: SyncStatus
    private(set) var lastSyncDate: Date?

    @ObservationIgnored let metadata: SyncMetadataStorage
    @ObservationIgnored let pushChannel: SyncPushChannel
    // After each pass the engine finished, so the stores' readers take what it wrote.
    @ObservationIgnored var onPassFinished: (() -> Void)?

    @ObservationIgnored let host: IOSSyncEngineHost
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let database: any CloudKitDatabase
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let makeNetworkMonitor: () -> SyncNetworkMonitor?
    @ObservationIgnored private let activationClock: any Clock<Duration>

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var triggers: IOSSyncTriggers?
    @ObservationIgnored private var currentPass: Task<Void, Never>?
    @ObservationIgnored private var pendingPass: PassReasonTag?
    @ObservationIgnored private var activationCooldown: Task<Void, Never>?
    @ObservationIgnored private var activationHeld = false
    @ObservationIgnored private var lastPassMs: Int64?
    // Each turn of iCloud on or off, so a pass that began before one changes nothing after it.
    @ObservationIgnored private var generation = 0
    // Every provider the engine is told, in order: a pass waits for the off before it, and an off follows the on.
    @ObservationIgnored private var providerChoice: Task<Void, Never>?

    init(
        host: IOSSyncEngineHost,
        metadata: SyncMetadataStorage,
        isEnabled: @escaping () -> Bool = { AppPreferences.isCloudSyncEnabled },
        database: any CloudKitDatabase = LiveCloudKitDatabase(),
        notificationCenter: NotificationCenter = .default,
        makeNetworkMonitor: @escaping () -> SyncNetworkMonitor? = { SyncNetworkMonitor() },
        activationClock: any Clock<Duration> = ContinuousClock(),
        pushRegistrar: SyncPushRegistrar = .live
    ) {
        self.host = host
        self.metadata = metadata
        self.isEnabled = isEnabled
        self.database = database
        self.notificationCenter = notificationCenter
        self.makeNetworkMonitor = makeNetworkMonitor
        self.activationClock = activationClock
        pushChannel = SyncPushChannel(registrar: pushRegistrar, metadata: metadata)
        status = .disabled(.userDisabled)
        lastSyncDate = metadata.lastSyncDate
    }

    var hasCompletedFirstSync: Bool {
        lastSyncDate != nil
    }

    var isHoldingActivations: Bool {
        activationCooldown != nil
    }

    // Read with sync off too, so the first-run sheet can tell whether iCloud is there to turn on.
    func accountStatus() async -> CKAccountStatus {
        do {
            return try await database.accountStatus()
        } catch {
            Self.logger.warning("iCloud account status unavailable: \(error.localizedDescription, privacy: .private)")
            return .couldNotDetermine
        }
    }

    // MARK: - Lifecycle

    // Once the library has loaded, so the first pass reads it.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        host.onSignal = { [weak self] in self?.engineSignalled() }
        evaluate()
        requestPass(.launch)
    }

    // At launch, from the app delegate: nothing registers while sync is off.
    func registerForPushesIfEnabled() {
        guard isEnabled() else { return }
        pushChannel.register()
    }

    // The person's switch, and the organization's managed configuration once the app reads it.
    func setEnabled(_ enabled: Bool) {
        guard enabled, isEnabled() else {
            stop(.disabled(.userDisabled))
            return
        }
        pushChannel.forgetSubscription()
        evaluate()
        requestPass(.person)
    }

    // After TablePro's data was removed from iCloud, nothing is uploaded until the person asks.
    func uploadAgain() async {
        await passesFinished()
        guard status.error == .blocked(.dataDeletedFromICloud), let engine = try? await host.engine(for: .icloud) else { return }
        pushChannel.forgetSubscription()
        do {
            try await engine.uploadAgain()
        } catch {
            Self.logger.error("Upload Again failed: \(error.localizedDescription, privacy: .private)")
            refreshStatus()
            return
        }
        requestPass(.person)
        await passesFinished()
    }

    // MARK: - Passes

    // Runs once whatever pass is out has finished; a trigger that arrives during one runs once after it.
    func sync(_ trigger: SyncTrigger = .userRequest) async {
        if trigger == .remoteChange {
            pushChannel.noticeArrived()
        }
        requestPass(Self.reason(for: trigger))
        await passesFinished()
    }

    // The scene came forward. After a pass, activations wait out the interval and then run once, so a change made on
    // another device still arrives.
    func syncOnSceneActivation() async {
        guard status.isEnabled else { return }
        if currentPass != nil {
            pendingPass = SyncEngineRules.stronger(pendingPass, .foreground)
            return
        }
        if activationCooldown != nil {
            activationHeld = true
            return
        }
        await sync(.activation)
    }

    func passesFinished() async {
        while let pass = currentPass {
            await pass.value
        }
    }

    // A move waits for these too, so the Off told when iCloud stops reaches iCloud's service before another opens.
    func passesAndChoicesFinished() async {
        await passesFinished()
        while let choice = providerChoice {
            await choice.value
            guard providerChoice == choice else { continue }
            return
        }
    }

    nonisolated static func reason(for trigger: SyncTrigger) -> PassReasonTag {
        switch trigger {
        case .launch: return .launch
        case .activation, .scheduledRetry: return .foreground
        case .remoteChange: return .cloudKitPush
        case .localChange: return .journal
        case .accountChange: return .accountChanged
        case .networkRestored: return .networkBack
        case .userRequest: return .person
        }
    }

    private func requestPass(_ why: PassReasonTag) {
        guard status.isEnabled else { return }
        guard currentPass == nil else {
            pendingPass = SyncEngineRules.stronger(pendingPass, why)
            return
        }
        currentPass = Task { [weak self] in
            await self?.runPass(why)
        }
    }

    private func runPass(_ why: PassReasonTag) async {
        let started = generation
        guard status.isEnabled else {
            finishPass()
            return
        }
        // A standing condition stays on screen through the automatic passes that check on it; only the person's own
        // request shows progress over it.
        if why == .person || status.error == nil {
            status = .syncing
        }
        do {
            try await choose(.icloud) { [weak self] in self?.generation == started }.value.get()
            if started == generation {
                try await host.engine(for: .icloud).syncNow(why: why)
            }
        } catch {
            Self.logger.error("A sync pass failed: \(error.localizedDescription, privacy: .private)")
        }
        if started == generation {
            await saveSubscriptionIfNeeded()
            host.rememberICloudAccount()
        }
        if started == generation, status.isEnabled {
            refreshStatus()
            if host.openedEngine(for: .icloud) == nil {
                // The engine did not open for iCloud, so there is none to sync with.
                status = .error(.unexpected)
            } else if status.error == nil {
                startActivationCooldown()
            }
        }
        finishPass()
    }

    private func finishPass() {
        currentPass = nil
        // iCloud turned on again while a pass from before the stop was out: only now may CloudKit be reached.
        if status.isEnabled, host.transport.isClosed {
            host.transport.open()
            refreshStatus()
        }
        if let pending = pendingPass {
            pendingPass = nil
            requestPass(pending)
        }
    }

    // Queued behind every earlier choice when it is made, not when it runs. The engine is asked only when it does not
    // hold the provider already, and a choice whose turn is over by then is dropped.
    private func choose(
        _ provider: SyncProviderTag,
        while isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Result<Void, any Error>, Never> {
        let previous = providerChoice
        let host = host
        let choice = Task<Result<Void, any Error>, Never> {
            await previous?.value
            do {
                let engine = try await host.engine(for: provider)
                guard isCurrent() else { return .success(()) }
                if engine.status().provider != provider {
                    try await engine.chooseProvider(provider: provider)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        providerChoice = Task { _ = await choice.value }
        return choice
    }

    private func saveSubscriptionIfNeeded() async {
        let transport = host.transport
        guard let account = transport.confirmedAccount else { return }
        await pushChannel.saveSubscriptionIfNeeded(account: account) {
            try await transport.saveSubscription(account: account)
        }
    }

    // The engine also runs passes of its own, after a store write; each one finished is a pass the stores may reflect.
    private func engineSignalled() {
        refreshStatus()
    }

    private func refreshStatus() {
        guard let engine = host.openedEngine(for: .icloud) else { return }
        let info = engine.status()
        if info.lastPassMs != lastPassMs {
            lastPassMs = info.lastPassMs
            if info.lastPassMs != nil {
                onPassFinished?()
            }
        }
        guard status.isEnabled else { return }
        status = SyncEngineRules.status(info)
        lastSyncDate = info.lastPassMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? metadata.lastSyncDate
    }

    private func startActivationCooldown() {
        activationCooldown?.cancel()
        activationHeld = false
        let clock = activationClock
        let interval = pushChannel.isLive(account: host.transport.confirmedAccount)
            ? Self.pushFallbackInterval
            : Self.activationInterval
        activationCooldown = Task { [weak self] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            // A newer pass may have replaced this hold after the sleep ended.
            guard !Task.isCancelled, let self else { return }
            activationCooldown = nil
            guard activationHeld else { return }
            activationHeld = false
            await syncOnSceneActivation()
        }
    }

    // MARK: - Status

    private func evaluate() {
        guard isEnabled() else {
            stop(.disabled(.userDisabled))
            return
        }
        guard case .disabled = status else { return }
        generation += 1
        status = .idle
        // A pass from before the stop may still be out; it opens the transport once it ends.
        if currentPass == nil {
            host.transport.open()
        }
        arm()
        refreshStatus()
    }

    // What is in flight stops, and nothing more reaches CloudKit until iCloud runs again (P1-I3).
    private func stop(_ next: SyncStatus) {
        host.transport.close()
        let wasRunning = status.isEnabled
        status = next
        pendingPass = nil
        disarm()
        guard wasRunning else { return }
        generation += 1
        metadata.lastSyncDate = nil
        lastSyncDate = nil
        let choice = choose(.off)
        Task {
            if case .failure(let error) = await choice.value {
                Self.logger.error("The engine did not take iCloud off: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Observers

    private func arm() {
        guard triggers == nil else { return }
        triggers = IOSSyncTriggers(
            notificationCenter: notificationCenter,
            accountObserver: observeAccountChanges(),
            networkMonitor: observeNetwork()
        )
        pushChannel.register()
    }

    private func disarm() {
        pushChannel.unregister()
        triggers = nil
        activationCooldown?.cancel()
        activationCooldown = nil
        activationHeld = false
    }

    // What is in flight belongs to the account that was signed in. The next pass reads the account and the engine opens
    // the state file of the one it finds.
    private func observeAccountChanges() -> any NSObjectProtocol {
        notificationCenter.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, status.isEnabled else { return }
                host.transport.cancelCallsInFlight()
                requestPass(.accountChanged)
            }
        }
    }

    // A return during a pass is kept for when it ends, since the monitor reports it only once.
    private func observeNetwork() -> SyncNetworkMonitor? {
        let monitor = makeNetworkMonitor()
        monitor?.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if currentPass != nil {
                    pendingPass = SyncEngineRules.stronger(pendingPass, .networkBack)
                } else if status.error == .offline {
                    requestPass(.networkBack)
                }
            }
        }
        return monitor
    }
}

// What starts a pass while iCloud runs. Releasing it detaches every observer; the network monitor stops in its deinit.
nonisolated private final class IOSSyncTriggers {
    private let notificationCenter: NotificationCenter
    private let accountObserver: any NSObjectProtocol
    private let networkMonitor: SyncNetworkMonitor?

    init(notificationCenter: NotificationCenter, accountObserver: any NSObjectProtocol, networkMonitor: SyncNetworkMonitor?) {
        self.notificationCenter = notificationCenter
        self.accountObserver = accountObserver
        self.networkMonitor = networkMonitor
    }

    deinit {
        notificationCenter.removeObserver(accountObserver)
    }
}
