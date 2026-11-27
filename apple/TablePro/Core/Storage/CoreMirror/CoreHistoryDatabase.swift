//
//  CoreHistoryDatabase.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The core's query stores under `TablePro/Core/` (core ADR 0060 as amended): history.db holds the history, and
// saved_queries.db the saved queries and their folders, the favourite tables and databases and the table folders.
// Each opens on first use; a failed open is tried again on the next call.
internal actor CoreHistoryDatabase {
    internal static let shared = CoreHistoryDatabase(
        folder: AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("Core", isDirectory: true)
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreHistoryDatabase")

    nonisolated internal let folder: URL
    private let clientVersion: String
    private var core: Core?
    private var store: QueryHistoryStore?
    private var savedQueryStore: SavedQueryDatabaseStore?

    internal init(folder: URL, clientVersion: String = CoreHistoryDatabase.appVersion) {
        self.folder = folder
        self.clientVersion = clientVersion
    }

    nonisolated internal static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    internal func history() async throws -> QueryHistoryStore {
        if let store { return store }
        do {
            let opened = try await openedCore().history()
            store = opened
            return opened
        } catch {
            Self.logger.error("The core's history store did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            throw error
        }
    }

    internal func savedQueries() async throws -> SavedQueryStore {
        try await savedQueryDatabase().savedQueries()
    }

    internal func favourites() async throws -> FavouriteStore {
        try await savedQueryDatabase().favourites()
    }

    internal func tableFolders() async throws -> TableFolderStore {
        try await savedQueryDatabase().tableFolders()
    }

    private func savedQueryDatabase() async throws -> SavedQueryDatabaseStore {
        if let savedQueryStore { return savedQueryStore }
        do {
            let opened = try await openedCore().savedQueryDatabase()
            savedQueryStore = opened
            return opened
        } catch {
            Self.logger.error("The core's saved query store did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            throw error
        }
    }

    private func openedCore() throws -> Core {
        if let core { return core }
        // Private as the core keeps its own folders, since history.db holds the SQL a person ran.
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let opened = try Core(
            config: HostConfig(clientVersion: clientVersion, storageDir: folder.path),
            secrets: NoHistorySecrets()
        )
        core = opened
        return opened
    }
}

// A whole-store write the core refused because the store moved since it was read (storage.import_outdated).
internal func refusingOutdated(_ work: () async throws -> Void) async throws {
    do {
        try await work()
    } catch CoreError.Failed(let info) where info.code == "storage.import_outdated" {
        throw CoreMirrorError.outdated
    }
}

// Nothing in the query stores is a secret, and this core is opened for those files alone.
private final class NoHistorySecrets: HostSecrets, Sendable {
    func load(connectionId: String, kind: SecretKindTag) throws -> String? { nil }

    func store(connectionId: String, kind: SecretKindTag, secret: String, label: String) throws {
        throw HostSecretError.Unavailable(detail: "the history store keeps no secrets")
    }

    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {}
    func delete(connectionId: String, kind: SecretKindTag) throws {}
    func deleteConnection(connectionId: String) throws {}
    func loadItem(item: SecretItemTag) throws -> String? { nil }

    func storeItem(item: SecretItemTag, secret: String) throws {
        throw HostSecretError.Unavailable(detail: "the history store keeps no secrets")
    }

    func deleteItem(item: SecretItemTag) throws {}
}
