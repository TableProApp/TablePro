//
//  SyncEngineHost.swift
//  TablePro
//

import Combine
import Foundation
import os
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
    func flushLegacyMarks() async throws
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
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SyncEngineHost")

    let transport: CloudKitCoreTransport
    let statusChanges = PassthroughSubject<Void, Never>()
    let keyChanges = PassthroughSubject<Void, Never>()
    private let open: @MainActor (SyncProviderTag, any SyncListener) async throws -> any SyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private typealias Opening = (provider: SyncProviderTag, signIn: Int, task: Task<any SyncEngine, any Error>)
    private var opening: Opening?
    private var opened: (provider: SyncProviderTag, engine: any SyncEngine)?
    // Each sign-in, sign-out or switch, so an open that began under the one before is never kept.
    private var signIn = 0
    private var signInObserver: AnyCancellable?
    // The provider the coordinator chose last, which a service opened again takes.
    private var chosen: SyncProviderTag?
    // Each closed service's flush of the marks it still held, which a quit waits for.
    private var retiring: [UUID: Task<Void, Never>] = [:]

    func openedEngine(for provider: SyncProviderTag) -> (any SyncEngine)? {
        guard let opened, Self.serves(opened.provider, provider) else { return nil }
        return opened.engine
    }

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        signInChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        open: @escaping @MainActor (SyncProviderTag, any SyncListener) async throws -> any SyncEngine
    ) {
        self.transport = transport
        self.keepICloudAccount = keepICloudAccount
        self.open = open
        signInObserver = signInChanges.sink { [weak self] in self?.signInChanged() }
    }

    // TablePro Sync and the key flows stay bound to the sign-in the service opened with, and refuse once it ends, so
    // the service closes and opens again for the provider chosen last. The old one goes once its calls in flight and
    // its flush end; the iCloud engine of the new one waits for its state file meanwhile.
    private func signInChanged() {
        signIn += 1
        guard let openFor = opened?.provider ?? opening?.provider else { return }
        let provider = chosen ?? openFor
        if let old = opened?.engine {
            retire(old)
        }
        opened = nil
        Task { [weak self] in
            _ = try? await self?.engine(for: provider)
        }
    }

    // Called as the coordinator makes each choice, in the order it makes them.
    func providerChosen(_ provider: SyncProviderTag) {
        chosen = provider
    }

    // The previous stable's marks for every write the closed services were told.
    func flushRetired() async {
        for task in Array(retiring.values) {
            await task.value
        }
    }

    private func retire(_ engine: any SyncEngine) {
        let id = UUID()
        retiring[id] = Task { [weak self] in
            do {
                try await engine.flushLegacyMarks()
            } catch {
                Self.logger.error("A closed service's marks did not flush: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
            self?.retiring[id] = nil
        }
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
            if case .failure(let error) = result, current.signIn == signIn, Self.serves(current.provider, provider) {
                throw error
            }
        }
    }

    // The service opened for this provider, or for any with nil, once an open of one in flight ends. It never opens one.
    func existingEngine(for provider: SyncProviderTag?) async -> (any SyncEngine)? {
        while let opening, provider == nil || opening.provider == provider {
            _ = await opening.task.result
            if self.opening?.task == opening.task {
                self.opening = nil
            }
        }
        guard let opened, provider == nil || opened.provider == provider else { return nil }
        return opened.engine
    }

    private func startOpening(_ provider: SyncProviderTag) -> Opening {
        let started = signIn
        let task = Task { [weak self, open, listener = SyncEngineListener(host: self)] in
            let engine = try await open(provider, listener)
            if let self, signIn == started {
                opened = (provider, engine)
            }
            return engine
        }
        opening = (provider, started, task)
        return (provider, started, task)
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

    // No settings host yet. The account is optional, since iCloud needs none (core ADR 0054, Providers).
    private static func live() -> SyncEngineHost {
        let transport = CloudKitCoreTransport()
        let mirror = LegacySyncMetadataMirror(
            metadata: .appDefault,
            recordCache: SyncProviderCoordinator.makeRecordCache()
        )
        let defaults = AppStorageEnvironment.shared.defaults
        let deviceStore = KeychainDeviceStore(
            items: AppStorageEnvironment.shared.deviceItems,
            accessGroup: KeychainHelper.resolveAccessGroup()
        )
        return SyncEngineHost(
            transport: transport,
            keepICloudAccount: { account in
                guard defaults.string(forKey: icloudAccountKey) != account else { return }
                defaults.set(account, forKey: icloudAccountKey)
            },
            signInChanges: AccountServices.shared.events.map { _ in }.eraseToAnyPublisher(),
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
                    deviceStore: deviceStore,
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
