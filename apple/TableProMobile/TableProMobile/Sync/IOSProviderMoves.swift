import Combine
import Foundation
import Observation
import os
import TableProFFI
import TableProLogRedaction
import TableProSyncTransport

nonisolated enum ProviderMoveError: Error, Equatable {
    // The organization's values leave the provider out (core ADR 0055).
    case notAllowed
    case inProgress
    case engineUnavailable
    // The person or the organization chose a provider again while the move waited.
    case superseded
    // The server this device is signed in to keeps no personal data (core ADR 0051, Policies).
    case serverRefusesPersonalSync
    // The account signed in or out after the person confirmed the move, so the open service may serve another one.
    case signInChanged
}

nonisolated enum MoveToServiceOutcome: Equatable {
    case moved
    // Nothing personal goes up before this device holds the account's keys (core ADR 0056).
    case needsKeys(KeyStateInfo)
}

// The app pieces a move touches: the core's sync service, opened for one provider at a time, the iCloud coordinator
// and its CloudKit transport, the stored provider and the organization's values.
@MainActor
struct IOSProviderMoveHost {
    var engine: @MainActor (SyncProviderTag) async throws -> any SyncMoveEngine
    var openedEngine: @MainActor (SyncProviderTag) -> (any SyncMoveEngine)?
    var engineChanges: AnyPublisher<Void, Never>
    var iCloudRuns: @MainActor () -> Bool
    // Every iCloud pass and every provider the coordinator is still telling the engine.
    var passesFinished: @MainActor () async -> Void
    var transport: CloudKitCoreTransport
    var choices: @MainActor () -> PersonalSyncChoices
    // The provider as the organization's values settle it, and the person's choice it stores.
    var provider: @MainActor () -> SyncProviderTag
    var setProvider: @MainActor (SyncProviderTag) -> Void
    var session: @MainActor () -> String?
}

