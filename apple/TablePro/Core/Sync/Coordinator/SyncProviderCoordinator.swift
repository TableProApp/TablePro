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
    private let makeNetworkMonitor: () -> SyncNetworkMonitor?
    private let metadata: SyncMetadataStorage
    private let activationClock: any Clock<Duration>

    private var hasStarted = false
    private var observers: Set<AnyCancellable> = []
    private var triggers: SyncProviderTriggers?
    private var currentPass: Task<Void, Never>?
    private var pendingPass: PassReasonTag?
    private var activationCooldown: Task<Void, Never>?
    private var activationHeld = false
    // Telling the engine iCloud is off, which the next pass waits for.
    private var stopping: Task<Void, Never>?

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
        makeNetworkMonitor: @escaping () -> SyncNetworkMonitor? = { SyncNetworkMonitor() },
        metadata: SyncMetadataStorage = .appDefault,
        pushRegistrar: SyncPushRegistrar = .live,
        activationClock: any Clock<Duration> = ContinuousClock()
    ) {
        makeHost = host
        self.loadSettings = loadSettings
        self.licenseGate = licenseGate ?? {
            Self.licenseDisableReason(for: FeatureAccess.shared.check(.iCloudSync))
        }
        self.policyGate = policyGate
        self.policyChanges = policyChanges
        self.licenseChanges = licenseChanges
        self.makeNetworkMonitor = makeNetworkMonitor
        self.metadata = metadata
        self.activationClock = activationClock
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
        guard syncStatus.error == .blocked(.dataDeletedFromICloud), let engine = try? await host.engine() else { return }
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
            pendingPass = Self.stronger(pendingPass, why)
            return
        }
        currentPass = Task { [weak self] in
            await self?.runPass(why)
        }
    }

    private func runPass(_ why: PassReasonTag) async {
        await stopping?.value
        if why == .person || syncStatus.error == nil {
            syncStatus = .syncing
        }
        do {
            let engine = try await host.engine()
            if engine.status().provider != .icloud {
                try await engine.chooseProvider(provider: .icloud)
            }
            try await engine.syncNow(why: why)
        } catch {
            Self.logger.error("A sync pass failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        if syncStatus.isEnabled {
            await saveSubscriptionIfNeeded()
            refreshStatus()
            if host.openedEngine == nil {
                // The account's core did not open, so there is no engine to sync with.
                syncStatus = .error(.unexpected)
            } else if syncStatus.error == nil {
                startActivationCooldown()
            }
        }
        currentPass = nil
        if let pending = pendingPass {
            pendingPass = nil
            requestPass(pending)
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
        guard syncStatus.isEnabled, let engine = host.openedEngine else { return }
        let info = engine.status()
        syncStatus = Self.status(info)
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
        host.transport.open()
        syncStatus = .idle
        arm()
        refreshStatus()
    }

    // What is in flight stops, and nothing more reaches CloudKit until iCloud runs again (P1-I3 under a profile).
    private func stop(_ status: SyncStatus) {
        host.transport.close()
        let wasRunning = syncStatus.isEnabled
        syncStatus = status
        pendingPass = nil
        disarm()
        guard wasRunning, let engine = host.openedEngine else { return }
        let previous = stopping
        stopping = Task {
            await previous?.value
            do {
                try await engine.chooseProvider(provider: .off)
            } catch {
                Self.logger.error("The engine did not take iCloud off: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Observers

    private func arm() {
        guard triggers == nil else { return }
        triggers = SyncProviderTriggers(accountObserver: observeAccountChanges(), networkMonitor: observeNetwork())
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
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, syncStatus.isEnabled else { return }
                host.transport.cancelCallsInFlight()
                requestPass(.launch)
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
                    pendingPass = Self.stronger(pendingPass, .networkBack)
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
    private let accountObserver: any NSObjectProtocol
    private let networkMonitor: SyncNetworkMonitor?

    init(accountObserver: any NSObjectProtocol, networkMonitor: SyncNetworkMonitor?) {
        self.accountObserver = accountObserver
        self.networkMonitor = networkMonitor
    }

    deinit {
        NotificationCenter.default.removeObserver(accountObserver)
    }
}
