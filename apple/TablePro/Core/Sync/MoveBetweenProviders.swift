//
//  MoveBetweenProviders.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI
import TableProSyncTransport

internal enum ProviderMoveError: Error, Equatable {
    // The configuration profile leaves the provider out (core ADR 0055).
    case notAllowed
    case inProgress
    case engineUnavailable
    // The person or a profile chose a provider again while the move waited.
    case superseded
    // The server this Mac is signed in to keeps no personal data (core ADR 0051, Policies).
    case serverRefusesPersonalSync
    // The account signed in or out after the person confirmed the move, so the open service may serve another one.
    case signInChanged
}

internal enum MoveToServiceOutcome: Equatable {
    case moved
    // Nothing personal goes up before this Mac holds the account's keys (core ADR 0056).
    case needsKeys(KeyStateInfo)
}

// The app pieces a move touches: the core's sync service, opened for one provider at a time, the iCloud coordinator and
// its CloudKit transport.
internal struct ProviderMoveHost {
    var engine: @MainActor (SyncProviderTag) async throws -> any SyncMoveEngine
    var openedEngine: @MainActor (SyncProviderTag) -> (any SyncMoveEngine)?
    var engineChanges: AnyPublisher<Void, Never>
    var iCloudRuns: @MainActor () -> Bool
    var passesFinished: @MainActor () async -> Void
    var cloudKit: CloudKitReach
    var policy: @MainActor () -> ManagedPolicySnapshot
    var session: @MainActor () -> String?
}

internal struct CloudKitReach {
    var isClosed: @MainActor () -> Bool
    var open: @MainActor () -> Void
    var close: @MainActor () -> Void
}

