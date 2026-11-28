//
//  SyncPassFollower.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// The stores a pass writes in the core, each read back into what the app shows. Settings are not here: the engine
// writes them through `HostSettings` during the pass. Team Library reads the engine on every status signal itself.
@MainActor
struct SyncPulledStores {
    // Connections, groups, tags, projects, and SSH and credential profiles.
    var library: @MainActor () -> Void
    var savedQueries: @MainActor () async -> Void
    var favoriteTables: @MainActor () async -> Void
    var favoriteDatabases: @MainActor () async -> Void
    var tableFolders: @MainActor () async -> Void
    var history: @MainActor () async -> Void

    // The library first, so a pulled favourite or folder finds its connection.
    func read() async {
        library()
        await savedQueries()
        await favoriteTables()
        await favoriteDatabases()
        await tableFolders()
        await history()
    }

    static var live: SyncPulledStores {
        SyncPulledStores(
            library: { ConnectionStorage.shared.readCoreWrites() },
            savedQueries: { _ = await SQLFavoriteManager.shared.pushToCore() },
            favoriteTables: { _ = await FavoriteTablesStorage.shared.coreMirror?.push() },
            favoriteDatabases: { _ = await FavoriteDatabasesStorage.shared.coreMirror?.push() },
            tableFolders: { _ = await TableFolderStorage.shared.coreMirror?.push() },
            history: {
                await QueryHistoryManager.shared.coreMirror?.pushSoon()
                _ = await QueryHistoryManager.shared.coreMirror?.fillFingerprints()
            }
        )
    }
}

// The one place pulled records reach the app (core ADR 0054, The Apple apps on the engine): after each pass of the
// service open now, whatever provider it runs and however often it was replaced, every store is read back once.
@MainActor
final class SyncPassFollower {
    static let shared = SyncPassFollower()

    private var subscription: AnyCancellable?
    private var passSeen: Int64?
    private var reading: Task<Void, Never>?
    private var readsAgain = false

    // The host's signals come from whichever service it holds, so a service opened after a move is followed too.
    func start(host: SyncEngineHost, stores: SyncPulledStores = .live) {
        start(
            changes: host.statusChanges.eraseToAnyPublisher(),
            lastPass: { [weak host] in host?.openedEngine(for: .off)?.status().lastPassMs },
            stores: stores
        )
    }

    func start(
        changes: AnyPublisher<Void, Never>,
        lastPass: @escaping @MainActor () -> Int64?,
        stores: SyncPulledStores
    ) {
        guard subscription == nil else { return }
        subscription = changes.sink { [weak self] in
            guard let self, let pass = lastPass(), pass != passSeen else { return }
            passSeen = pass
            read(stores)
        }
    }

    // Waits for the reads asked for so far.
    func readsFinished() async {
        while let reading {
            await reading.value
        }
    }

    // One read at a time; a pass that ends during one reads again once it is done.
    private func read(_ stores: SyncPulledStores) {
        readsAgain = true
        guard reading == nil else { return }
        reading = Task { [weak self] in
            guard let self else { return }
            while readsAgain {
                readsAgain = false
                await stores.read()
            }
            reading = nil
        }
    }
}
