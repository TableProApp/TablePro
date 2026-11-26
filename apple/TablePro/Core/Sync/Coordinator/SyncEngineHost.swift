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
}

extension SyncService: SyncEngine {}

// The app's one core sync service (core ADR 0054), opened on first use over the account's core, with the CloudKit
// transport and the Swift engine's metadata. Its listener only signals, and the signal reaches the main actor.
@MainActor
final class SyncEngineHost {
    static let shared = SyncEngineHost.live()

    let transport: CloudKitCoreTransport
    let statusChanges = PassthroughSubject<Void, Never>()
    let keyChanges = PassthroughSubject<Void, Never>()
    private let open: @MainActor (any SyncListener) async throws -> any SyncEngine
    private var opening: Task<any SyncEngine, any Error>?
    private(set) var openedEngine: (any SyncEngine)?

    init(
        transport: CloudKitCoreTransport,
        open: @escaping @MainActor (any SyncListener) async throws -> any SyncEngine
    ) {
        self.transport = transport
        self.open = open
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
    // and freshness).
    private static func live() -> SyncEngineHost {
        let transport = CloudKitCoreTransport()
        let mirror = LegacySyncMetadataMirror(
            metadata: .appDefault,
            recordCache: SyncProviderCoordinator.makeRecordCache()
        )
        return SyncEngineHost(transport: transport) { listener in
            guard let opener = AccountServices.shared.syncOpener else {
                throw AccountError.network("the account did not open")
            }
            return try await opener.openSync(
                config: SyncConfig(
                    platform: .macos,
                    categories: SyncProviderCoordinator.categories(AppSettingsStorage.shared.loadSync())
                ),
                cloudkit: transport,
                settings: nil,
                deviceStore: nil,
                legacyMirror: mirror,
                listener: listener
            )
        }
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
