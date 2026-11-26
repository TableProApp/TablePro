import Foundation
import TableProFFI
import TableProSyncTransport

// The core's sync service as the iOS coordinator drives it, so its tests run over a fake engine.
nonisolated protocol IOSSyncEngine: AnyObject, Sendable {
    func status() -> SyncStatusInfo
    func syncNow(why: PassReasonTag) async throws
    func chooseProvider(provider: SyncProviderTag) async throws
    func uploadAgain() async throws
    func icloudAccount() -> String?
}

extension SyncService: IOSSyncEngine {}

// The app's one core sync service (core ADR 0054, The Apple apps on the engine), opened on first use on the core that
// holds the stores, with the shared CloudKit transport and the Swift engine's metadata, which it imports once and keeps
// written for the previous stable. Its listener only signals, and the signal reaches the main actor.
@MainActor
final class IOSSyncEngineHost {
    // The iCloud account whose state file the engine used last, handed back at the next open so a switch made while the
    // app was closed removes that account's file. Its own key: `lastAccountId` is the downgrade mirror's.
    nonisolated static let icloudAccountKey = "com.TablePro.sync.engineICloudAccount"

    // Where the Swift engine kept its record cache, which the engine imports as bases and the mirror keeps writing.
    nonisolated static var recordCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    let transport: CloudKitCoreTransport
    var onSignal: (() -> Void)?
    private let open: @MainActor (SyncProviderTag, any SyncListener) async throws -> any IOSSyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private typealias Opening = (provider: SyncProviderTag, task: Task<any IOSSyncEngine, any Error>)
    private var opening: Opening?
    private var opened: (provider: SyncProviderTag, engine: any IOSSyncEngine)?

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        open: @escaping @MainActor (SyncProviderTag, any SyncListener) async throws -> any IOSSyncEngine
    ) {
        self.transport = transport
        self.keepICloudAccount = keepICloudAccount
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
            if case .failure(let error) = result, Self.serves(current.provider, provider) {
                throw error
            }
        }
    }

    private func startOpening(_ provider: SyncProviderTag) -> Opening {
        let task = Task { [weak self, open, listener = IOSSyncEngineListener(host: self)] in
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

    fileprivate func listenerSignalled() {
        onSignal?()
    }

    // No settings host: the iPhone keeps no synced settings of its own. The device store holds each state file's MAC
    // key and anchor in the app's own Keychain group, since no extension reads sync state. The account is optional,
    // since iCloud needs none (core ADR 0054, Providers).
    static func live(
        core: MobileCoreHost,
        account: AccountModel,
        metadata: SyncMetadataStorage,
        recordCache: SyncRecordCache,
        defaults: UserDefaults
    ) -> IOSSyncEngineHost {
        let transport = CloudKitCoreTransport()
        let checked = PolicyCheckedCloudKitTransport(base: transport) {
            ManagedAppConfiguration.current().allowsICloudSync
        }
        let mirror = LegacySyncMetadataMirror(metadata: metadata, recordCache: recordCache)
        let deviceStore = KeychainDeviceStore(accessGroup: AccountKeychainItems.appAccessGroup)
        return IOSSyncEngineHost(
            transport: transport,
            keepICloudAccount: { kept in
                guard defaults.string(forKey: icloudAccountKey) != kept else { return }
                defaults.set(kept, forKey: icloudAccountKey)
            },
            open: { provider, listener in
                let service = await account.syncAccountService()
                return try await core.core().openSync(
                    config: SyncConfig(
                        platform: .ios,
                        provider: provider,
                        categories: SyncCategoriesArg(offKinds: [], passwords: AppPreferences.syncsPasswords),
                        icloudAccount: defaults.string(forKey: icloudAccountKey)
                    ),
                    account: service,
                    cloudkit: checked,
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
        Task { @MainActor [weak host] in host?.listenerSignalled() }
    }

    func keysChanged() {}
}
