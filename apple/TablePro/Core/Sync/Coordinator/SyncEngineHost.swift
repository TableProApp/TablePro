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
    private let open: @MainActor (SyncProviderTag, any SyncListener) async throws -> any SyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private typealias Opening = (provider: SyncProviderTag, task: Task<any SyncEngine, any Error>)
    private var opening: Opening?
    private var opened: (provider: SyncProviderTag, engine: any SyncEngine)?

    func openedEngine(for provider: SyncProviderTag) -> (any SyncEngine)? {
        guard let opened, Self.serves(opened.provider, provider) else { return nil }
        return opened.engine
    }

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        open: @escaping @MainActor (SyncProviderTag, any SyncListener) async throws -> any SyncEngine
    ) {
        self.transport = transport
        self.keepICloudAccount = keepICloudAccount
        self.open = open
    }

    func rememberICloudAccount() {
        guard let opened else { return }
        keepICloudAccount(opened.engine.icloudAccount())
    }

    // The provider is fixed when the service opens, and one opened Off refuses every provider call, so iCloud turned
    // on after that opens a new service. One opened for iCloud is kept when iCloud stops, and told Off. A failed open
    // is tried again by the next caller.
    func engine(for provider: SyncProviderTag) async throws -> any SyncEngine {
        while true {
            if let opened, Self.serves(opened.provider, provider) {
                return opened.engine
            }
            let current = opening ?? startOpening(provider)
            let result = await current.task.result
            if opening?.task == current.task {
                opening = nil
            }
            if case .failure(let error) = result, Self.serves(current.provider, provider) {
                throw error
            }
        }
    }

    // The service opened for this provider, once an open of one in flight ends. It never opens one.
    func existingEngine(for provider: SyncProviderTag) async -> (any SyncEngine)? {
        if let opening, opening.provider == provider {
            _ = await opening.task.result
        }
        guard let opened, opened.provider == provider else { return nil }
        return opened.engine
    }

    private func startOpening(_ provider: SyncProviderTag) -> Opening {
        let task = Task { [weak self, open, listener = SyncEngineListener(host: self)] in
            let engine = try await open(provider, listener)
            self?.opened = (provider, engine)
            return engine
        }
        opening = (provider, task)
        return (provider, task)
    }

    private static func serves(_ opened: SyncProviderTag, _ wanted: SyncProviderTag) -> Bool {
        opened == wanted || wanted == .off
    }

    fileprivate func listenerSignalled(keys: Bool) {
        if keys {
            keyChanges.send()
        } else {
            statusChanges.send()
        }
    }

    // No settings host yet, and no device store, which holds the state file's MAC key and anchor (core ADR 0054,
    // Integrity and freshness): until one lands, the core starts no iCloud engine and answers each call as unavailable.
    // The account is optional, since iCloud needs none (Providers).
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
            open: { provider, listener in
                let settings = AppSettingsStorage.shared.loadSync()
                let account = await AccountServices.shared.syncAccount?.accountService()
                return try await CoreStoreHost.shared.core().openSync(
                    config: SyncConfig(
                        platform: .macos,
                        provider: provider,
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
