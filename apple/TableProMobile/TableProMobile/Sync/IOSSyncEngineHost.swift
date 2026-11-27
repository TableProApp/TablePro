import Combine
import Foundation
import os
import TableProFFI
import TableProLogRedaction
import TableProSyncTransport

// The core's sync service as the iOS coordinator drives it, so its tests run over a fake engine.
nonisolated protocol IOSSyncEngine: AnyObject, Sendable {
    func status() -> SyncStatusInfo
    func syncNow(why: PassReasonTag) async throws
    func chooseProvider(provider: SyncProviderTag) async throws
    func setCategories(categories: SyncCategoriesArg) async throws
    func uploadAgain() async throws
    func icloudAccount() -> String?
    func serviceAccount() -> String?
    func flushLegacyMarks() async throws
}

extension SyncService: IOSSyncEngine {}

// The open service is not the core's, so no key flow runs on it.
nonisolated struct KeyServiceUnavailable: Error {}

// The app's one core sync service (core ADR 0054, The Apple apps on the engine), opened on first use on the core that
// holds the stores, with the shared CloudKit transport, the Swift engine's metadata, which it imports once and keeps
// written for the previous stable, and the TablePro account when one is open. Its listener only signals, and the
// signal reaches the main actor.
@MainActor
final class IOSSyncEngineHost {
    // The iCloud account whose state file the engine used last, handed back at the next open so a switch made while the
    // app was closed removes that account's file. Its own key: `lastAccountId` is the downgrade mirror's.
    nonisolated static let icloudAccountKey = "com.TablePro.sync.engineICloudAccount"
    // The TablePro Sync sign-in whose state file the engine used last, handed back at the next open so another account
    // or server waits for the person's choice instead of taking this one's state.
    nonisolated static let serviceAccountKey = "com.TablePro.sync.engineServiceAccount"
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "IOSSyncEngineHost")

    // Where the Swift engine kept its record cache, which the engine imports as bases and the mirror keeps writing.
    nonisolated static var recordCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    let transport: CloudKitCoreTransport
    // The iCloud coordinator's signal; the other readers listen to `statusChanges`.
    var onSignal: (() -> Void)?
    let statusChanges = PassthroughSubject<Void, Never>()
    let keyChanges = PassthroughSubject<Void, Never>()
    // A sign-in change opened the service again, which takes no choice the old one was told.
    let reopened = PassthroughSubject<Void, Never>()
    // Sent at the sign-in change itself, before any reopen: what was read belongs to the account before it.
    let signInChanges = PassthroughSubject<Void, Never>()
    private let open: @MainActor (SyncProviderTag, any SyncListener) async throws -> any IOSSyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private let keepServiceAccount: @MainActor (String?) -> Void
    private typealias Opening = (provider: SyncProviderTag, signIn: Int, task: Task<any IOSSyncEngine, any Error>)
    private var opening: Opening?
    private var opened: (provider: SyncProviderTag, engine: any IOSSyncEngine)?
    // Each sign-in, sign-out or switch, so an open that began under the one before is never kept.
    private var signIn = 0
    // Each closed service's flush of the marks it still held.
    private var retiring: [UUID: Task<Void, Never>] = [:]

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        keepServiceAccount: @escaping @MainActor (String?) -> Void = { _ in },
        open: @escaping @MainActor (SyncProviderTag, any SyncListener) async throws -> any IOSSyncEngine
    ) {
        self.transport = transport
        self.keepICloudAccount = keepICloudAccount
        self.keepServiceAccount = keepServiceAccount
        self.open = open
    }

    func openedEngine(for provider: SyncProviderTag) -> (any IOSSyncEngine)? {
        guard let opened, Self.serves(opened.provider, provider) else { return nil }
        return opened.engine
    }

    func rememberICloudAccount() {
        guard let opened else { return }
        keepICloudAccount(opened.engine.icloudAccount())
    }

    // TablePro Sync and the key flows stay bound to the sign-in the service opened with, and refuse once it ends, so
    // the service closes and opens again for the same provider, as on the Mac. The old one goes once its calls in
    // flight and its flush end.
    func signInChanged() {
        signIn += 1
        signInChanges.send()
        guard let provider = opened?.provider ?? opening?.provider else { return }
        if let old = opened?.engine {
            retire(old)
        }
        opened = nil
        Task { [weak self] in
            guard (try? await self?.engine(for: provider)) != nil else { return }
            self?.reopened.send()
        }
    }

    // The open service goes, with its flush; the next caller opens one for the provider it asks for.
    func close() {
        guard let old = opened?.engine else { return }
        retire(old)
        opened = nil
    }

    private func retire(_ engine: any IOSSyncEngine) {
        let id = UUID()
        retiring[id] = Task { [weak self] in
            do {
                try await engine.flushLegacyMarks()
            } catch {
                Self.logger.error("A closed service's marks did not flush: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            }
            self?.retiring[id] = nil
        }
    }

    // The provider is fixed when the service opens, and one opened Off refuses every provider call, so iCloud turned
    // on after that opens a new service, as on the Mac. One opened for iCloud is kept when iCloud stops, and told Off. A
    // failed open is tried again by the next caller.
    func engine(for provider: SyncProviderTag) async throws -> any IOSSyncEngine {
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

    // The service for what lives on TablePro Sync whatever the personal provider is: the account's keys and its team
    // scopes (core ADR 0054, Providers, and 0056). The open service serves them whichever provider it was opened for;
    // with none open, one opens Off.
    func accountScopesEngine() async throws -> any IOSSyncEngine {
        try await engine(for: .off)
    }

    func keyService() async throws -> SyncService {
        guard let service = try await accountScopesEngine() as? SyncService else { throw KeyServiceUnavailable() }
        return service
    }

    // The service the categories go to now, whichever provider opened it. One opening meanwhile may have read the
    // earlier categories, so it hears them once it is open.
    func setCategories(_ categories: SyncCategoriesArg) async {
        while let pending = opening {
            _ = await pending.task.result
            if opening?.task == pending.task {
                opening = nil
            }
        }
        guard let engine = openedEngine(for: .off) else { return }
        do {
            try await engine.setCategories(categories: categories)
        } catch {
            Self.logger.error("The engine did not take the categories: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
    }

    private func startOpening(_ provider: SyncProviderTag) -> Opening {
        let started = signIn
        let task = Task { [weak self, open, listener = IOSSyncEngineListener(host: self)] in
            let engine = try await open(provider, listener)
            if let self, signIn == started {
                opened = (provider, engine)
                keepServiceAccount(engine.serviceAccount())
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
            return
        }
        // The sign-in the state file follows changes once the person chooses for another account.
        if let opened {
            keepServiceAccount(opened.engine.serviceAccount())
        }
        onSignal?()
        statusChanges.send()
    }

    // No settings host: the iPhone keeps no synced settings of its own. The device store holds each state file's MAC
    // key and anchor in the app's own Keychain group, since no extension reads sync state. The account is optional,
    // since iCloud needs none (core ADR 0054, Providers).
    static func live(
        core: MobileCoreHost,
        account: @escaping @MainActor () async -> AccountService?,
        database: any CloudKitDatabase,
        metadata: SyncMetadataStorage,
        recordCache: SyncRecordCache,
        defaults: UserDefaults
    ) -> IOSSyncEngineHost {
        let transport = CloudKitCoreTransport(database: database)
        let mirror = LegacySyncMetadataMirror(metadata: metadata, recordCache: recordCache)
        let deviceStore = KeychainDeviceStore(accessGroup: AccountKeychainItems.appAccessGroup)
        return IOSSyncEngineHost(
            transport: transport,
            keepICloudAccount: { kept in
                guard defaults.string(forKey: icloudAccountKey) != kept else { return }
                defaults.set(kept, forKey: icloudAccountKey)
            },
            keepServiceAccount: { kept in
                guard defaults.string(forKey: serviceAccountKey) != kept else { return }
                defaults.set(kept, forKey: serviceAccountKey)
            },
            open: { provider, listener in
                let account = await account()
                return try await core.core().openSync(
                    config: SyncConfig(
                        platform: .ios,
                        provider: provider,
                        categories: SyncCategories(defaults: defaults).coreArgument,
                        icloudAccount: defaults.string(forKey: icloudAccountKey),
                        serviceAccount: defaults.string(forKey: serviceAccountKey)
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
nonisolated private final class IOSSyncEngineListener: SyncListener, @unchecked Sendable {
    private weak var host: IOSSyncEngineHost?

    @MainActor
    init(host: IOSSyncEngineHost) {
        self.host = host
    }

    func statusChanged() {
        Task { @MainActor [weak host] in host?.listenerSignalled(keys: false) }
    }

    func keysChanged() {
        Task { @MainActor [weak host] in host?.listenerSignalled(keys: true) }
    }
}
