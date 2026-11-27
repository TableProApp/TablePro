//
//  CoreHistoryDatabase.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The core's query stores under `TablePro/Core/`, on the core every store there shares (core ADR 0060 as amended): the
// history in its own folder, and the saved queries and their folders, the favourite tables and databases and the table
// folders in `saved_queries.db`. Each opens on first use; a failed open is tried again on the next call.
internal actor CoreHistoryDatabase {
    internal static let shared = CoreHistoryDatabase(host: .shared)

    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreHistoryDatabase")

    private let host: CoreStoreHost
    private var store: QueryHistoryStore?
    private var savedQueryStores: SavedQueryDatabaseStore?

    nonisolated internal var folder: URL { host.folder }

    internal init(host: CoreStoreHost) {
        self.host = host
    }

    // A core of its own over `folder`, for a store nothing else opens.
    internal init(folder: URL, clientVersion: String = CoreHistoryDatabase.appVersion) {
        self.init(host: CoreStoreHost(folder: folder, makeSecrets: { NoHistorySecrets() }, clientVersion: clientVersion))
    }

    nonisolated internal static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    internal func history() async throws -> QueryHistoryStore {
        if let store { return store }
        do {
            let opened = try await host.core().history()
            store = opened
            return opened
        } catch {
            Self.logger.error("The core's history store did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            throw error
        }
    }

    private func savedQueryDatabase() async throws -> SavedQueryDatabaseStore {
        if let savedQueryStores { return savedQueryStores }
        do {
            let opened = try await host.core().savedQueryDatabase()
            savedQueryStores = opened
            return opened
        } catch {
            Self.logger.error("The core's saved queries store did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
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
}

// A whole-store write the core refused because the store moved since it was read (storage.import_outdated).
internal func refusingOutdated(_ work: () async throws -> Void) async throws {
    do {
        try await work()
    } catch CoreError.Failed(let info) where info.code == "storage.import_outdated" {
        throw CoreMirrorError.outdated
    }
}

// Nothing in the query stores is a secret, and a core opened for them alone keeps none.
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