// Moves this device's personal data between iCloud and TablePro Sync (core ADR 0054, Moving between providers), and
// keeps the engine off TablePro Sync whenever the provider is Off, as the Mac's ProviderMoves does. The move to TablePro
// Sync runs on iCloud's service and stops iCloud itself after its last pass; the move back runs on TablePro Sync's. The
// stored provider changes once a move returns, and the next open follows it.
@MainActor @Observable
final class IOSProviderMoves {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "ProviderMoves")
    // A pass on TablePro Sync when the app comes forward, unless one finished this recently.
    nonisolated static let activationInterval: Duration = .seconds(60)

    private(set) var engineStatus: SyncStatusInfo?
    // The scopes the service read last, with the server's switches (core ADR 0051, Policies). Empty until it has read them.
    private(set) var scopes: [ScopeStatusInfo] = []
    private(set) var isMoving = false

    // After each TablePro Sync pass the engine finished, so the stores' readers take what it wrote.
    @ObservationIgnored var onPassFinished: (() -> Void)?

    @ObservationIgnored private let host: IOSProviderMoveHost
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var lastPassMs: Int64?
    // Each provider choice the moves did not write themselves, so a move that waited on one gives way to it.
    @ObservationIgnored private var choice = 0

    init(host: IOSProviderMoveHost, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.now = now
    }

    // A device on TablePro Sync opens the engine at launch, whose scheduler then polls the service.
    func start() {
        guard observers.isEmpty else { return }
        host.engineChanges
            .sink { [weak self] in self?.engineChanged() }
            .store(in: &observers)
        guard current == .tableproSync else { return }
        Task { [weak self] in
            await self?.openEngine()
        }
    }

    func openEngine() async {
        do {
            _ = try await host.engine(current)
        } catch {
            Self.logger.error("The sync engine did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        engineChanged()
    }

    // The person or the organization changed the provider without a move: Off from TablePro Sync, or iCloud from Off.
    func providerChangedElsewhere() {
        choice += 1
        reconcile()
    }

    // The core's scheduler stops while the app is suspended, so coming forward asks for the pass it missed.
    func sceneBecameActive() async {
        guard current == .tableproSync, !isMoving else { return }
        if let last = engineStatus?.lastPassMs {
            let finished = Date(timeIntervalSince1970: Double(last) / 1_000)
            guard now().timeIntervalSince(finished) >= Double(Self.activationInterval.components.seconds) else { return }
        }
        do {
            try await host.engine(.tableproSync).syncNow(why: .foreground)
        } catch {
            Self.logger.notice("The foreground pass failed: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        engineChanged()
    }

    var choices: PersonalSyncChoices {
        host.choices()
    }

    // The organization requires TablePro Sync and this device has not moved to it yet.
    var awaitsMove: Bool {
        choices.forced == .tableproSync && current != .tableproSync
    }

    // The organization requires iCloud and this device's data is on TablePro Sync: the move back waits for the person,
    // who confirms what it deletes on iCloud.
    var awaitsMoveBack: Bool {
        choices.forced == .icloud && current == .tableproSync
    }

    private var current: SyncProviderTag {
        host.provider()
    }

    // MARK: - To TablePro Sync

    func keyState() async throws -> KeyStateInfo {
        try await host.engine(current).keyState()
    }

    func planMoveToService() async throws -> MovePlanInfo {
        try await host.engine(current).planMoveToService()
    }

    // From iCloud the core runs the last iCloud pass and stops iCloud on this device itself, so the coordinator keeps
    // CloudKit open until the move returns; only then does the stored provider change, which stops the coordinator.
    // From Off it is the first upload, the server's copy winning a conflict. A move that fails leaves iCloud stopped in
    // the core and the stored provider where it was, so Try Again goes on from there.
    // `session` is the sign-in the person confirmed the move under; the move goes nowhere once another holds the account.
    func moveToService(confirmedUnder session: String?) async throws -> MoveToServiceOutcome {
        guard host.session() == session else { throw ProviderMoveError.signInChanged }
        guard choices.providers.contains(.tableproSync) else { throw ProviderMoveError.notAllowed }
        guard !Self.refusesPersonalSync(scopes) else { throw ProviderMoveError.serverRefusesPersonalSync }
        let asked = choice
        return try await exclusively {
            let from = current
            let engine = try await host.engine(from)
            let keys = try await engine.keyState()
            try ensureCurrent(asked)
            guard case .approved = keys else { return .needsKeys(keys) }
            guard choices.providers.contains(.tableproSync) else { throw ProviderMoveError.notAllowed }
            guard host.session() == session else { throw ProviderMoveError.signInChanged }
            try await engine.chooseProvider(provider: .tableproSync)
            guard choice == asked else {
                await stopPersonalSyncAfterSupersededMove()
                throw ProviderMoveError.superseded
            }
            host.setProvider(.tableproSync)
            if from == .icloud {
                // Stopping iCloud has the coordinator tell the service it holds Off. That service is still the open one
                // until TablePro Sync's has opened, so the Off goes to iCloud's before the first pass opens the new one.
                await host.passesFinished()
            }
            await firstPass(asked)
            return .moved
        }
    }

    // The core put personal data on TablePro Sync in the service that moved, which a choice made meanwhile overrides.
    private func stopPersonalSyncAfterSupersededMove() async {
        guard current == .off else { return }
        do {
            try await host.engine(.tableproSync).chooseProvider(provider: .off)
        } catch {
            Self.logger.error("The moved service did not stop: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        engineChanged()
    }

    private func firstPass(_ asked: Int) async {
        guard choice == asked, current == .tableproSync else { return }
        do {
            try await host.engine(.tableproSync).syncNow(why: .person)
        } catch {
            Self.logger.error("The first TablePro Sync pass failed: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        engineChanged()
    }

    // MARK: - Back to iCloud

    func planMoveToICloud() async throws -> MoveBackPlanInfo {
        try await host.engine(.tableproSync).planMoveToIcloud()
    }

    // The move back fetches and deletes on CloudKit while iCloud is still off here, so the transport opens for it.
    // iCloud then turns on as it does today, once the core is done.
    func moveToICloud(confirmedDeletions: UInt64, confirmedUnder session: String?) async throws {
        guard host.session() == session else { throw ProviderMoveError.signInChanged }
        guard choices.providers.contains(.icloud) else { throw ProviderMoveError.notAllowed }
        let asked = choice
        try await exclusively {
            let engine = try await host.engine(.tableproSync)
            guard host.session() == session else { throw ProviderMoveError.signInChanged }
            try await withCloudKit(asked) {
                try await engine.moveToIcloud(confirmedDeletions: confirmedDeletions)
                guard choice == asked else {
                    throw ProviderMoveError.superseded
                }
                host.setProvider(.icloud)
            }
            engineChanged()
        }
    }

    // MARK: - Off

    func turnOff() async {
        guard current != .off else { return }
        choice += 1
        host.setProvider(.off)
        reconcile()
        await reconciling?.value
    }

    // From Off, iCloud needs no move: the coordinator turns it on.
    func turnOnICloud() {
        guard current == .off, choices.providers.contains(.icloud) else { return }
        choice += 1
        host.setProvider(.icloud)
    }

    // MARK: - Another account or server

    func planNewIdentity() async throws -> NewIdentityPlanInfo {
        try await host.engine(current).planNewIdentity()
    }

    // The answer names the prompt's account, so one given for an account signed out meanwhile is refused.
    func chooseForNewIdentity(_ choice: NewIdentityChoiceTag, for plan: NewIdentityPlanInfo) async throws {
        let engine = try await host.engine(current)
        try await engine.chooseForNewIdentity(choice: choice, account: plan.account)
        engineChanged()
        try await engine.syncNow(why: .person)
    }

    // MARK: - Passes

    func syncNow() async throws {
        try await host.engine(current).syncNow(why: .person)
        engineChanged()
    }

    // MARK: - iCloud data

    // The zone stays after a move until the person deletes it. Never while this device syncs with iCloud, and never
    // once the organization takes iCloud away: then no request reaches CloudKit.
    var offersICloudDataDeletion: Bool {
        current != .icloud && choices.providers.contains(.icloud)
    }

    func deleteICloudData() async throws {
        guard offersICloudDataDeletion else { throw ProviderMoveError.notAllowed }
        let asked = choice
        try await exclusively {
            let engine = try await host.engine(current)
            try await withCloudKit(asked) {
                guard current != .icloud else { throw ProviderMoveError.notAllowed }
                try await engine.deleteIcloudZone()
            }
            engineChanged()
        }
    }

    // MARK: - Server policies

    // A server whose `personalSync` switch is off takes no personal data while this device is signed in to it. The
    // stored provider stays, so the device picks up again when the switch comes back on (core ADR 0051, Policies).
    nonisolated static func refusesPersonalSync(_ scopes: [ScopeStatusInfo]) -> Bool {
        scopes.first { $0.scope == "personal" }?.personalSync == false
    }

    // MARK: - Engine

    func engineChanged() {
        let engine = host.openedEngine(.off)
        let status = engine?.status()
        engineStatus = status
        scopes = engine?.scopeStatuses() ?? []
        if let status, status.provider == .tableproSync, status.lastPassMs != lastPassMs {
            lastPassMs = status.lastPassMs
            if status.lastPassMs != nil {
                onPassFinished?()
            }
        }
        reconcile()
    }

    // Off is the person's word, so an engine still on TablePro Sync stops. A stored TablePro Sync the engine has not
    // moved to waits for the person's confirmation, and iCloud is the coordinator's.
    private func reconcile() {
        guard reconciling == nil, !isMoving, current == .off else { return }
        guard let engine = host.openedEngine(.tableproSync), engine.status().provider == .tableproSync else { return }
        // Values that require TablePro Sync keep a device that moved on it.
        guard choices.providers.contains(.off) else {
            host.setProvider(.tableproSync)
            return
        }
        reconciling = Task { [weak self] in
            do {
                try await engine.chooseProvider(provider: .off)
            } catch {
                Self.logger.error("The engine did not take TablePro Sync off: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            }
            guard let self else { return }
            reconciling = nil
            engineStatus = host.openedEngine(.off)?.status()
        }
    }

    // An Off that arrived during the operation is applied once it ends.
    private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
        guard !isMoving else { throw ProviderMoveError.inProgress }
        isMoving = true
        defer {
            isMoving = false
            reconcile()
        }
        await reconciling?.value
        return try await body()
    }

    private func ensureCurrent(_ asked: Int) throws {
        guard choice == asked else { throw ProviderMoveError.superseded }
    }

    // Opened only when iCloud does not run here, and closed again after, so the coordinator's own rules hold.
    private func withCloudKit<T>(_ asked: Int, _ body: () async throws -> T) async throws -> T {
        await host.passesFinished()
        try ensureCurrent(asked)
        guard choices.providers.contains(.icloud) else { throw ProviderMoveError.notAllowed }
        let reached = host.transport.isClosed
        if reached {
            host.transport.open()
        }
        defer {
            if reached, !host.iCloudRuns() {
                host.transport.close()
            }
        }
        return try await body()
    }
}

extension IOSProviderMoveHost {
    static func live(
        engines: IOSSyncEngineHost,
        coordinator: IOSSyncCoordinator,
        onboarding: OnboardingPreferences,
        account: AccountModel,
        setProvider: @escaping @MainActor (SyncProviderTag) -> Void
    ) -> IOSProviderMoveHost {
        IOSProviderMoveHost(
            engine: { provider in
                guard let engine = try await engines.engine(for: provider) as? any SyncMoveEngine else {
                    throw ProviderMoveError.engineUnavailable
                }
                return engine
            },
            openedEngine: { provider in engines.openedEngine(for: provider) as? any SyncMoveEngine },
            engineChanges: engines.statusChanges.merge(with: engines.reopened).eraseToAnyPublisher(),
            iCloudRuns: { coordinator.status.isEnabled },
            passesFinished: { await coordinator.passesAndChoicesFinished() },
            transport: engines.transport,
            choices: { onboarding.managed.syncChoices },
            provider: { onboarding.syncProvider },
            setProvider: setProvider,
            session: { account.snapshot.sessionID }
        )
    }
}
