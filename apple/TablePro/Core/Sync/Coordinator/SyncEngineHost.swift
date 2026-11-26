//
//  SyncEngineHost.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI
import TableProSyncTransport

// The core's sync service as the provider coordinator drives it, so its tests run over a fake engine.
nonisolated protocol SyncEngine: AnyObject, Sendable {
    func status() -> SyncStatusInfo
    func syncNow(why: PassReasonTag) async throws
    func chooseProvider(provider: SyncProviderTag) async throws
    func setCategories(categories: SyncCategoriesArg) async throws
    func recordHostChanges(kind: String, written: [String], deleted: [String]) async throws
    func uploadAgain() async throws
    func icloudAccount() -> String?
}

extension SyncService: SyncEngine {}

// The app's one core sync service (core ADR 0054), opened on first use on the core that holds the stores, with the
// CloudKit transport and the Swift engine's metadata. Its listener only signals, and the signal reaches the main actor.
@MainActor
final class SyncEngineHost {
    static let shared = SyncEngineHost.live()
    // The iCloud account whose state file the engine used last, handed back at the next open so a switch made while the
    // app was closed removes that account's file. Its own key: `lastAccountId` is the downgrade mirror's.
    nonisolated static let icloudAccountKey = "com.TablePro.sync.engineICloudAccount"

    let transport: CloudKitCoreTransport
    let statusChanges = PassthroughSubject<Void, Never>()
    let keyChanges = PassthroughSubject<Void, Never>()
    private let open: @MainActor (any SyncListener) async throws -> any SyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private var opening: Task<any SyncEngine, any Error>?
    private(set) var openedEngine: (any SyncEngine)?

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        open: @escaping @MainActor (any SyncListener) async throws -> any SyncEngine
    ) {
        self.transport = transport
        self.keepICloudAccount = keepICloudAccount
        self.open = open
    }

    func rememberICloudAccount() {
        guard let openedEngine else { return }
        keepICloudAccount(openedEngine.icloudAccount())
    }

    // A failed open is tried again by the next caller.
    func engine() async throws -> any SyncEngine {
        if let openedEngine {
            return openedEngine
        }
        let task = opening ?? Task { [open, listener = SyncEngineListener(host: self)] in
            try await open(listener)
        }
        opening = task
        do {
            let engine = try await task.value
            openedEngine = engine
            return engine
        } catch {
            if opening == task {
                opening = nil
            }
            throw error
        }
    }

    fileprivate func listenerSignalled(keys: Bool) {
        if keys {
            keyChanges.send()
        } else {
            statusChanges.send()
        }
    }

    // No settings host yet, and no device store: the state file's MAC key and anchor need one (core ADR 0054, Integrity
    // and freshness). The engine runs on the core that holds the stores; the account is optional, since iCloud needs
    // none (Providers).
    private static func live() -> SyncEngineHost {
        let transport = CloudKitCoreTransport()
        let mirror = LegacySyncMetadataMirror(
            metadata: .appDefault,
            recordCache: SyncProviderCoordinator.makeRecordCache()
        )
        let defaults = AppStorageEnvironment.shared.defaults
        return SyncEngineHost(
            transport: transport,
            keepICloudAccount: { account in
                guard defaults.string(forKey: icloudAccountKey) != account else { return }
                defaults.set(account, forKey: icloudAccountKey)
            },
            open: { listener in
                let settings = AppSettingsStorage.shared.loadSync()
                let account = await AccountServices.shared.syncAccount?.accountService()
                return try await CoreStoreHost.shared.core().openSync(
                    config: SyncConfig(
                        platform: .macos,
                        provider: settings.enabled ? .icloud : .off,
                        categories: SyncProviderCoordinator.categories(settings),
                        icloudAccount: defaults.string(forKey: icloudAccountKey)
                    ),
                    account: account,
                    cloudkit: transport,
                    settings: nil,
                    deviceStore: nil,
                    legacyMirror: mirror,
                    listener: listener
                )
            }
        )
    }
}

// Called on a core runtime thread: it only schedules the read on the main actor (core ADR 0002).
nonisolated private final class SyncEngineListener: SyncListener, @unchecked Sendable {
    private weak var host: SyncEngineHost?

    @MainActor
    init(host: SyncEngineHost) {
        self.host = host
    }

    func statusChanged() {
        Task { @MainActor [weak host] in host?.listenerSignalled(keys: false) }
    }

    func keysChanged() {
        Task { @MainActor [weak host] in host?.listenerSignalled(keys: true) }
    }
}
