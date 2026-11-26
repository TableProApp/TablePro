//
//  SyncProviderCoordinator.swift
//  TablePro
//

import CloudKit
import Combine
import Foundation
import os
import TableProFFI
import TableProSyncTransport

// iCloud on the core engine (core ADR 0054, The Apple apps on the engine). The engine syncs; this decides whether
// iCloud runs on this Mac, tells the engine the provider, and asks for a pass on launch, on foreground, when the network
// returns, on a CloudKit notice and when the person asks. The transport is open only while iCloud runs, so a provider
// the organization stops sends nothing more, an upload in flight included.
@MainActor
final class SyncProviderCoordinator: ObservableObject {
    static let shared = SyncProviderCoordinator()
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "SyncProviderCoordinator")

    // While CloudKit's notices reach this Mac they bring other devices' changes, so an activation only covers a lost one.
    nonisolated static let activationInterval: Duration = .seconds(60)
    nonisolated static let pushFallbackInterval: Duration = .seconds(15 * 60)
    // A burst of edits, such as a drag across a list, asks for one pass.
    nonisolated static let journalDebounce: Duration = .seconds(2)

    @Published private(set) var syncStatus: SyncStatus = .disabled(.userDisabled)
    @Published private(set) var lastSyncDate: Date?

    let pushChannel: SyncPushChannel
    private let makeHost: () -> SyncEngineHost
    private lazy var host = makeHost()
    private let loadSettings: @MainActor () -> SyncSettings
    private let licenseGate: @MainActor () -> DisableReason?
    private let policyGate: @MainActor () -> DisableReason?
    private let policyChanges: AnyPublisher<DisableReason?, Never>
    private let licenseChanges: AnyPublisher<Void, Never>
    private let journal: SyncHostJournal
    private let makeNetworkMonitor: () -> SyncNetworkMonitor?
    private let metadata: SyncMetadataStorage
    private let activationClock: any Clock<Duration>
    private let notificationCenter: NotificationCenter

    private var hasStarted = false
    private var observers: Set<AnyCancellable> = []
    private var triggers: SyncProviderTriggers?
    private var currentPass: Task<Void, Never>?
    private var pendingPass: PassReasonTag?
    private var activationCooldown: Task<Void, Never>?
    private var activationHeld = false
    private var journalPass: Task<Void, Never>?
    // Host changes are told to the engine in order, and a pass waits for those before it. One the engine did not take
    // goes again with the next.
    private var journalDelivery: Task<Void, Never>?
    private var undelivered = SyncHostChangeQueue()
    private var toldCategories: SyncCategoriesArg?
    // Each turn of iCloud on or off, so a pass that began before one changes nothing after it.
    private var generation = 0
    // Every provider the engine is told, in order: a pass waits for the off before it, and an off follows the on.
    private var providerChoice: Task<Void, Never>?

    init(
        host: @escaping @autoclosure () -> SyncEngineHost = .shared,
        loadSettings: @escaping @MainActor () -> SyncSettings = { AppSettingsStorage.shared.loadSync() },
        licenseGate: (@MainActor () -> DisableReason?)? = nil,
        policyGate: @escaping @MainActor () -> DisableReason? = {
            SyncProviderPolicy.disableReason(ManagedPolicyCenter.shared.snapshot)
        },
        // Each reading's own answer, so a stop counts even when iCloud is allowed again before the gate is read.
        policyChanges: AnyPublisher<DisableReason?, Never> = ManagedPolicyCenter.shared.$snapshot
            .dropFirst()
            .map(SyncProviderPolicy.disableReason)
            .eraseToAnyPublisher(),
        licenseChanges: AnyPublisher<Void, Never> = AppEvents.shared.licenseStatusDidChange.eraseToAnyPublisher(),
        journal: SyncHostJournal = .shared,
        makeNetworkMonitor: @escaping () -> SyncNetworkMonitor? = { SyncNetworkMonitor() },
        metadata: SyncMetadataStorage = .appDefault,
        pushRegistrar: SyncPushRegistrar = .live,
        activationClock: any Clock<Duration> = ContinuousClock(),
        notificationCenter: NotificationCenter = .default
    ) {
        makeHost = host
        self.loadSettings = loadSettings
        self.licenseGate = licenseGate ?? {
            Self.licenseDisableReason(for: FeatureAccess.shared.check(.iCloudSync))
        }
        self.policyGate = policyGate
        self.policyChanges = policyChanges
        self.licenseChanges = licenseChanges
        self.journal = journal
        self.makeNetworkMonitor = makeNetworkMonitor
        self.metadata = metadata
        self.activationClock = activationClock
        self.notificationCenter = notificationCenter
        pushChannel = SyncPushChannel(registrar: pushRegistrar, metadata: metadata)
        lastSyncDate = metadata.lastSyncDate
    }

    // MARK: - Lifecycle

    // Only the license and the organization are observed while iCloud is off: they decide whether it can turn on.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        host.statusChanges
            .sink { [weak self] in self?.refreshStatus() }
            .store(in: &observers)
        journal.listen { [weak self] change in self?.journalRecorded(change) }
            .store(in: &observers)
        licenseChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.evaluate()
                self?.requestPass(.launch)
            }
            .store(in: &observers)
        // A provider no longer allowed stops at once. One allowed again is decided a turn later, once the center holds
        // the values the gate reads.
        policyChanges
            .sink { [weak self] reason in
                guard let self else { return }
                if let reason {
                    stop(.disabled(reason))
                    return
                }
                Task { @MainActor [weak self] in
                    self?.evaluate()
                    self?.requestPass(.launch)
                }
            }
            .store(in: &observers)
        evaluate()
        requestPass(.launch)
    }

    // The switch turned on: the person's choice to sync, a removed zone included.
    func enableSync() {
        pushChannel.forgetSubscription()
        evaluate()
        requestPass(.person)
    }

    func disableSync() {
        stop(.disabled(policyGate() ?? .userDisabled))
    }

    // A category turned on is read whole by the next pass; one turned off sends nothing from the engine's next call on.
    func categoriesChanged() {
        guard syncStatus.isEnabled else { return }
        Task {
            guard let engine = host.openedEngine(for: .icloud) else { return }
            do {
                try await tellCategories(to: engine)
            } catch {
                Self.logger.error("The engine did not take the categories: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        requestPass(.person)
    }

    // MARK: - Passes

    // The app came forward. After a pass, activations wait out the interval and then run once, so a change made on
    // another Mac still arrives.
    func syncIfNeeded() {
        guard syncStatus.isEnabled, currentPass == nil else { return }
        if activationCooldown != nil {
            activationHeld = true
            return
        }
        requestPass(.foreground)
    }

    // Sync Now: the person asked, so it runs whatever held the last attempt back.
    func syncNow() async {
        requestPass(.person)
        await passesFinished()
    }

    // After TablePro's data was removed from iCloud, nothing is uploaded until the person asks.
    func uploadAgain() async {
        guard syncStatus.error == .blocked(.dataDeletedFromICloud), let engine = try? await host.engine(for: .icloud) else { return }
        pushChannel.forgetSubscription()
        do {
            try await engine.uploadAgain()
        } catch {
            Self.logger.error("Upload Again failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            refreshStatus()
            return
        }
        requestPass(.person)
        await passesFinished()
    }

    func passesFinished() async {
        while let pass = currentPass {
            await pass.value
        }
    }

    private func requestPass(_ why: PassReasonTag) {
        guard syncStatus.isEnabled else { return }
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
        guard syncStatus.isEnabled else {
            finishPass()
            return
        }
        if why == .person || syncStatus.error == nil {
            syncStatus = .syncing
        }
        do {
            try await choose(.icloud) { [weak self] in self?.generation == started }.value.get()
            if !undelivered.isEmpty {
                deliverJournal()
            }
            await journalDelivery?.value
            // A category turned off must hold before anything else goes up.
            let engine = try await host.engine(for: .icloud)
            try await tellCategories(to: engine)
            if started == generation {
                try await engine.syncNow(why: why)
            }
        } catch {
            Self.logger.error("A sync pass failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        if started == generation {
            await saveSubscriptionIfNeeded()
        }
        if started == generation, syncStatus.isEnabled {
            refreshStatus()
            if host.openedEngine(for: .icloud) == nil {
                // The engine did not open for iCloud, so there is none to sync with.
                syncStatus = .error(.unexpected)
            } else if syncStatus.error == nil {
                startActivationCooldown()
            }
        }
        finishPass()
    }

    private func finishPass() {
        currentPass = nil
        // iCloud turned on again while a pass from before the stop was out: only now may CloudKit be reached.
        if syncStatus.isEnabled, host.transport.isClosed {
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

    private func tellCategories(to engine: any SyncEngine) async throws {
        let categories = Self.categories(loadSettings())
        guard categories != toldCategories else { return }
        try await engine.setCategories(categories: categories)
        toldCategories = categories
    }

    // MARK: - Journal

    // Told always, offline and with iCloud off too, so the engine marks them for the previous stable: turned on there,
    // that build marks what still exists but cannot know what was deleted. Only a running iCloud asks for a pass.
    private func journalRecorded(_ change: SyncHostChange) {
        undelivered.append(change)
        deliverJournal()
        guard syncStatus.isEnabled else { return }
        journalPass?.cancel()
        let clock = activationClock
        journalPass = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.journalDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            journalPass = nil
            requestPass(.journal)
        }
    }

    private func deliverJournal() {
        let previous = journalDelivery
        journalDelivery = Task { [weak self] in
            await previous?.value
            await self?.deliverUndelivered()
        }
    }

    private func deliverUndelivered() async {
        let changes = undelivered.takeAll()
        guard !changes.isEmpty else { return }
        var delivered = 0
        do {
            let engine = try await host.engine(for: syncStatus.isEnabled ? .icloud : .off)
            for change in changes {
                try await engine.recordHostChanges(kind: change.kind, written: change.written, deleted: change.deleted)
                delivered += 1
            }
        } catch {
            undelivered.putBack(Array(changes[delivered...]))
            Self.logger.error("The engine did not take a host change: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func saveSubscriptionIfNeeded() async {
        let transport = host.transport
        guard let account = transport.confirmedAccount else { return }
        await pushChannel.saveSubscriptionIfNeeded(account: account) {
            try await transport.saveSubscription(account: account)
        }
    }

    private func refreshStatus() {
        guard syncStatus.isEnabled, let engine = host.openedEngine(for: .icloud) else { return }
        host.rememberICloudAccount()
        let info = engine.status()
        syncStatus = SyncEngineRules.status(info)
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
            syncIfNeeded()
        }
    }

    // MARK: - Status

    // The organization first, then the switch before the license: sync that was never turned on is off by choice,
    // whatever the license says.
    private func evaluate() {
        if let reason = policyGate() {
            stop(.disabled(reason))
            return
        }
        guard loadSettings().enabled else {
            stop(.disabled(.userDisabled))
            return
        }
        if let reason = licenseGate() {
            stop(.disabled(reason))
            return
        }
        guard case .disabled = syncStatus else { return }
        generation += 1
        syncStatus = .idle
        // A pass from before the stop may still be out; it opens the transport once it ends.
        if currentPass == nil {
            host.transport.open()
        }
        arm()
        refreshStatus()
    }

    // What is in flight stops, and nothing more reaches CloudKit until iCloud runs again (P1-I3 under a profile).
    private func stop(_ status: SyncStatus) {
        host.transport.close()
        let wasRunning = syncStatus.isEnabled
        syncStatus = status
        pendingPass = nil
        journalPass?.cancel()
        journalPass = nil
        toldCategories = nil
        disarm()
        guard wasRunning else { return }
        generation += 1
        let choice = choose(.off)
        Task {
            if case .failure(let error) = await choice.value {
                Self.logger.error("The engine did not take iCloud off: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Observers

    private func arm() {
        guard triggers == nil else { return }
        triggers = SyncProviderTriggers(
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

    // What is in flight belongs to the account that was signed in. The next pass reads the account and the engine
    // opens the state file of the one it finds.
    private func observeAccountChanges() -> any NSObjectProtocol {
        notificationCenter.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, syncStatus.isEnabled else { return }
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
                } else if syncStatus.error == .offline {
                    requestPass(.networkBack)
                }
            }
        }
        return monitor
    }

    // MARK: - Push

    // CloudKit registers the device for its own notices, so the token goes nowhere.
    func pushRegistrationDidFinish(registered: Bool) {
        pushChannel.registrationDidFinish(registered: registered)
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard syncStatus.isEnabled, SyncPushSubscription.announcesChange(userInfo) else { return }
        pushChannel.noticeArrived()
        requestPass(.cloudKitPush)
    }
}

// What starts a pass while iCloud runs. Releasing it detaches every observer; the network monitor stops in its deinit.
private final class SyncProviderTriggers {
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
