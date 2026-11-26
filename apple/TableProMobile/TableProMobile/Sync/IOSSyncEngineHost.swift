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
    private let open: @MainActor (any SyncListener) async throws -> any IOSSyncEngine
    private let keepICloudAccount: @MainActor (String?) -> Void
    private var opening: Task<any IOSSyncEngine, any Error>?
    private(set) var openedEngine: (any IOSSyncEngine)?

    init(
        transport: CloudKitCoreTransport,
        keepICloudAccount: @escaping @MainActor (String?) -> Void = { _ in },
        open: @escaping @MainActor (any SyncListener) async throws -> any IOSSyncEngine
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
    func engine() async throws -> any IOSSyncEngine {
        if let openedEngine {
            return openedEngine
        }
        let task = opening ?? Task { [open, listener = IOSSyncEngineListener(host: self)] in
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

    fileprivate func listenerSignalled() {
        onSignal?()
    }

    // No device store and no settings host: iCloud on iOS carries no key state, and the iPhone keeps no synced
    // settings of its own. The account is optional, since iCloud needs none (core ADR 0054, Providers).
    static func live(
        core: MobileCoreHost,
        account: AccountModel,
        metadata: SyncMetadataStorage,
        recordCache: SyncRecordCache,
        defaults: UserDefaults,
        isEnabled: @escaping @MainActor () -> Bool
    ) -> IOSSyncEngineHost {
        let transport = CloudKitCoreTransport()
        let checked = PolicyCheckedCloudKitTransport(base: transport) {
            ManagedAppConfiguration.current().allowsICloudSync
        }
        let mirror = LegacySyncMetadataMirror(metadata: metadata, recordCache: recordCache)
        return IOSSyncEngineHost(
            transport: transport,
            keepICloudAccount: { kept in
                guard defaults.string(forKey: icloudAccountKey) != kept else { return }
                defaults.set(kept, forKey: icloudAccountKey)
            },
            open: { listener in
                let service = await account.syncAccountService()
                return try await core.core().openSync(
                    config: SyncConfig(
                        platform: .ios,
                        provider: isEnabled() ? .icloud : .off,
                        categories: SyncCategoriesArg(offKinds: [], passwords: AppPreferences.syncsPasswords),
                        icloudAccount: defaults.string(forKey: icloudAccountKey)
                    ),
                    account: service,
                    cloudkit: checked,
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
