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
}

internal enum MoveToServiceOutcome: Equatable {
    case moved
    // Nothing personal goes up before this Mac holds the account's keys (core ADR 0056).
    case needsKeys(KeyStateInfo)
}

// The app pieces a move touches: the core's sync service, the iCloud coordinator and its CloudKit transport.
internal struct ProviderMoveHost {
    var engine: @MainActor () async throws -> any SyncMoveEngine
    var openedEngine: @MainActor () -> (any SyncMoveEngine)?
    var engineChanges: AnyPublisher<Void, Never>
    var iCloudRuns: @MainActor () -> Bool
    // A pass through the iCloud coordinator, which keeps CloudKit to its rules.
    var iCloudPass: @MainActor () async -> Void
    var passesFinished: @MainActor () async -> Void
    var cloudKit: CloudKitReach
    var policy: @MainActor () -> ManagedPolicySnapshot
}

internal struct CloudKitReach {
    var isClosed: @MainActor () -> Bool
    var open: @MainActor () -> Void
    var close: @MainActor () -> Void
}

// Moves this Mac's personal data between iCloud and TablePro Sync (core ADR 0054, Moving between providers), and keeps
// the engine off TablePro Sync whenever the stored provider says Off, after a reset or an import too.
@MainActor
internal final class ProviderMoves: ObservableObject {
    static let shared = ProviderMoves()
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "ProviderMoves")

    @Published private(set) var engineStatus: SyncStatusInfo?

    private let makeHost: () -> ProviderMoveHost
    private lazy var host = makeHost()
    private let settings: SettingsSlice<SyncSettings>
    private var observers: Set<AnyCancellable> = []
    private var isMoving = false
    private var reconciling: Task<Void, Never>?

    init(
        host: @escaping @autoclosure () -> ProviderMoveHost = .live,
        settings: SettingsSlice<SyncSettings> = AppSettingsManager.shared.syncSlice
    ) {
        makeHost = host
        self.settings = settings
    }

    // A Mac on TablePro Sync opens the engine at launch, whose scheduler then polls the service.
    func start() {
        guard observers.isEmpty else { return }
        host.engineChanges
            .sink { [weak self] in self?.engineChanged() }
            .store(in: &observers)
        settings.publisher
            .map(\.provider)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            }
            .store(in: &observers)
        guard settings.value.provider == .tableproSync else { return }
        Task { [weak self] in
            await self?.openEngine()
        }
    }

    func openEngine() async {
        do {
            _ = try await host.engine()
        } catch {
            Self.logger.error("The sync engine did not open: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        engineChanged()
    }

    var choices: PersonalSyncChoices {
        SyncProviderPolicy.choices(host.policy())
    }

    // The Mac chose TablePro Sync and the engine has not moved yet: a profile forced it, or a move did not finish.
    var awaitsMove: Bool {
        settings.value.provider == .tableproSync && engineStatus?.provider != .tableproSync
    }

    // MARK: - To TablePro Sync

    func planMoveToService() async throws -> MovePlanInfo {
        try await host.engine().planMoveToService()
    }

    // The last iCloud push and pull run through the coordinator, then iCloud stops on this Mac before the engine moves,
    // so nothing more reaches CloudKit and no iCloud pass runs beside the move. A move that fails leaves the Mac on
    // TablePro Sync waiting for it, so Try Again picks up where it stopped.
    func moveToService() async throws -> MoveToServiceOutcome {
        guard choices.providers.contains(.tableproSync) else { throw ProviderMoveError.notAllowed }
        return try await exclusively {
            let engine = try await host.engine()
            let keys = try await engine.keyState()
            guard case .approved = keys else { return .needsKeys(keys) }
            if settings.value.provider != .tableproSync {
                if host.iCloudRuns() {
                    await host.iCloudPass()
                }
                settings.update { $0.provider = .tableproSync }
            }
            await host.passesFinished()
            try await engine.moveToService()
            engineChanged()
            do {
                try await engine.syncNow(why: .person)
            } catch {
                Self.logger.error("The first TablePro Sync pass failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            return .moved
        }
    }

    // MARK: - Back to iCloud

    func planMoveToICloud() async throws -> MoveBackPlanInfo {
        try await host.engine().planMoveToIcloud()
    }

    // The move back fetches and deletes on CloudKit while iCloud is still off here, so the transport opens for it.
    // iCloud then turns on as it does today, once the engine is on it.
    func moveToICloud(confirmedDeletions: UInt64) async throws {
        guard choices.providers.contains(.icloud) else { throw ProviderMoveError.notAllowed }
        try await exclusively {
            let engine = try await host.engine()
            // iCloud turns on before CloudKit would close again, so the coordinator takes the transport over open.
            try await withCloudKit {
                try await engine.moveToIcloud(confirmedDeletions: confirmedDeletions)
                settings.update { $0.provider = .iCloud }
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

    func chooseForNewIdentity(_ choice: NewIdentityChoiceTag) async throws {
        let engine = try await host.engine()
        try await engine.chooseForNewIdentity(choice: choice)
        engineChanged()
        if host.iCloudRuns() {
            await host.iCloudPass()
        } else {
            try await engine.syncNow(why: .person)
        }
    }

    // MARK: - Passes

    func syncNow() async throws {
        try await host.engine().syncNow(why: .person)
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
        try await exclusively {
            let engine = try await host.engine()
            try await withCloudKit {
                try await engine.deleteIcloudZone()
            }
            engineChanged()
        }
    }

    // MARK: - Engine

    private func engineChanged() {
        engineStatus = host.openedEngine()?.status()
        reconcile()
    }

    // Off is the person's word, so an engine still on TablePro Sync stops. A stored TablePro Sync the engine has not
    // moved to waits for the person's confirmation, and iCloud is the coordinator's.
    private func reconcile() {
        guard reconciling == nil, !isMoving, settings.value.provider == .off else { return }
        guard let engine = host.openedEngine(), engine.status().provider == .tableproSync else { return }
        reconciling = Task { [weak self] in
            do {
                try await engine.chooseProvider(provider: .off)
            } catch {
                Self.logger.error("The engine did not take TablePro Sync off: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            guard let self else { return }
            reconciling = nil
            engineStatus = host.openedEngine()?.status()
        }
    }

    private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
        guard !isMoving else { throw ProviderMoveError.inProgress }
        isMoving = true
        defer { isMoving = false }
        await reconciling?.value
        return try await body()
    }

    // Opened only when iCloud does not run here, and closed again after, so the coordinator's own rules hold.
    private func withCloudKit<T>(_ body: () async throws -> T) async throws -> T {
        await host.passesFinished()
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
        switch error {
        case ProviderMoveError.notAllowed:
            return String(localized: "Your organization does not allow this on this Mac.")
        case ProviderMoveError.inProgress:
            return String(localized: "Another change to how this Mac syncs is still running.")
        case CoreError.Failed(let info):
            return message(forCode: info.code)
        default:
            return message(forCode: "")
        }
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
        default:
            return String(localized: "TablePro Sync could not finish. Your data stays on this Mac; try again later.")
        }
    }
}

extension ProviderMoveHost {
    static var live: ProviderMoveHost {
        let engines = SyncEngineHost.shared
        let coordinator = SyncProviderCoordinator.shared
        return ProviderMoveHost(
            engine: {
                // The service the coordinator opened is the one `SyncService` the app holds.
                guard let engine = try await engines.engine() as? any SyncMoveEngine else {
                    throw ProviderMoveError.engineUnavailable
                }
                return engine
            },
            openedEngine: { engines.openedEngine as? any SyncMoveEngine },
            engineChanges: engines.statusChanges.eraseToAnyPublisher(),
            iCloudRuns: { coordinator.syncStatus.isEnabled },
            iCloudPass: { await coordinator.syncNow() },
            passesFinished: { await coordinator.passesFinished() },
            cloudKit: CloudKitReach(
                isClosed: { engines.transport.isClosed },
                open: { engines.transport.open() },
                close: { engines.transport.close() }
            ),
            policy: { ManagedPolicyCenter.shared.snapshot }
        )
    }
}