// Moves this Mac's personal data between iCloud and TablePro Sync (core ADR 0054, Moving between providers), and keeps
// the engine off TablePro Sync whenever the stored provider says Off, after a reset or an import too. Each call goes to
// the service opened for the provider in use, as the core runs a move: the move to TablePro Sync runs on iCloud's and
// stops iCloud itself after its last pass, the move back runs on TablePro Sync's. The stored provider changes once a
// move returns, and the next open follows it.
@MainActor
internal final class ProviderMoves: ObservableObject {
    static let shared = ProviderMoves()
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "ProviderMoves")

    @Published private(set) var engineStatus: SyncStatusInfo?
    // The scopes the service read last, with the server's switches (core ADR 0051, Policies). Empty until it has read them.
    @Published private(set) var scopes: [ScopeStatusInfo] = []

    private let makeHost: () -> ProviderMoveHost
    private lazy var host = makeHost()
    private let settings: SettingsSlice<SyncSettings>
    private var observers: Set<AnyCancellable> = []
    private var providerWatch: AnyCancellable?
    private var categoriesWatch: AnyCancellable?
    private var isMoving = false
    private var reconciling: Task<Void, Never>?
    // Each provider choice the moves did not write themselves, so a move that waited on one gives way to it.
    private var choice = 0
    private var writesProvider = false

    init(
        host: @escaping @autoclosure () -> ProviderMoveHost = .live,
        settings: SettingsSlice<SyncSettings> = AppSettingsManager.shared.syncSlice
    ) {
        makeHost = host
        self.settings = settings
        // Settings are written on the main thread, and the count has to move before the write returns.
        providerWatch = settings.publisher
            .map(\.provider)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if !writesProvider {
                    choice += 1
                }
                Task { @MainActor [weak self] in self?.reconcile() }
            }
        // iCloud's service hears the categories from the coordinator; any other open service hears them here.
        categoriesWatch = settings.publisher
            .map(SyncProviderCoordinator.categories)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] categories in
                Task { @MainActor [weak self] in await self?.tell(categories) }
            }
    }

    private func tell(_ categories: SyncCategoriesArg) async {
        guard settings.value.provider != .iCloud, let engine = host.openedEngine(.off) else { return }
        do {
            try await engine.setCategories(categories: categories)
        } catch {
            Self.logger.error("The engine did not take the categories: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    // A Mac on TablePro Sync opens the engine at launch, whose scheduler then polls the service.
    func start() {
        guard observers.isEmpty else { return }
        host.engineChanges
            .sink { [weak self] in self?.engineChanged() }
            .store(in: &observers)
        guard settings.value.provider == .tableproSync else { return }
        Task { [weak self] in
            await self?.openEngine()
        }
    }

    func openEngine() async {
        do {
            _ = try await host.engine(current)
        } catch {
            Self.logger.error("The sync engine did not open: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        engineChanged()
    }

    var choices: PersonalSyncChoices {
        SyncProviderPolicy.choices(host.policy())
    }

    // The profile requires TablePro Sync and this Mac has not moved to it yet.
    var awaitsMove: Bool {
        choices.forced == .tableproSync && settings.value.provider != .tableproSync
    }

    // The profile requires iCloud and this Mac's data is on TablePro Sync: the move back waits for the person, who
    // confirms what it deletes on iCloud.
    var awaitsMoveBack: Bool {
        choices.forced == .icloud && settings.value.provider == .tableproSync
    }

    private var current: SyncProviderTag {
        SyncProviderTag(settings.value.provider)
    }

    // MARK: - To TablePro Sync

    func keyState() async throws -> KeyStateInfo {
        try await host.engine(current).keyState()
    }

    func planMoveToService() async throws -> MovePlanInfo {
        try await host.engine(current).planMoveToService()
    }

    // From iCloud the core runs the last iCloud pass and stops iCloud on this Mac itself, so the coordinator keeps
    // CloudKit open until the move returns; only then does the stored provider change, which stops the coordinator. From
    // Off it is the first upload, the server's copy winning a conflict. A move that fails leaves iCloud stopped in the
    // core and the stored provider where it was, so Try Again goes on from there.
    // `session` is the sign-in the person confirmed the move under; the move goes nowhere once another holds the account.
    func moveToService(confirmedUnder session: String?) async throws -> MoveToServiceOutcome {
        guard host.session() == session else { throw ProviderMoveError.signInChanged }
        guard choices.providers.contains(.tableproSync) else { throw ProviderMoveError.notAllowed }
        guard !Self.refusesPersonalSync(scopes) else { throw ProviderMoveError.serverRefusesPersonalSync }
        let asked = choice
        return try await exclusively {
            let outcome = try await moveOnOpenService(asked, confirmedUnder: session)
            guard outcome == .moved else { return outcome }
            // TablePro Sync's service waits for the state file the service that moved still holds, so that one is let
            // go before the first pass.
            await firstPass(asked)
            return .moved
        }
    }

    private func moveOnOpenService(_ asked: Int, confirmedUnder session: String?) async throws -> MoveToServiceOutcome {
        let from = current
        let engine = try await host.engine(from)
        let keys = try await engine.keyState()
        try ensureCurrent(asked)
        guard case .approved = keys else { return .needsKeys(keys) }
        // The profile is read again in the same turn as the call, and the core checks it as well. From iCloud the core
        // moves, from Off it makes the first upload.
        guard choices.providers.contains(.tableproSync) else { throw ProviderMoveError.notAllowed }
        guard host.session() == session else { throw ProviderMoveError.signInChanged }
        try await engine.chooseProvider(provider: .tableproSync)
        guard choice == asked else {
            await stopPersonalSyncAfterSupersededMove()
            throw ProviderMoveError.superseded
        }
        setProvider(.tableproSync)
        if from == .icloud {
            // Stopping iCloud has the coordinator tell the service it holds Off. That service is still the open one
            // until TablePro Sync's has opened, which takes a call into the core, so the Off goes to iCloud's.
            await host.passesFinished()
        }
        return .moved
    }

    // The core put personal data on TablePro Sync in the service that moved, which a choice made meanwhile overrides.
    // Opening TablePro Sync's service replaces that one, and Off then stops personal sync there; another provider is
    // the coordinator's to open.
    private func stopPersonalSyncAfterSupersededMove() async {
        guard settings.value.provider == .off else { return }
        do {
            try await host.engine(.tableproSync).chooseProvider(provider: .off)
        } catch {
            Self.logger.error("The moved service did not stop: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        engineChanged()
    }

    // The first pass on the service the stored provider opens now. A choice made meanwhile wins over it.
    private func firstPass(_ asked: Int) async {
        guard choice == asked, settings.value.provider == .tableproSync else { return }
        do {
            try await host.engine(.tableproSync).syncNow(why: .person)
        } catch {
            Self.logger.error("The first TablePro Sync pass failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        engineChanged()
    }

    // MARK: - Back to iCloud

    func planMoveToICloud() async throws -> MoveBackPlanInfo {
        try await host.engine(.tableproSync).planMoveToIcloud()
    }

    // The move back fetches and deletes on CloudKit while iCloud is still off here, so the transport opens for it.
    // iCloud then turns on as it does today, once the core is done.
    // `session` is the sign-in the person confirmed the count under; its service is the one the move may run on.
    func moveToICloud(confirmedDeletions: UInt64, confirmedUnder session: String?) async throws {
        guard host.session() == session else { throw ProviderMoveError.signInChanged }
        guard choices.providers.contains(.icloud) else { throw ProviderMoveError.notAllowed }
        let asked = choice
        try await exclusively {
            let engine = try await host.engine(.tableproSync)
            guard host.session() == session else { throw ProviderMoveError.signInChanged }
            // iCloud turns on before CloudKit would close again, so the coordinator takes the transport over open.
            try await withCloudKit(asked) {
                try await engine.moveToIcloud(confirmedDeletions: confirmedDeletions)
                guard choice == asked else {
                    throw ProviderMoveError.superseded
                }
                setProvider(.iCloud)
            }
            engineChanged()
        }
    }

    // MARK: - Off

    func turnOff() async {
        settings.update { $0.provider = .off }
        reconcile()
        await reconciling?.value
    }

    // MARK: - Another account or server

    // What the prompt for another account shows, and the account its answer names back.
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

    // The zone stays after a move until the person deletes it. Never while this Mac syncs with iCloud, and never once
    // the organization takes iCloud away: then no request reaches CloudKit.
    nonisolated static func offersICloudDataDeletion(
        _ provider: SyncProviderSetting,
        under snapshot: ManagedPolicySnapshot
    ) -> Bool {
        provider != .iCloud && SyncProviderPolicy.choices(snapshot).providers.contains(.icloud)
    }

    var offersICloudDataDeletion: Bool {
        Self.offersICloudDataDeletion(settings.value.provider, under: host.policy())
    }

    func deleteICloudData() async throws {
        guard offersICloudDataDeletion else { throw ProviderMoveError.notAllowed }
        let asked = choice
        try await exclusively {
            let engine = try await host.engine(current)
            try await withCloudKit(asked) {
                guard settings.value.provider != .iCloud else { throw ProviderMoveError.notAllowed }
                try await engine.deleteIcloudZone()
            }
            engineChanged()
        }
    }

    // MARK: - Server policies

    // A server whose `personalSync` switch is off takes no personal data while this Mac is signed in to it. The stored
    // provider stays, so the device picks up again when the switch comes back on (core ADR 0051, Policies; 0055).
    nonisolated static func refusesPersonalSync(_ scopes: [ScopeStatusInfo]) -> Bool {
        scopes.first { $0.scope == "personal" }?.personalSync == false
    }

    // MARK: - Engine

    private func engineChanged() {
        let engine = host.openedEngine(.off)
        engineStatus = engine?.status()
        scopes = engine?.scopeStatuses() ?? []
        reconcile()
    }

    // Off is the person's word, so an engine still on TablePro Sync stops. A stored TablePro Sync the engine has not
    // moved to waits for the person's confirmation, and iCloud is the coordinator's.
    private func reconcile() {
        guard reconciling == nil, !isMoving, settings.value.provider == .off else { return }
        guard let engine = host.openedEngine(.tableproSync), engine.status().provider == .tableproSync else { return }
        // A profile that requires TablePro Sync keeps a Mac that moved on it, so a reset or an import does not take it off.
        guard choices.providers.contains(.off) else {
            setProvider(.tableproSync)
            return
        }
        reconciling = Task { [weak self] in
            do {
                try await engine.chooseProvider(provider: .off)
            } catch {
                Self.logger.error("The engine did not take TablePro Sync off: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
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

    private func setProvider(_ provider: SyncProviderSetting) {
        writesProvider = true
        defer { writesProvider = false }
        settings.update { $0.provider = provider }
    }

    private func ensureCurrent(_ asked: Int) throws {
        guard choice == asked else { throw ProviderMoveError.superseded }
    }

    // Opened only when iCloud does not run here, and closed again after, so the coordinator's own rules hold. The
    // profile and the choice are read in the same turn as the open; a profile that takes iCloud away later makes the
    // coordinator close the transport, which ends the call.
    private func withCloudKit<T>(_ asked: Int, _ body: () async throws -> T) async throws -> T {
        await host.passesFinished()
        try ensureCurrent(asked)
        guard choices.providers.contains(.icloud) else { throw ProviderMoveError.notAllowed }
        let reached = host.cloudKit.isClosed()
        if reached {
            host.cloudKit.open()
        }
        defer {
            if reached, !host.iCloudRuns() {
                host.cloudKit.close()
            }
        }
        return try await body()
    }
}

extension ProviderMoves {
    // The engine's own words never reach the screen; its code goes to the log.
    nonisolated static func message(for error: any Error) -> String {
        if let error = error as? ProviderMoveError {
            switch error {
            case .notAllowed:
                return String(localized: "Your organization does not allow this on this Mac.")
            case .inProgress:
                return String(localized: "Another change to how this Mac syncs is still running.")
            case .serverRefusesPersonalSync:
                return String(localized: "Your server does not keep personal data, so this Mac cannot sync it there.")
            case .superseded:
                return String(localized: "How this Mac syncs changed while this ran, so it stopped.")
            case .signInChanged:
                return String(localized: "Your TablePro account changed, so nothing moved. Start again to see what this account gets.")
            case .engineUnavailable:
                return message(forCode: "")
            }
        }
        if let error = error as? CoreError, case .Failed(let info) = error {
            return message(forCode: info.code)
        }
        return message(forCode: "")
    }

    nonisolated static func message(forCode code: String) -> String {
        switch code {
        case "sync.locked", "sync.not_allowed", "sync.device_not_approved", "sync.device_removed":
            return String(localized: "This Mac cannot read your account's keys. Approve it from another device, or use your recovery key.")
        case "sync.network", "sync.server", "sync.rate_limited", "sync.restore_check_unavailable", "account.unreachable":
            return String(localized: "TablePro Sync cannot be reached. Your data stays on this Mac; try again once you are online.")
        case "sync.feature_required", "sync.license_expired", "sync.seat_required":
            return String(localized: "Your account no longer includes TablePro Sync uploads. Your data stays on this Mac.")
        case "sync.signed_out", "sync.interactive_sign_in_required":
            return String(localized: "Sign in to your TablePro account again, then try again.")
        case "sync.changed":
            return String(localized: "This changed while you were deciding. Look again, then choose.")
        default:
            return String(localized: "TablePro Sync could not finish. Your data stays on this Mac; try again later.")
        }
    }
}

extension ProviderMoveHost {
    @MainActor
    static var live: ProviderMoveHost {
        let engines = SyncEngineHost.shared
        let coordinator = SyncProviderCoordinator.shared
        return ProviderMoveHost(
            engine: { provider in
                // The one `SyncService` the app holds for that provider.
                guard let engine = try await engines.engine(for: provider) as? any SyncMoveEngine else {
                    throw ProviderMoveError.engineUnavailable
                }
                return engine
            },
            openedEngine: { provider in engines.openedEngine(for: provider) as? any SyncMoveEngine },
            engineChanges: engines.statusChanges.eraseToAnyPublisher(),
            iCloudRuns: { coordinator.syncStatus.isEnabled },
            passesFinished: { await coordinator.passesFinished() },
            cloudKit: CloudKitReach(
                isClosed: { engines.transport.isClosed },
                open: { engines.transport.open() },
                close: { engines.transport.close() }
            ),
            policy: { ManagedPolicyCenter.shared.snapshot },
            session: { FeatureAccess.shared.state.sessionID }
        )
    }
}
